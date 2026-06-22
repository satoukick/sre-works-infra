# sre-works-infra

## ArgoCD 部署故障排查

当 ArgoCD 配置变更没有生效时，按以下顺序排查：

### 1. 确认远程 GitHub 已推送最新内容
- **最常见的原因**：本地修改了 YAML 但忘记 push 到远程
- 检查命令：`git push origin main` 前先确保 `git status` 显示已提交
- ArgoCD 从 GitHub 拉取配置，**本地更改对集群无效**

### 2. 检查资源所有权和 Finalizers
```bash
# 检查子 Application 是否有 finalizer
kubectl get application sre-works-argo-app -n argocd -o yaml | grep finalizers
```
### 3. 级联删除时的常见问题
- Application 必须有 `finalizers: [resources-finalizer.argocd.argoproj.io]`
- 必须配置 `syncOptions: [PrunePropagationPolicy=foreground]`
- 删除时使用：`kubectl delete application <name> -n argocd` 或 `argocd app delete <name> --cascade`
