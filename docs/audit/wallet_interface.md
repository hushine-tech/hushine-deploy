# Wallet Interface

日期：`2026-04-18`，最后整理：`2026-04-26`

状态：`Phase C / C2b` 已落地；`mode=0` 与 `mode=2` 已收敛到同一 `BinanceWalletRuntime`，`C3` 已进入对账校正 / 稳定化阶段。

目的：

- 统一 `core-service -> strategy-service -> runtime wallet` 的接口分层
- 明确 canonical 字段、provider raw 边界、以及各字段的使用场景
- 作为 `Phase B` 收尾后的接口与行为基线文档

## 1. 设计原则

| 规则 | 说明 | 使用场景 |
| --- | --- | --- |
| 严格 canonical ingress | `strategy-service` 接口层只消费 canonical 字段，不在入口层做 alias fallback。 | `GetPortfolioSnapshot` / venue snapshots 进入 `strategy-service` 时。 |
| 兼容从主路径移除 | 旧字段/旧结构只允许出现在 provider raw 或历史归档中；主代码不再经过 `LegacyWalletAdapter`。 | `core-service` raw → canonical、历史归档 / 审计。 |
| `mode` 是唯一运行时选择键 | `0 -> BinanceWalletRuntime`，`2 -> BinanceWalletRuntime`，`1 -> fail-closed`。 | `RunStrategy` / HTTP backtest 启动前选择钱包实现。 |
| 运行时接口围绕行为定义 | 统一暴露余额读取、价格更新、订单事件处理、快照导出，不直接暴露 provider raw schema。 | 策略运行、订单回写、状态同步。 |
| oracle/computed 边界显式化 | 尚未本地等价重算的字段保留 exchange/oracle 值，不允许用 legacy 近似值冒充 Binance 对齐结果。 | `mode=2` testnet 验证阶段。 |
| 生命周期事件必须有稳定身份 | `NEW / PARTIALLY_FILLED / CANCELED / EXPIRED` 这类 order lifecycle 事件必须带显式 `order_id`；只有直接 `FILLED` 的即时成交路径可以省略。 | futures / spot open-order state machine。 |

## 2. 分层接口总览

| 层级 | 主要类型 | 生产者 | 消费者 | 作用 | 兼容规则 |
| --- | --- | --- | --- | --- | --- |
| 跨服务 proto contract | `AccountWalletState` / `FuturesWallet` / `FuturesPosition` / `SpotWallet` / `SpotAsset` | `core-service` | `strategy-service` | 服务间传输的钱包快照 | 对外可暂时保留旧字段，但 `strategy-service` 新入口只读 canonical 字段 |
| strategy canonical state | `CanonicalAccountState` / `CanonicalFuturesState` / `CanonicalFuturesPositionState` / `CanonicalSpotState` | `wallet_adapter.py` | `wallet_factory.py` / runtime 实现 | Python 内部标准状态 | 不做 legacy fallback |
| runtime protocol | `WalletRuntime` | `strategy-service` | `grpc_server.py` / `StrategyEngine` / `account_client.py` | 统一运行时能力接口 | 所有 runtime 都必须满足 |
| mode=0 runtime | `BinanceWalletRuntime` | `wallet_factory.py` | 策略引擎 / 快照回写 | backtest 与 testnet 共用 Binance runtime | 不再走 legacy adapter |
| mode=2 runtime | `BinanceWalletRuntime` | `wallet_factory.py` | 策略引擎 / 快照回写 | Binance testnet / reconciliation 主路径 | 旧 `BinanceParityWallet` alias 已删除 |

## 3. 运行时选择

| `account.mode` | 运行时实现 | 状态 | 使用场景 |
| --- | --- | --- | --- |
| `0` | `BinanceWalletRuntime` | 启用 | 回测、HTTP / gRPC backtest 共用 Binance runtime |
| `1` | 无，明确报错 | fail-closed | live 暂不开放，防止误用未验证 runtime |
| `2` | `BinanceWalletRuntime` | 启用 | Binance futures testnet / reconciliation 主路径 |
| 其他 | 无，明确报错 | unsupported | 未来新交易所/新环境接入前不得静默回退 |

## 4. `WalletRuntime` 协议

### 4.1 属性

| 属性 | 类型 | 含义 | 使用场景 |
| --- | --- | --- | --- |
| `mode` | `int` | 当前钱包实现对应的账户模式 | 路由、审计、快照回写 |
| `futures` | `object` | 期货账本对象 | 策略读取仓位、账户余额、订单结算 |
| `spot` | `object` | 现货账本对象 | 策略读取现货资产、估值、订单结算 |

