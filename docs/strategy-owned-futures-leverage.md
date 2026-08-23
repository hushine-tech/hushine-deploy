# Strategy-owned Futures leverage

Last verified: 2026-08-24.

This is the current repository guide for strategy-declared Futures leverage.
The current product/operator source of truth is the `量化交易系统文档` tree,
specifically `1 基础运维`, `2 代码结构和逻辑`, and `3 用户手册`. The archived
`B.4 Runtime Management` page is not current authority. Dated Superpowers
specifications and plans, archived OpenSpec changes, and Account-era documents
are historical records, not current operating instructions.

## Authority and declaration contract

The strategy source is the only leverage-intent authority. Start Demo,
Backtest, and Resume have no editable leverage field. Legacy HTTP and protobuf
request fields remain decodable for compatibility, but the gateway and new
runtime path send/consume zero and do not let those fields override the
strategy.

For each Futures `ORDER_TARGETS` entry, precedence is:

1. `ORDER_TARGETS[].leverage`;
2. class-level `LEVERAGE`;
3. platform default `1x`.

Both declaration forms must be Python literal positive integers. Booleans,
zero, negatives, floats, strings, non-finite values, and dynamic expressions
are rejected during strategy validation. A Spot target cannot declare
`leverage`. A Spot-only strategy cannot declare class-level `LEVERAGE`; a
mixed Spot/Futures strategy may declare it, and it applies only to the Futures
targets.

```python
class MyStrategy:
    LEVERAGE = 5

    ORDER_TARGETS = [
        {
            "exchange": Exchange.BINANCE,
            "market": Market.PERPETUAL_FUTURES,
            "symbol": "BTCUSDT",
        },
        {
            "exchange": Exchange.BINANCE,
            "market": Market.PERPETUAL_FUTURES,
            "symbol": "ETHUSDT",
            "leverage": 10,
        },
        {
            "exchange": Exchange.BINANCE,
            "market": Market.PERPETUAL_FUTURES,
            "symbol": "ZECUSDT",
        },
    ]
```

The resolved facts are:

| Symbol | Effective leverage | Source |
|---|---:|---|
| `BTCUSDT` | `5x` | `strategy_default` |
| `ETHUSDT` | `10x` | `order_target` |
| `ZECUSDT` | `5x` | `strategy_default` |

If both declarations are absent, a Futures target resolves to `1x` with
source `platform_default`. Downstream services consume the validator's
`effective_leverage` and `leverage_source`; they do not recompute precedence.

## Read-only Preview

Preview runs in a temporary one-shot Python worker. The worker loads and
validates the current active strategy, resolves declarations, and asks
core-service for preflight facts through the authenticated RuntimeChannel
proxy. It exits after the response and never becomes a strategy session
worker.

For every Futures target the page shows the effective value, source, current
exchange value, and whether Start needs a change, for example:

```text
BTCUSDT  5x   Strategy default   Current: 3x   Will change on start
ETHUSDT 10x   Target override    Current: 10x  No change
ZECUSDT  5x   Strategy default   Current: 2x   Will change on start
```

Spot targets show no leverage row. Preview is strictly read-only: it performs
no Binance leverage POST, acquires no target admission, writes no launch
journal or outbox row, creates no Session, and writes no Session target facts.
A failed target read blocks Start and remains visible with its structured code,
route, source, and retryability.

## Start: prepare, commit, then final worker

Start does not trust an earlier preview. It uses this order:

1. runtime-agent creates a canonical `session_id` and independent
   `launch_operation_id`.
2. A temporary one-shot preparation worker reloads the current active strategy,
   repeats validation and preflight, and returns an immutable manifest with the
   strategy source SHA-256, declarations, target leverage intents, routes,
   symbols, Session metadata, and risk controls. It does not enter user strategy
   execution.
3. runtime-agent sends a typed `CommitStrategySessionStart` platform call over
   RuntimeChannel. control-panel-service authenticates the runtime/user,
   overwrites runtime identity from the authenticated route, and relays the
   typed request. It does not calculate precedence or receive a caller-selected
   internal endpoint.
4. core-service re-resolves Portfolio/Venue facts and validates the target
   manifest. For Demo Futures it acquires admission on
   `(exchange, environment, credential_fingerprint, market, symbol)` before any
   exchange change. Reusing the same credential through another Venue does not
   bypass the conflict key.
5. Targets are processed in stable route/symbol order. core-service reads the
   current leverage, durably journals the rollback obligation before a POST,
   changes only mismatched symbols, and reads back every target. An unchanged
   target is still read back and confirmed.
6. Only after every target is confirmed, one database transaction inserts the
   pending Session with deprecated scalar `0`, inserts per-target facts,
   transfers admission holders from the operation to `session_id`, and marks
   the launch operation committed.
7. runtime-agent reads the committed Session back, verifies its identity and
   facts, constructs a typed bootstrap, and only then creates the final Python
   session worker.
8. The final worker reloads the strategy and fails closed unless its source
   digest, target set, effective values/sources, Venue/environment bindings,
   confirmed leverage, and canonical wallet risk metadata all match the
   bootstrap. It publishes `running` only after startup succeeds.

The final worker therefore never starts on preview facts, an uncommitted
Session, or a collapsed session-wide leverage value.

## Failure, rollback, and recovery

`LEVERAGE_ADMISSION_CONFLICT`, `LEVERAGE_QUERY_FAILED`,
`LEVERAGE_SET_FAILED`, and `LEVERAGE_CONFIRMATION_FAILED` stop the launch. If
an earlier symbol may have changed, core-service rolls changed targets back in
reverse order and reads each one back. A confirmed rollback releases the
operation's admissions; no runnable Session is created.

