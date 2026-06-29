# sre-practice-infra 路线图

## 目标

实现 Argo CD 的 app-of-apps 部署模式，让 `sre-practice-infra` 仓库先拉起基础平台组件。基础组件健康后，可以手动部署由 `sre-practice/Dockerfile` 构建出来的业务镜像，并让业务服务在集群中成功运行。

## 当前状态

- `root-application.yaml` 已经指向 `infra-apps`，所以 `sre-practice-infra` 是 app-of-apps root Application 的合适位置。
- `infra-apps` 目录下已经有 `cert-manager`、`opentelemetry`、`jaeger` 三个 child Application。
- 业务应用的 Application 当前放在 `legacy/business-app.yaml`，指向 `sre-practice/kubernetes/app`。
- `sre-practice` 仓库里已经有业务 app、OpenTelemetry Collector、Jaeger、cert-manager、OpenTelemetry Operator 等 Kubernetes manifest。
- `sre-practice` 仓库里已有 GitHub Actions workflow，用来构建并推送 GHCR 镜像。

## Phase 1：用 Terraform Bootstrap Argo CD

> **状态：代码与文档完成，待集群验证**
> - Terraform bootstrap 代码位于 `terraform/eks/`（含 `helm`/`kubernetes`/`kubectl` provider、Argo CD helm_release、root Application 的 kubectl_manifest）。
> - Bootstrap runbook 见 `docs/bootstrap.md`。
> - `terraform fmt -check` 通过；`terraform init`/`apply` 因沙箱网络（github.com / registry SSL 重置）未跑通，待在联网环境验证一次真实建集群。

- 在 EKS 创建完成后，为 Terraform 增加需要的 provider：`helm`、`kubernetes`，以及可选的 `argocd`。
- 使用 Terraform 将 Argo CD 安装到 `argocd` namespace。
- 在 Argo CD 就绪后，由 Terraform apply 或管理 `root-application.yaml`。
- Terraform 只负责集群和 bootstrap 资源；基础平台组件交给 Argo CD 管理。
- 文档化 bootstrap 流程：
  - 创建 EKS
  - 更新 kubeconfig
  - 安装 Argo CD
  - 创建 root Application
  - 验证 root Application 的同步状态

## Phase 2：完善 App-Of-Apps 结构

> **状态：代码完成，待集群验证**
> - `infra-apps/` 下 `cert-manager`、`opentelemetry`、`jaeger` 三个 child Application 已补齐一致的 finalizer、syncOptions 和 sync-wave。
> - opentelemetry 的 sync-wave 从 `-1` 修正为 `1`，确保它晚于 cert-manager 同步。
> - `legacy/business-app.yaml` 仍保留在 `legacy/`，等待后续决定是否纳入 app-of-apps tree。
> - wave 3 的 otel-collector 属于 Phase 3 范围，尚未创建。

- 保持 `root-application.yaml` 作为 root app，继续指向 `infra-apps`。
- 确保 `infra-apps` 下每个 YAML 都是一个 Argo CD child Application。
- 等基础组件稳定后，再考虑把 `legacy/business-app.yaml` 移入 `infra-apps`；如果目标仍然是手动部署业务 app，也可以继续保留在 `legacy`。
- 为所有 child Application 补齐一致的元数据：
  - `resources-finalizer.argocd.argoproj.io`
  - `PrunePropagationPolicy=foreground`
  - 需要自动创建 namespace 时加 `CreateNamespace=true`
- 使用 sync wave 表达组件依赖顺序：
  - wave 0：`cert-manager`
  - wave 1：`opentelemetry-operator`
  - wave 2：`jaeger`
  - wave 3：`otel-collector` 以及相关配置
  - wave 4：可选的业务 app Application
- 重新检查当前 sync-wave 配置。`opentelemetry` 不应该早于 `cert-manager` 同步，因为 OpenTelemetry Operator manifest 中包含 cert-manager 的 `Certificate` / `Issuer` 资源。

## Phase 3：补齐缺失的平台组件

> **状态：代码完成，待集群验证**
> - `infra-apps/otel-collector.yaml`（wave 3）指向 `sre-works/kubernetes/components/otel-collector/`，部署 OpenTelemetryCollector CR `simple` + ConfigMap。
> - `infra-apps/kube-prometheus-stack.yaml`（wave 2，Helm-based）部署 kube-prometheus-stack chart 87.3.0，内联 `web.enable-otlp-receiver` override 启用 OTLP receiver。
> - service 名一致性已核对：`jaeger-inmemory-instance-collector`、`simple-collector`、`kube-prometheus-stack-prometheus` 均与 collector endpoint 匹配。
> - cert-manager / opentelemetry 的静态 vendor YAML 暂不转 Helm（用户决策：Phase 3 只做加法）。