### 4.2 方法

| 方法 | 返回值 | 含义 | 使用场景 |
| --- | --- | --- | --- |
| `get_total_value()` | `float` | 账户总价值，当前口径为 `futures.margin_balance + spot estimated value` | UI 展示、快照回写、总资产检查 |
| `get_wallet_balance()` | `float` | 运行时钱包余额读取口 | 账本余额读取、快照回写 |
| `get_available_balance()` | `float` | 运行时可用余额读取口 | 下单前余额检查、快照回写 |
| `on_market_data(symbol, symbol_type, price)` | `None` | 处理行情更新 | 每个 tick 先更新 mark price，再让策略读 wallet |
| `on_order(symbol, symbol_type, order_resp)` | `None` | 处理订单生命周期事件 | `NEW` / `PARTIALLY_FILLED` / `FILLED` / `CANCELED` / `EXPIRED` 下更新仓位、挂单占用与 spot/futures 锁定状态；非纯 `FILLED` 路径必须带显式 `order_id` |
| `on_ledger_event(event)` | `None` | 处理非成交账本事件 | funding fee、transfer、deposit、withdrawal 等直接更新 runtime 余额 |
| `to_canonical_state()` | `CanonicalAccountState` | 导出标准快照 | 回写 `core-service`、后续对账/审计 |

## 5. canonical 顶层账户字段

| 字段 | 层级 | 含义 | 计算方法（当前实现 / 约定） | 主要消费者 | 使用场景 |
| --- | --- | --- | --- | --- | --- |
| `mode` | `CanonicalAccountState` | 账户模式 | 不计算；由 `core-service` 账户元数据直接给出。 | `wallet_factory` | 选择 runtime 实现 |
| `total_value` | 顶层 | 总资产价值 | ingress：应由上游直接给出 canonical 值。`BinanceWalletRuntime` 目标导出口径：`futures.margin_balance + spot.get_estimated_value()`；若 spot 缺价格则 fallback `spot_estimated_value` 或 `free + locked`。 | UI / 快照回写 | 账户总值展示、审计 |
| `updated_at` | 顶层 | 快照时间 | 不计算；由上游快照时间直接透传。 | 审计 / 对账 | 时间点追踪 |
| `spot_estimated_value` | 顶层 | 现货估值 | ingress：由上游直接给出。runtime 导出时优先 `spot.get_estimated_value()`，无价格时 fallback `free + locked`。 | `BinanceWalletRuntime` | 现货估值 fallback、总值计算 |
| `futures_position_equity` | 顶层 | 期货权益展示值 | ingress：由上游直接给出。runtime 导出时取 `futures.margin_balance`。 | UI / 审计 | 当前实现中用于展示/审计 |
| `metrics_authoritative` | 顶层 | 这些展示指标是否为服务端权威值 | 不计算；由上游标记。当前 `BinanceWalletRuntime` 导出固定为 `False`，表示 runtime 自算值不是展示权威源。 | UI / 审计 | 区分 display metric 与 runtime 自算值 |

补充规则：

| 规则 | 说明 |
| --- | --- |
| canonical 顶层不再保留 `total_equity` | 账户总资产统一看 `total_value`；需要期货腿展示值时看 `futures_position_equity`。 |
| canonical 顶层不再保留余额类字段 | `wallet_balance`、`available_balance`、`margin_balance`、`unrealized_pnl` 统一只属于 `futures` 子账本；顶层若仍有 wire 兼容镜像，一律不作为 canonical 读取入口。 |

## 6. canonical 期货账户级字段