If any rollback cannot be confirmed, the returned code is
`LEVERAGE_ROLLBACK_FAILED`. The launch and admissions remain
`recovery_required`, affected symbols remain visible, and a
`strategy.leverage_rollback_failed` notification is placed in the durable
outbox. The outbox dedupe key is the `launch_operation_id`, so retrying delivery
cannot fan out duplicate warnings for the same operation. Operators must not
describe this state as “the account was unchanged.”

A successfully started Session does not restore Binance leverage when it
finishes; an open position can still depend on that configuration. Terminal
Session handling releases target admission. Runtime loss marks active Sessions
`recoverable` and deliberately retains their target admissions. Resume creates
a new Session and carries the user-selected predecessor as an explicit
`resume_session_id`; ordinary Start never infers or takes over a Session.
core-service validates that predecessor against the same user, Portfolio,
environment, strategy, and stopped/recoverable source status. In one database
transaction it changes a recoverable predecessor to `stopped` with
`SESSION_SUPERSEDED_BY_RESUME`, releases its admissions, and acquires the new
launch admissions. Any new admission conflict rolls the whole transaction
back, leaving the predecessor recoverable and still protected. The user still
selects a routable runtime, the original strategy must be active for the
read-only preview, and Start reloads current code and repeats preparation,
apply/readback, facts, and bootstrap. The predecessor remains audit history
and is never changed back to `running`.

## Environment and runtime boundaries

| Environment/path | Leverage behavior |
|---|---|
| Backtest (`environment=0`) | Uses the same declaration resolver and simulated Futures wallet metadata. It performs no Binance call and acquires no live admission; committed facts are simulated as confirmed. |
| Demo (`environment=1`) | Reads and, on Start only, changes Binance Futures leverage per declared symbol. |
| Live (`environment=2`) | Remains rollout guarded and fails closed. |
| Spot | Has no leverage intent, preview row, Binance leverage call, or Session leverage fact. |
| strategy-debugger-cli | Reuses the same offline replay/declaration resolution and simulated wallet semantics. It has no leverage override and makes no Binance call. |

Session routing uses only `runtime_id`. Hosted, self-hosted, and guarded bare
runtimes call typed platform methods through RuntimeChannel. They do not
receive core-service, order, PostgreSQL, Kafka, credential, or internal endpoint
addresses. Venue credential resolution and Binance calls remain in
core-service.

## Durable schema and historical reads

The portfolio schema owns these additive objects:

| Migration | Objects/meaning |
|---|---|
| `0006_strategy_owned_futures_leverage.sql` | `strategy_launch_operations`, per-target `strategy_leverage_apply_attempts`, credential/symbol `strategy_target_admissions`, and authoritative `strategy_session_target_facts`. |
| `0007_strategy_leverage_notification_outbox.sql` | Crash-safe, operation-deduplicated rollback-failure delivery. |
| `0008_strategy_session_deprecated_leverage_zero.sql` | Relaxes `chk_strategy_sessions_leverage` from `> 0` to `>= 0`; it does not change the column default or rewrite history. |

`strategy_sessions.leverage` remains wire/schema-compatible with default `1`
for historical readers. Zero has a narrow meaning: a new coordinated Session
does not claim one session-wide leverage. New Futures Sessions read
`strategy_session_target_facts`; mixed targets must never be flattened to the
scalar. New Spot-only coordinated Sessions also store zero and expose no
Futures leverage. Only a historical Session with no target facts may display a
positive legacy scalar. Negative values remain invalid.

Generate deployment SQL only with
`hushine-deploy/scripts/db/render-schema-bundle.sh`. Do not hand-edit
`db/generated/portfolio.sql`, remove applied ledger entries, or delete launch,
fact, admission, or outbox history to recover an operation.

## UI and test-strategy behavior

Start Demo, Backtest, Portfolio Resume, and Session-detail Resume contain no
leverage input and do not send leverage in new requests. The Preview list is
the user's notice of changes that Start may make; clicking Start is the
confirmation. Apply is single-flight and the result keeps per-target status,
previous/current/confirmed values, structured errors, and rollback state.
Session detail prefers durable target facts and labels the old scalar only as
`Historical session / Legacy session value` when facts are absent.

The current BTC/ETH/ZEC functional template
`strategy-service/strategy_templates/btc_eth_zec_cross_momentum.py` declares
standard `LEVERAGE = 10`. It sizes each target from the canonical confirmed
metadata and `wallet_balance * 1%`, accepts only canonical margin mode `cross`,
and has no `REQUIRED_LEVERAGE` or raw `CROSSED` compatibility branch. Its
active-issue set emits a warning once while the same account, symbol, or sizing
problem persists; after recovery, a later recurrence may warn again.

## Verification references

The implementation was inspected at these exact code commits:

| Repository | Commit |
|---|---|
| `strategy-library` | `cb89b4c3413f6cd9bba4aab2da589862c048ba76` |
| `strategy-service` | `eb18951b7542621e69a283d24040b1dd4dd81966` |
| `core-service` | `2f710a8c252299b11abb8626a630db79c07288cf` |
| `control-panel-service` | `ada3ab0614fbec84e8420a0c1ded5fac11e4108b` |
| `quant-handler` | `74575981de53f5cb4313171895718d03d2ff4d0c` |
| `quant-frontend` | `6e59bd1a5c55e65a0041722fffae07996b90be54` |
| `strategy-debugger-cli` | `652c09bf1aab5f1bad9fbd4a14adfeaf02731264` |

These references establish the code inspected for this guide; release owners
must update them when behavior changes.
