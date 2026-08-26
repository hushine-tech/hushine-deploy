# Exchange Adapter 与 Funding Income

最后核验：2026-08-27。

## Capability routing

core-service 只按完整 route 调用：

```text
route → adapter.Registry → optional capability → canonical result
```

Funding 使用 `IncomeHistoryReader`、`FundingFactReader`、
`FundingSettlementCalculator` 和 canonical `UserDataEvent`。Registry 先拒绝 Spot，再绑定
route；common coordinator 不比较交易所名称。Binance Factory 拥有 USD-M 实现；OKX
Factory 对 Funding capability 返回 unsupported，因此需要 Funding 的 OKX Futures Session
在 preflight fail closed。

Binance Adapter 独占外部 URL、签名、限频/错误码、Income 分页、私有事件字段、公式和
舍入。scraper 的 Binance Adapter 独占历史 Funding/Premium 响应解析。通用 core、
control-panel、strategy-service 不得导入 Binance package 或复制这些规则。

## Canonical Account Update

一个 User Data Stream 同时承载 `order_update` 与 `account_update`：

- `order_update` 仍是 order/fill/commission/REALIZED_PNL 的唯一事实源；
- `account_update(reason=order)` 更新或核对精确持仓投影，不再生成 fill；
- `account_update(reason=funding_fee)` 冻结发生时持仓并触发 Income repair；它没有最终
  transaction ID，不能直接成为最终 Income；
- 其他 reason 不产生 Funding Income，也不终止共享 stream。

Spot 的 Account Update 不能进入 Funding。Funding 需要的活动/grace Futures route 与有
open order 的 route 取并集，所以没有挂单但有持仓的 Session 仍保持账户流。

## 精确 Funding facts 与计算

scraper 保存 exchange、market、symbol、真实 `funding_time`、decimal-string Funding
rate、decimal-string mark price 和可空的真实 next Funding time。批量响应只用下一条真实
记录补前一条时间；无法证明时保持空，不能按固定时长推导。

Binance USDT 线性 Futures Adapter 当前逐腿公式：

```text
leg_amount = -signed_quantity × mark_price × funding_rate
```

LONG quantity 为正，SHORT quantity 为负。ONE_WAY 使用 `BOTH`；HEDGE 必须分别计算
`LONG`/`SHORT` 后再求和。Cross/Isolated 不改变公式，只保留钱包归属。杠杆不直接进入
公式，默认 `1x` 只影响可建立仓位规模。

所有权威边界使用 decimal string 和 exact rational/NUMERIC。Demo/Live actual 总额存在
时，Adapter 把 exact residual 分配给绝对计算金额最大的 leg；并列按 symbol、position
side 稳定排序，保证 applied legs 严格等于 actual。Backtest 没有 actual，总 applied 等于
calculated。

## 单表、合并与原子性

`venue_income_entries` 是唯一 Income/Funding history 表；没有 Funding 子表或 wallet
ledger。一个 settlement 一行，逐腿 exact input/result 存在 `calculation_details`。交易所
transaction ID 与 deterministic settlement key 各有唯一约束。

Demo/Live 可先写 `pending_actual`，但不更新钱包。REST actual 到达时先查 exchange key，
再查 settlement key；命中同一 pending 后补 actual/raw payload 并变为 `confirmed`。两个
key 指向不同记录时 fail closed。Backtest 直接写 `calculated`。

Repository 在一个 PostgreSQL transaction 中锁 Session/Venue 与 wallet，写/确认 Income，
更新 Venue wallet、Portfolio aggregate、Session snapshot 和
`last_applied_income_entry_id`；失败全部 rollback。发生时间必须落在原 Session 半开区间，
迟到 Income 不能归属给后来复用同一 Venue 的 Session。离线变化不写 Session Income。