| 字段 | 层级 | 含义 | 计算方法（当前实现 / 约定） | 主要消费者 | 使用场景 |
| --- | --- | --- | --- | --- | --- |
| `margin_mode` | `CanonicalFuturesState` | `cross` / `isolated` | 不计算；由上游或 runtime 上下文直接给出。 | runtime / strategy | 决定保证金计算分支 |
| `position_mode` | 期货账户级 | `one_way` / `hedge` | 不计算；由上游或 runtime 上下文直接给出。 | runtime / strategy | 决定仓位 key 与方向解析 |
| `multi_assets_mode` | 期货账户级 | Binance 多资产模式开关 | ingress：由 `core-service` 明确给出。当前 `mode=2` 若该字段为 `true` 则 fail-closed，不构建 parity runtime。 | `wallet_factory` | 支持边界判断 |
| `portfolio_margin` | 期货账户级 | Binance 组合保证金模式开关 | ingress：由 `core-service` 明确给出。当前 `mode=2` 若该字段为 `true` 则 fail-closed，不构建 parity runtime。 | `wallet_factory` | 支持边界判断 |
| `initial_balance` | 期货账户级 | 账户初始余额 | 不计算；作为账户历史上下文直接透传。 | legacy / parity runtime | 初始化 cross 账户上下文 |
| `deposit_sum` | 期货账户级 | 累计入金 | 不计算；作为账户历史上下文直接透传。 | legacy / parity runtime | 历史余额上下文 |
| `withdrawal_sum` | 期货账户级 | 累计出金 | 不计算；作为账户历史上下文直接透传。 | legacy / parity runtime | 历史余额上下文 |
| `wallet_balance` | 期货账户级 | 期货钱包余额 | ingress：上游直接给出。runtime 中只受账本事件影响：成交、fee、funding、deposit、withdrawal、transfer；`mark_price` 更新不会改写它。 | runtime / strategy | 账本余额读取、快照回写 |
| `available_balance` | 期货账户级 | 期货可用余额 | `cross`：`max(0, total_cross_wallet_balance + unrealized_pnl - (total_position_initial_margin + total_open_order_initial_margin))`。`isolated`：`max(0, margin_balance - (total_position_initial_margin + total_open_order_initial_margin))`。 | runtime / strategy | 下单前可用余额检查 |
| `margin_balance` | 期货账户级 | 期货保证金余额 | 当前实现：`wallet_balance + unrealized_pnl`。 | parity runtime | 风险指标、账户权益计算 |
| `unrealized_pnl` | 期货账户级 | 账户级未实现盈亏 | 当前实现：`sum(pos.get_unrealized_pnl())`。 | parity runtime | 风险指标、`margin_balance` 计算 |
| `total_position_initial_margin` | 期货账户级 | 持仓初始保证金总和 | 当前实现：`sum(pos.position_initial_margin)`。仅统计已持仓部分，不含挂单占用。 | parity runtime | available balance / 风险计算 |
| `total_open_order_initial_margin` | 期货账户级 | 挂单初始保证金总和 | 当前实现：若 runtime 已跟踪本地 futures open orders，则按所有 active orders 的剩余开仓量和当前 `mark_price` 汇总；否则保留启动快照值。 | parity runtime | available balance / 对账 |
| `total_maint_margin` | 期货账户级 | 维持保证金总和 | 当前实现：`sum(pos.maint_margin)`。若 `risk_metadata[]` 足够，则按 bracket 本地重算；缺 metadata 时回退到 exchange/oracle 值。 | parity runtime | 风险监控 / liquidation parity |
| `total_cross_wallet_balance` | 期货账户级 | 全仓钱包余额 | ingress：上游直接给出。当前 `cross` 模式 runtime 刷新时会设为 `wallet_balance`。 | parity runtime | cross available balance 计算 |
| `total_cross_un_pnl` | 期货账户级 | 全仓未实现盈亏 | ingress：上游直接给出。当前 `cross` 模式导出时等于 `get_unrealized_pnl()`。 | parity runtime | cross available balance / 对账 |
| `risk_metadata[]` | 期货账户级 | 风险公式元数据 | ingress：由 `core-service` 从 `symbolConfig` / `exchangeInfo` / `leverageBracket` 抓取并透传。包含 precision、`tick_size`、`step_size`、brackets 等本地风险公式输入。 | parity runtime | `maint_margin` / `liquidation_price` 的 metadata-backed 计算 |

补充规则：

| 规则 | 说明 |
| --- | --- |
| canonical 期货层不再保留 `total_equity` | 期货权益统一使用 `margin_balance`；不再维护语义重复字段。 |
| backtest bootstrap | `cross` 启动时 `wallet_balance_0 = futures.initial_balance + deposit_sum - withdrawal_sum`；`isolated` 启动时 `wallet_balance_0 = Σ position.initial_balance + deposit_sum - withdrawal_sum`。 |
| `wallet_balance` 的变化边界 | 运行中 `wallet_balance` 只受账本事件影响；`on_market_data` 只会更新 `mark_price`、`unrealized_pnl`、`margin_balance`、`available_balance`，不会改写 `wallet_balance`。 |
| futures 开仓前置检查 | 策略层应读取 `get_available_balance()`，而不是 `get_wallet_balance()`；`wallet_balance` 是账本余额，不代表可立即开新仓的可用保证金。 |
| unsupported futures modes | `multi_assets_mode=true` 或 `portfolio_margin=true` 时，`mode=2` 直接 fail-closed；不再静默按 single-asset `USDT-M` 处理。 |

