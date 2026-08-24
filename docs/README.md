# Hushine 文档

最后核验：2026-08-25。

当前文档按使用目的分为三块。日期化 Superpowers/OpenSpec 文件是设计与决策记录，
不作为部署或用户操作入口。

## 1. 基础运维

- [`production-deploy-checklist.md`](production-deploy-checklist.md)：数据库、Kafka、ELK、
  Jaeger、服务和 Runtime 镜像的部署与验收
- [`local-docker.md`](local-docker.md)：本机完整 Docker 基础设施和 coverage 启动
- [`../db/README.md`](../db/README.md)：一次性数据库 baseline、owner 和生成 bundle
- [`runtime-operator-flow.md`](runtime-operator-flow.md)：Hosted/Self-hosted/Bare Runtime
  的启动、心跳、恢复和 worker restart

## 2. 代码结构和逻辑

- [`../README.md`](../README.md)：多仓库服务图、端口和通信边界
- [`runtime-operator-flow.md`](runtime-operator-flow.md)：RuntimeChannel、agent/worker 隔离、
  Indicator 1024 分块与 finalization
- [`strategy-owned-futures-leverage.md`](strategy-owned-futures-leverage.md)：策略解析、
  Preview、Binance apply/readback、原子提交与 rollback
- [`spot-usdt.md`](spot-usdt.md)：Binance Spot asset/symbol、精确过滤器、订单、wallet、
  stop-and-close 与 reconciliation
- [`code-census/README.md`](code-census/README.md)：静态、单元覆盖率和页面采样方法

## 3. 用户手册

- [`user-manual.md`](user-manual.md)：从登录、Portfolio/Venue、Market Data、Strategy、
  Runtime 到 Session/通知的页面流程
- [`strategy-debugger-cli-smoke.md`](strategy-debugger-cli-smoke.md)：离线导入包和本地调试

发现文档与页面或代码不一致时，以当前测试通过的代码契约为准，并在同一修改中更新
这里的当前文档；不要继续链接已删除的验收快照或审计记录。
