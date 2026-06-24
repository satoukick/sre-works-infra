# build EKS cluster with Terraform

provider "aws" {
  region = local.region
}

# ---- Kubernetes / Helm / kubectl provider 配置 ----
# 直接用 module.eks 的输出而不是 data.aws_eks_cluster：
# 同一次 apply 里创建 EKS 时，data source 会在 plan 阶段因集群不存在而失败，
# 而 module 输出能在 plan 阶段以 unknown 值通过，apply 时才真正连集群。
# exec 块让 provider 每次调用 API 时动态执行 `aws eks get-token` 拿短期 token。

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks",
      "get-token",
      "--cluster-name",
      module.eks.cluster_name,
    ]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = [
        "eks",
        "get-token",
        "--cluster-name",
        module.eks.cluster_name,
      ]
    }
  }
}

provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false
  # lazy_load: apply 时才连 API，避免 plan 阶段集群还没建好就报错
  lazy_load = true

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks",
      "get-token",
      "--cluster-name",
      module.eks.cluster_name,
    ]
  }
}

locals {
  region             = "ap-southeast-1"
  kubernetes_version = "1.35"
  azs = slice(
    data.aws_availability_zones.available.names,
    0,
    3
  )

  vpc_cidr = "10.0.0.0/16"
  name     = "sre-works-eks"

  tags = {
    Environment = "dev"
    Terraform   = "true"
  }

}

data "aws_availability_zones" "available" {
  state = "available"
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.15.1"

  name                                     = local.name
  kubernetes_version                       = local.kubernetes_version
  endpoint_public_access                   = true
  enable_cluster_creator_admin_permissions = true

  compute_config = {
    enabled    = true
    node_pools = ["general-purpose"]
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  tags = local.tags
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = local.name

  azs = local.azs

  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]
  intra_subnets   = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 52)]

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = local.tags
}

# ============================================================
# Phase 1: Bootstrap Argo CD + root Application
# ============================================================

# 1) 安装 Argo CD 到 argocd namespace。
#    create_namespace=true 让 helm 自动建 namespace，省去单独的 kubernetes_namespace 资源。
#    wait=true 会阻塞到所有 Deployment 就绪、Application CRD 变成 Established，
#    这样紧接着的 kubectl_manifest 创建 root Application 时 CRD 一定已就绪。
resource "helm_release" "argocd" {
  name       = "argo-cd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version
  namespace  = "argocd"

  create_namespace = true
  wait             = true
  wait_for_jobs    = true

  # bootstrap 阶段不做任何额外配置，使用 chart 默认值。
  # 生产环境建议通过 values = [file(...)] 注入 Ingress / SSO / 资源 limits 等。
}

# 2) 把 root-application.yaml apply 进集群。
#    kubectl provider 直接读 Git 仓库里的同一份 YAML，保证 "Terraform bootstrap"
#    和 "Argo CD 后续 GitOps" 用的是同一份事实来源。
#    depends_on 确保 helm_release.argocd（含 Application CRD）先就绪。
#    server-side apply 被开启，避免与 Argo CD 自己的 controller 发生字段所有权冲突。
data "kubectl_file_documents" "root_application" {
  content = file(var.root_application_manifest_path)
}

resource "kubectl_manifest" "root_application" {
  for_each   = data.kubectl_file_documents.root_application.manifests
  yaml_body  = each.value
  apply_only = true

  depends_on = [helm_release.argocd]
}