## 7. canonical 期货仓位级字段

| 字段 | 层级 | 含义 | 计算方法（当前实现 / 约定） | 主要消费者 | 使用场景 |
| --- | --- | --- | --- | --- | --- |
| `symbol` | `CanonicalFuturesPositionState` | 合约标的 | 不计算；标准化为大写 symbol。 | runtime / strategy | 仓位定位、事件路由 |
| `direction_key` | 仓位级 | 运行时内部 key：`one_way=0`，`hedge LONG=+1`，`hedge SHORT=-1` | `derive_position_key(position_mode, position_side, direction, position_qty)`：`one_way -> 0`；`hedge LONG -> +1`；`hedge SHORT -> -1`；缺失时再看 `direction` 或 `position_qty` 符号。 | runtime | 仓位字典 key，不直接对外暴露给用户策略 |
| `initial_balance` | 仓位级 | 仓位初始资金上下文 | 不计算；作为 isolated/legacy 初始化上下文直接透传。 | legacy / isolated 路径 | isolated 模式初始化 |
| `leverage` | 仓位级 | 杠杆 | 不计算；由 exchange 快照或账户配置直接给出。 | parity runtime / strategy | 保证金估算、下单检查 |
| `fee_rate` | 仓位级 | 手续费率 | 不计算；由账户配置/快照给出。成交时手续费以 `order_resp.fee` 扣减。 | parity runtime | 成交后费用扣减 |
| `mark_price` | 仓位级 | 标记价格 | 启动时来自 exchange 快照；运行中由 `on_market_data(symbol, "futures", price)` 更新。 | runtime / strategy | UPNL、notional、风险指标 |
| `position_qty` | 仓位级 | 带方向数量；long 为正，short 为负 | 启动时来自 canonical 快照；成交后按 signed fill 更新。开/加仓：`current_qty + fill_qty`；平/反手：先抵消，再决定剩余方向与数量。 | runtime / strategy | 仓位恢复、PnL、开平仓演算 |
| `entry_price` | 仓位级 | 开仓均价 | 开/加仓：`(abs(current_qty)*entry + abs(fill_qty)*fill_price) / (abs(current_qty)+abs(fill_qty))`；完全平仓后归零；反手后设为反手成交价。 | runtime / strategy | UPNL、break-even、风控 |
| `unrealized_pnl` | 仓位级 | 仓位未实现盈亏 | 当前实现：`0`（空仓或无 mark）否则 `position_qty * (mark_price - entry_price)`。 | parity runtime / 对账 | PnL 对齐 |
| `position_side` | 仓位级 | `LONG` / `SHORT` / `BOTH` | 启动时来自快照；导出时若缺失则按 `position_qty` 符号推断：正=`LONG`，负=`SHORT`，零=`BOTH`。 | runtime | hedge / one-way 方向解释 |
| `margin_mode` | 仓位级 | `cross` / `isolated` | 不计算；由快照或账户上下文直接给出。 | runtime | 仓位风险分支 |
| `notional` | 仓位级 | 名义价值 | 当前实现：若有 `mark_price`，则 `abs(position_qty) * mark_price`；否则保留 oracle 值。 | parity runtime | `initial_margin` / 风险计算 |
| `initial_margin` | 仓位级 | 当前总初始保证金需求 | 当前实现：`position_initial_margin + open_order_initial_margin`。当 runtime 已跟踪本地 open order 时，挂单部分按剩余开仓量和当前 `mark_price` 重算。 | parity runtime | 总 IM 展示、对账、字段对齐 |
| `position_initial_margin` | 仓位级 | 持仓初始保证金 | 只统计已持仓部分。当前实现：若有 `mark_price`，则 `notional / leverage`；否则保留 oracle 值。当 `open_order_initial_margin = 0` 时，它会与 `initial_margin` 相同；当挂单 IM 大于 0 时，两者会分离。 | parity runtime | 账户级 IM 汇总、对账 |
| `open_order_initial_margin` | 仓位级 | 挂单保证金占用 | 只统计未成交挂单占用。当前实现：若该 position 已有本地 tracked orders，则按剩余开仓量和 `mark_price` 重算；`reduce_only` / 纯平仓挂单不占用开仓保证金；若没有本地 order state，则保留启动快照值。 | parity runtime / 对账 | available balance、对账 |
| `maint_margin` | 仓位级 | 维持保证金 | 当前实现优先走 metadata-backed 本地公式：按 `notional` 选择 bracket，计算 `notional * maint_margin_ratio - cumulative`；缺 metadata 或无有效 bracket 时回退到 exchange/oracle 值。 | parity runtime / 风险 | liquidation parity、风险展示 |
| `isolated_wallet` | 仓位级 | 逐仓钱包余额 | 当前实现：以 `position.initial_balance` / 快照值为 seed，本地随 fill、fee、funding 和 isolated-scope transfer 演化；不再把 oracle 当作运行中主来源。 | parity runtime / 风险 | isolated 风险分析 |
| `liquidation_price` | 仓位级 | 爆仓价 | 当前实现优先走 metadata-backed 本地公式。`cross` 读取账户本地 `wallet_balance` 与其他仓位 `UPNL/MM`，`isolated` 读取本地 `isolated_wallet`；仅在缺 metadata 时保留 exchange/oracle 值。 | parity runtime / 风险 | liquidation parity、风险提示 |
| `break_even_price` | 仓位级 | 保本价 | 当前实现：由本地持仓 cost basis 维护；公式为 `entry_price + sign(qty) * carry_cost / abs(qty)`。同向加仓把 fee 加入 `carry_cost`；同向 partial close 按样本推断把 `-realized_pnl + close_fee` 摊入剩余仓位；full close 清零；flip 开启新生命周期。Binance 未公开完整公式，cross funding 无 position attribution 时只动 wallet balance，不动 break-even。 | parity runtime / UI | 仓位盈亏判断、展示 |

