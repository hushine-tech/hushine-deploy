# Hushine 文档

最后核验：2026-08-27。

当前文档按使用目的分为三块。日期化 Superpowers/OpenSpec 文件是设计与决策记录，
不作为部署或用户操作入口。

## 基础运维 / Operations

- [`operations/local-development.md`](operations/local-development.md)：本机 PostgreSQL/
  TimescaleDB、Kafka、ELK、Jaeger、一次性 schema bootstrap、服务和 coverage 启动
- [`operations/funding-income.md`](operations/funding-income.md)：Funding 支持矩阵、同步调度、
  监控告警、Mock Binance 与受保护的 Demo gate
- [`production-deploy-checklist.md`](production-deploy-checklist.md)：发布前的完整部署与验收清单
- [`local-docker.md`](local-docker.md)：本机 Docker 基础设施的详细配置
- [`../db/README.md`](../db/README.md)：一次性数据库 baseline、owner 和生成 bundle
- [`runtime-operator-flow.md`](runtime-operator-flow.md)：Hosted/Self-hosted/Bare Runtime
  的启动、心跳、恢复和 worker restart

## 代码结构与逻辑 / Architecture

- [`architecture/exchange-adapters.md`](architecture/exchange-adapters.md)：Registry capability、
  Binance/OKX 边界、精确 Funding 计算与 Income 原子入账
- [`architecture/runtime-channel.md`](architecture/runtime-channel.md)：Income 投递、持久化 cursor、
  blocked Worker、restart、Backtest 时间线与 Indicator 分块
- [`../README.md`](../README.md)：多仓库服务图、端口和通信边界
- [`strategy-owned-futures-leverage.md`](strategy-owned-futures-leverage.md)：策略解析、
  Preview、Binance apply/readback、原子提交与 rollback
- [`spot-usdt.md`](spot-usdt.md)：Binance Spot asset/symbol、精确过滤器、订单、wallet、
  stop-and-close 与 reconciliation
- [`code-census/README.md`](code-census/README.md)：静态、单元覆盖率和页面采样方法

## 用户手册 / User Manual

- [`user-manual/backtest.md`](user-manual/backtest.md)：Backtest、Funding 时间线、数据缺口、
  多 symbol 与订单语义
- [`user-manual/demo-live.md`](user-manual/demo-live.md)：Demo/Live、Funding 对账、Venue 模式、
  Telegram 与 worker restart
- [`user-manual.md`](user-manual.md)：登录、Portfolio/Venue、Market Data、Strategy、Runtime
  和 Session 的页面总览

发现文档与页面或代码不一致时，以当前测试通过的代码契约为准，并在同一修改中更新
这里的当前文档；不要继续链接已删除的验收快照或审计记录。