- 为 `sre-practice/kubernetes/otel-instance.yaml` 增加一个 child Application，用来部署 OpenTelemetry Collector。
- 为 `sre-practice/kubernetes/otel-configmap.yaml` 增加 child Application，或者将它纳入 collector 所在路径。
- 明确 Prometheus 的安装方式：
  - 使用 Argo CD Helm chart Application 安装 `kube-prometheus-stack`
  - 或者继续使用应用仓库中的静态渲染 manifest
- 如果 collector 的 metrics exporter 依赖 Prometheus，需要确认 collector 中配置的 Prometheus service name 和实际部署出来的 service name 一致。
- 确认 OpenTelemetry Operator 为 Jaeger 生成的 service name 与 collector exporter endpoint 一致。
- 对特别大的 vendor YAML 做清理规划。条件允许时，优先改成 Helm-based Application，尤其是 cert-manager 和 kube-prometheus-stack。

## Phase 4：准备业务应用的手动部署

- 在基础组件健康之前，业务 app 继续保持手动部署。
- 统一 `sre-practice` 仓库里的两套业务部署 manifest：
  - `kubernetes/app/*` 当前使用 `ghcr.io/satoukick/sre-practice:main`
  - `kubernetes/server.yaml` 包含有用的 OTEL 环境变量，但使用的是本地镜像 `sre-practice:v1`
- 将最终业务 Deployment 补齐必要的 OTEL 环境变量：
  - `OTEL_EXPORTER_OTLP_ENDPOINT`
  - `OTEL_EXPORTER_OTLP_PROTOCOL`
  - `OTEL_RESOURCE_ATTRIBUTES`
- 为业务 Deployment 增加 CPU / memory requests 和 limits。
- 增加 readiness / liveness 检查，最好在 Go 应用里补一个简单的 `/healthz` endpoint。
- 确认 GitHub Actions 实际产出的 GHCR 镜像 tag 与 Deployment 中使用的 image tag 一致。
- 明确最终业务发布方式：
  - 手动执行 `kubectl apply`
  - 或者手动 sync 一个 Argo CD child Application

## Phase 5：验证与 Runbook

- 在本仓库补充一份简短的验证 runbook。
- 最小集群检查：
  - `kubectl get applications -n argocd`
  - `kubectl get pods -A`
  - `kubectl get opentelemetrycollectors -A`
  - `kubectl get svc -A`
- 最小 Argo CD 检查：
  - root Application 状态为 `Synced` 和 `Healthy`
  - child Applications 状态为 `Synced` 和 `Healthy`
  - refresh 后没有非预期的 `OutOfSync` 资源
- 最小业务应用检查：
  - 业务 Deployment 达到可用副本数
  - LoadBalancer service 获取到 external address
  - `/rolldice/` 能返回一个骰子点数
  - Jaeger 中能看到 trace
  - 如果 Prometheus 被纳入平台目标，则 Prometheus 中能看到 metrics

## 完成标准

- Terraform 可以创建 EKS 集群，并 bootstrap Argo CD。
- Argo CD root Application 可以同步所有基础 infra child Application。
- cert-manager、OpenTelemetry Operator、Jaeger、OpenTelemetry Collector 能按照预期顺序变为健康状态。
- 基础组件健康后，可以手动部署由 `Dockerfile` 构建出的业务 app 镜像。
- 业务 app 可以通过 Kubernetes Service 接收流量。
- 业务 app 的 telemetry 能进入配置好的 collector，并能在选定的后端中查看。
- 部署和故障排查步骤足够清晰，可以在一个新集群上重复执行。

## 待确认问题

- kube-prometheus-stack 是否属于当前阶段必须拉起的基础组件，还是先等 tracing 端到端打通后再加入？
- child Application 应该继续引用 `sre-practice` 中的 manifest，还是把 infra 组件 manifest 移到 `sre-practice-infra` 管理？
- 业务 app 最终是否也要纳入 app-of-apps tree，还是按设计保持手动部署？
- 手动测试时应该使用哪个镜像 tag：`main`、commit SHA，还是语义化版本？
