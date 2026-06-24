# Phase 1 bootstrap: 用来 apply 的 root Application 清单路径。
# terraform/ 与 root-application.yaml 同处 sre-works-infra 仓库，
# 这样 GitOps 的 "唯一事实来源" 和 Terraform bootstrap 用的是同一份文件。
# file() 路径相对模块目录(terraform/eks/)，向上两级到仓库根。
variable "root_application_manifest_path" {
  description = "Path to the root Argo CD Application manifest applied during bootstrap."
  type        = string
  default     = "../../root-application.yaml"
}

# Argo CD Helm chart 版本。最新版本见:
# https://artifacthub.io/packages/helm/argo/argo-cd
variable "argocd_chart_version" {
  description = "Version of the argo-cd Helm chart to install."
  type        = string
  default     = "9.7.0"
}