补充规则：

| 规则 | 说明 |
| --- | --- |
| `initial_margin` 和 `position_initial_margin` 不是同义词 | 前者是总 IM，后者是持仓 IM。两者在“没有挂单占用”时可以相等，但这不代表字段定义相同。 |
| 判断两者是否应相等，先看是否存在挂单占用 | 当 `open_order_initial_margin = 0` 时，两者通常相等；当挂单 IM 大于 0 时，`initial_margin` 不应再被视为 `position_initial_margin` 的别名。 |

## 8. canonical 现货字段

| 字段 | 层级 | 含义 | 计算方法（当前实现 / 约定） | 主要消费者 | 使用场景 |
| --- | --- | --- | --- | --- | --- |
| `free` | `CanonicalSpotState` | 可用现货余额 | 启动时来自快照。现货买入后：`free -= qty*fill_price + fee`；现货卖出后：`free += qty*fill_price - fee`。 | spot runtime / strategy | 现货买入余额检查 |
| `locked` | 现货账户级 | 冻结现货余额 | 当前实现：本地维护 quote-side 挂单冻结；买单 `NEW` 时锁定 quote，部分成交/撤单/过期时按剩余订单量释放。 | spot runtime / UI | 现货余额展示 |
| `assets[].symbol` | 现货资产级 | 资产标的 | 不计算；标准化为大写 symbol。 | spot runtime / strategy | 资产定位 |
| `assets[].qty` | 现货资产级 | 资产数量 | 启动时来自快照。买入后：`qty += fill_qty`；卖出后：`qty -= fill_qty`；若接近零则归零。 | spot runtime / strategy | 现货卖出数量检查 |
| `assets[].locked` | 现货资产级 | 资产冻结量 | 当前实现：本地维护 base-side 挂单冻结；卖单 `NEW` 时锁定 base，部分成交/撤单/过期时按剩余订单量释放。 | spot runtime / UI | 资产展示 |
| `assets[].avg_entry_price` | 现货资产级 | 持仓均价 | 首次买入：`avg_entry_price = fill_price`；继续买入：`(old_avg*old_qty + fill_price*fill_qty) / (old_qty + fill_qty)`；卖出不重算，清仓时归零。 | spot runtime / UI | 现货收益展示 |
| `assets[].price` | 现货资产级 | 最新估值价格 | 由 `on_market_data(symbol, "spot", price)` 设置。现货估值为 `qty * price`。 | spot runtime | 现货估值 / 总值计算 |

补充规则：

| 规则 | 说明 |
| --- | --- |
| spot 卖出前置检查 | 策略层应按 `assets[].qty - assets[].locked` 读取可卖数量，不能把已冻结 base 资产再次视为可卖。 |
| spot lifecycle 身份要求 | spot 的 `NEW / PARTIALLY_FILLED / CANCELED / EXPIRED` 事件必须带显式 `order_id`，否则 runtime 会 fail-closed，避免多笔同价同量订单互相覆盖。 |

