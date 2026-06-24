# Phase 1 Bootstrap Runbook

本 runbook 描述如何在一个全新的 AWS 账号上，从零拉起 `sre-works-infra` 定义的
EKS 集群，并 bootstrap Argo CD + root Application。

执行完本文档后，集群应处于以下状态：

- EKS 集群 `sre-works-eks` 已创建
- `argocd` namespace 中 Argo CD 已运行
- root Application 已创建，Argo CD 开始同步 `infra-apps/` 下的 child Application

> Terraform 只负责"建集群 + 装 Argo CD + 创建 root Application"这三件事。
> 之后所有平台组件（cert-manager、OpenTelemetry、Jaeger 等）都由 Argo CD 通过
> GitOps 管理，不再走 Terraform。

## 0. 前置条件

| 依赖 | 版本要求 | 用途 |
|---|---|---|
| Terraform | >= 1.14 | 执行 bootstrap |
| AWS CLI | >= 2.x | `eks get-token` 认证、更新 kubeconfig |
| kubectl | 与集群 K8s 版本匹配（1.35） | 验证集群状态 |
| git | 任意 | clone 本仓库 |
| AWS 凭证 | 有 EKS/VPC/IAM 权限的 IAM 身份 | Terraform 操作 AWS |

确认 AWS 凭证已配置且指向目标账号：

```bash
aws sts get-caller-identity
```

## 1. 创建 EKS 集群

```bash
cd terraform/eks
terraform init
terraform plan
terraform apply
```

`terraform apply` 会依次完成：

1. 用 `terraform-aws-modules/vpc` 建专用 VPC（含 NAT、3 AZ 子网）
2. 用 `terraform-aws-modules/eks` 建 EKS 集群（EKS Auto Mode，节点池 `general-purpose`）
3. 用 `helm_release` 把 Argo CD 安装到 `argocd` namespace（`wait=true`，等 CRD 就绪）
4. 用 `kubectl_manifest` 把 `../../root-application.yaml` apply 进集群

整个过程约 15-25 分钟，主要耗时在 EKS 控制面与节点启动上。

> `apply` 结束前若卡在 `helm_release.argocd`，多半是节点还没 Ready。
> EKS Auto Mode 节点冷启动通常需要 3-5 分钟，耐心等待即可。

## 2. 更新 kubeconfig

`terraform apply` 完成后，把集群写入本地 kubeconfig：

```bash
aws eks update-kubeconfig \
  --region ap-southeast-1 \
  --name sre-works-eks
```

验证能连上集群：

```bash
kubectl get nodes
```

应看到 `general-purpose` 节点池的节点处于 `Ready`。

## 3. 确认 Argo CD 已就绪

```bash
kubectl get pods -n argocd
```

所有 Pod 应为 `Running`。其中 `argocd-server-*` 是 Argo CD 的 API server。

（可选）获取初始 admin 密码：

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
```

## 4. 确认 root Application 已创建并开始同步

```bash
kubectl get application -n argocd
```

应看到名为 `root-application` 的 Application。

查看它的同步与健康状态：

```bash
kubectl get application root-application -n argocd \
  -o jsonpath='{.status.sync.status}{" "}{.status.health.status}{"\n"}'
```

预期输出：

```
Synced Healthy
```

root Application 会自动递归发现 `infra-apps/` 下的 child Application
（cert-manager、opentelemetry、jaeger）并开始同步。

## 5. 验证 child Application 已被 root 拉起

```bash
kubectl get applications -n argocd
```

应看到 root Application 以及它创建出来的 child Application 列表。

> Phase 1 的完成标准只要求 root Application 处于 `Synced` + `Healthy`。
> child Application 是否健康属于 Phase 2（app-of-apps 顺序、sync wave）的范畴，
> 此时它们可能还因依赖顺序问题处于 `OutOfSync` / `Degraded`，属正常现象。

## 排查清单

### `terraform apply` 报 `Could not download module`

网络问题——`terraform-aws-modules/eks` / `vpc` 需要从 GitHub 拉取。
确认能访问 github.com，必要时配置代理或 `git config --global` 走 HTTPS。

### provider 报 `Unauthorized` / `client.authentication.k8s.io`

`exec` 块依赖 `aws eks get-token`。确认：

- AWS CLI 已登录，且凭证有 `eks:AccessKubernetesApi` 权限
- `--cluster-name` 与实际集群名一致（`sre-works-eks`）
- 本机时区/时间正确（token 有时效校验）

### `kubectl_manifest.root_application` 报 `no matches for kind "Application"`

Argo CD 的 `Application` CRD 还没注册到 API server。通常是 `helm_release.argocd`
的 `wait=true` 没真正等到 CRD `Established`。手动等待后重试：

```bash
kubectl wait --for=condition=Established crd/applications.argoproj.io --timeout=120s
terraform apply   # 重新 apply，kubectl_manifest 会成功
```

### root Application 一直 `OutOfSync`

最常见原因：本地改了 `root-application.yaml` 但没 push 到 GitHub。
Argo CD 从 GitHub 拉取，**本地更改对集群无效**。先 commit + push，再到 Argo CD 里 refresh。

详见仓库根目录 `CLAUDE.md` 的故障排查章节。

## 销毁（可选）

完全清理集群时，**先删 root Application 触发级联，再 `terraform destroy`**：

```bash
# 1. 删 root Application（finalizer 会级联清理所有 child Application 及其资源）
kubectl delete application root-application -n argocd

# 2. 等级联删除完成
kubectl get applications -n argocd   # 应为空

# 3. 销毁集群与 VPC
cd terraform/eks
terraform destroy
```

> 如果直接 `terraform destroy`，`kubectl_manifest` 的删除可能因 CRD 随 Argo CD
> 一起卸载而失败。按上面顺序操作更稳妥。