## 9. 实现类与使用场景

| 实现 | 输入 | 输出 | 主要使用场景 | 说明 |
| --- | --- | --- | --- | --- |
| `BinanceWalletRuntime.from_canonical(state)` | `CanonicalAccountState` | Binance runtime | `mode=0` backtest、`mode=2` testnet | 当前主路径唯一 runtime 构造入口 |
| `to_canonical_state()` | runtime 内部状态 | `CanonicalAccountState` | 快照回写、后续对账 | 作为统一导出接口 |

## 10. 兼容字段与清理方向

| 旧字段/旧语义 | canonical 字段 | 接口层是否允许 fallback | 允许出现的位置 | 说明 |
| --- | --- | --- | --- | --- |
| `qty`（futures） | `position_qty` | 否 | 旧 proto mirror / provider raw | 期货标准层统一用 `position_qty`；`qty` 仅保留兼容镜像 |
| `margin_type` | `margin_mode` | 否 | provider raw mirror | 标准层统一用 `margin_mode` |
| `total_margin_balance` | `margin_balance` | 否 | provider raw / 审计 | 入口层不应再把 raw 字段当主字段消费 |
| `total_unrealized_pnl` | `unrealized_pnl` | 否 | provider raw / 审计 | 同上 |
| 模糊 `balance` | `wallet_balance` / `available_balance` / `margin_balance` | 否 | legacy 内部变量 | 新 contract 不再使用模糊余额名 |
| `marginRequired` | `initial_margin` / `position_initial_margin` / `open_order_initial_margin` | 否 | legacy 内部对象 | 新 contract 必须拆开语义 |

## 11. 当前状态与 `Phase B3` 结果

| 项目 | 当前状态 | `Phase B3` 结果 |
| --- | --- | --- |
| canonical contract | 已建立并收紧 | 顶层 summary-only，canonical ingress 不再接受 alias fallback |
| runtime protocol | 已建立并扩展 | 主路径统一使用 `get_wallet_balance()`，并新增 `on_ledger_event()` |
| `mode=0` runtime 路径 | 已切到 Binance runtime | HTTP / gRPC backtest 都走 `BinanceWalletRuntime`；`LegacyWalletAdapter` 已删除 |
| `mode=2` parity 路径 | 已完成 hydration + lifecycle parity | futures open-order margin、ledger events、isolated wallet、break-even、spot locked lifecycle 已本地化；unsupported futures modes fail-closed |
| B3 review 收尾 | 已完成 | lifecycle order events 缺 `order_id` 时 fail-closed；策略层 futures 开仓预检查改读 `available_balance`；spot 卖出预检查改读未冻结数量 |
| 接口层 fallback | 已收紧 | 缺 `position_qty` / `margin_mode` / `margin_balance` / `unrealized_pnl` 时直接报 contract error |
| 对账能力 | `C1` 已落地 | `mode=2` reconciliation、`reconciliation_runs`、ELK metrics logs、PeriodicSample 触发已进入代码 |

## 12. 推荐的接口使用方式

| 调用方 | 推荐读取方式 | 不推荐读取方式 | 原因 |
| --- | --- | --- | --- |
| `grpc_server.py` | `AccountWalletState -> CanonicalAccountState -> WalletRuntime` | 直接按 proto raw 字段拼 legacy wallet | 避免 provider schema 侵入运行时 |
| 策略引擎 | futures 开仓读 `wallet.get_available_balance()`；账本/展示读 `wallet.get_wallet_balance()`；spot 卖出读 `asset.qty - asset.locked`；统一通过 `wallet.on_market_data()` / `wallet.on_order()` / `wallet.on_ledger_event()` 更新状态 | 直接假设所有 runtime 都是 legacy `FutureWallet`，或把 `wallet_balance` 当作开新仓的可用保证金 | 为后续新 runtime 保留扩展面，并避免冻结资产/已占用保证金被误判为可用 |
| backtest / testnet runtime | `CanonicalAccountState -> BinanceWalletRuntime` | 分叉出新的 legacy runtime | 当前 `mode=0` / `mode=2` 已共享同一条 Binance runtime 主路径 |
| testnet parity 路径 | 读取 canonical 字段并显式区分 computed/oracle | 用 legacy 公式去补未完成 Binance 字段 | 会污染对账与后续替换路径 |
