# Trading Mode Matrix — 2026-08-28

Hermetic Binance mock and local service tests only; no real Binance API was called.

| Cell | Input | Expected | Actual | Evidence ID | Error / 误差 | Status |
| --- | --- | --- | --- | --- | --- | --- |
| SPOT-GTC-FULL | Spot LIMIT GTC, complete liquidity | FILLED; one intent/attempt/order/fill/lifecycle with exact identities | focused hermetic test passed | core-order-matrix | 0 | PASS |
| SPOT-GTC-PARTIAL | Spot LIMIT GTC, partial liquidity | PARTIALLY_FILLED remains open; exact partial fill persisted once | focused hermetic test passed | core-order-matrix | 0 | PASS |
| SPOT-IOC-PARTIAL | Spot LIMIT IOC, partial liquidity | Partial quantity settles and remainder expires | focused hermetic test passed | core-order-matrix | 0 | PASS |
| SPOT-FOK-FULL | Spot LIMIT FOK, complete liquidity | FILLED atomically with one exact fill | focused hermetic test passed | core-order-matrix | 0 | PASS |
| SPOT-FOK-ZERO | Spot LIMIT FOK, insufficient liquidity | EXPIRED with zero persisted fill | focused hermetic test passed | core-order-matrix | 0 | PASS |
| FUT-GTC-FULL | Futures LIMIT GTC, complete liquidity | FILLED; lifecycle identities persist exactly | focused hermetic test passed | core-order-matrix | 0 | PASS |
| FUT-GTC-PARTIAL | Futures LIMIT GTC, partial liquidity | PARTIALLY_FILLED remains open; later fill is recoverable | focused hermetic test passed | core-order-matrix | 0 | PASS |
| FUT-IOC-PARTIAL | Futures LIMIT IOC, partial liquidity | Partial quantity settles and remainder expires | focused hermetic test passed | core-order-matrix | 0 | PASS |
| FUT-FOK-FULL | Futures LIMIT FOK, complete liquidity | FILLED atomically with one exact fill | focused hermetic test passed | core-order-matrix | 0 | PASS |
| FUT-FOK-ZERO | Futures LIMIT FOK, insufficient liquidity | EXPIRED with zero persisted fill | focused hermetic test passed | core-order-matrix | 0 | PASS |
| FUT-REDUCE-CLOSE | Futures SELL reduce-only close | Intent, attempt, exchange order and fill retain reduce-only close facts | focused hermetic test passed | core-order-matrix | 0 | PASS |
| FUT-REJECT | Futures business rejection | Failed attempt persists; no exchange order, fill or lifecycle event | focused hermetic test passed | core-order-matrix | 0 | PASS |
| FUT-GTC-DELAYED | Futures GTC REST NEW then delayed websocket fill | Open order transitions to exact final fill without duplicate quantity | focused hermetic test passed | core-binance-mock/delayed-GTC-final | 0 | PASS |
| FUT-DUPLICATE | Repeated exchange trade report | Canonical trade identity is idempotent at lifecycle storage boundary | focused hermetic test passed | core-lifecycle/duplicate-trade | 0 | PASS |
| MODE-ONEWAY-CROSS | One-way Cross open, Funding, mark and reduce-only close | BOTH leg initial margin, PnL and wallet/margin/available balances reconcile | focused hermetic test passed | strategy-wallet/four-modes | 0 | PASS |
| MODE-ONEWAY-ISOLATED | One-way Isolated open, Funding, mark and reduce-only close | BOTH leg isolated Funding and all wallet balances reconcile | focused hermetic test passed | strategy-wallet/four-modes | 0 | PASS |
| MODE-HEDGE-CROSS | Hedge Cross simultaneous LONG/SHORT | Leg quantities, initial margin, realized/unrealized PnL, Funding and balances remain separate | focused hermetic test passed | strategy-wallet/four-modes | 0 | PASS |
| MODE-HEDGE-ISOLATED | Hedge Isolated simultaneous LONG/SHORT | Both isolated legs and all wallet balances reconcile independently | focused hermetic test passed | strategy-wallet/four-modes | 0 | PASS |
| MODE-INVALID-ONEWAY | One-way order declares LONG or SHORT | Fails before first intent/attempt/order persistence | focused hermetic test passed | core-order/invalid-position-side | 0 | PASS |
| MODE-INVALID-HEDGE | Hedge order declares BOTH | Fails before first intent/attempt/order persistence | focused hermetic test passed | core-order/invalid-position-side | 0 | PASS |
| MULTI-SYMBOL | BTCUSDT, ETHUSDT and ZECUSDT under all four Futures modes | Each symbol and hedge leg projects independently | focused hermetic test passed | core-position/BTC-ETH-ZEC-isolation | 0 | PASS |
| SPOT-SEMANTICS | Binance Spot order request | No position side, margin mode, leverage or reduceOnly field is sent to Binance Spot | focused hermetic test passed | core-binance/spot-request-semantics | 0 | PASS |
| SPOT-ASSET-WALLET | Spot fill and duplicate replay | Only base/quote/fee assets change by exact fill delta; no symbol-shaped pseudo asset appears | focused hermetic test passed | strategy-spot/asset-wallet-funding-leverage | 0 | PASS |
| SPOT-NO-FUNDING | Spot backtest timeline | Contains Klines only and has no Funding coverage/settlement requirement | focused hermetic test passed | strategy-spot/asset-wallet-funding-leverage | 0 | PASS |
| SPOT-NO-LEVERAGE | Spot-only strategy declares leverage | Validation fails because Spot has no leverage semantic | focused hermetic test passed | strategy-spot/asset-wallet-funding-leverage | 0 | PASS |
| FUNDING-DIRECT | Direct Historical Funding request | Creates the requested Funding stream without a companion | focused hermetic test passed | control-marketdata/historical-funding | 0 | PASS |
| FUNDING-COMPANION | Historical Futures Kline requested twice | Exactly one Funding companion exists per symbol | focused hermetic test passed | control-marketdata/historical-funding | 0 | PASS |
| FUNDING-SPOT-NONE | Historical Spot Kline | No Funding companion is created | focused hermetic test passed | control-marketdata/historical-funding | 0 | PASS |
| FUNDING-GAP | Open Futures leg with missing/incomplete Funding coverage | Backtest fails closed before strategy callback or settlement | focused hermetic test passed | strategy-backtest/funding-gap-and-retry | 0 | PASS |
| FUNDING-RETRY | Missing Funding is supplied and the same backtest is rerun | Retry settles once, advances cursor and then runs strategy callback | focused hermetic test passed | strategy-backtest/funding-gap-and-retry | 0 | PASS |
| FUNDING-THREE-DAY | Three days of Funding settlements with page-boundary replay | All three settlements emit/apply exactly once | focused hermetic test passed | strategy-backtest/three-day-funding | 0 | PASS |
| FUNDING-HEDGE-FORMULA | Hedge LONG and SHORT at same symbol | Each signed quantity is calculated separately as -qty*mark*rate, then summed | focused hermetic test passed | core-binance/funding-per-leg | 0 | PASS |
| ORDER-CLIENT-IOC | Strategy order client receives IOC partial then expired | Exact fill emits once and terminal remainder does not stay open | focused hermetic test passed | strategy-order-client/IOC-partial-expired | 0 | PASS |
| SPOT-WALLET-GTC-FULL | Spot GTC full lifecycle applied to wallet | Exact base/quote/fee asset delta; no open order remains | focused hermetic test passed | strategy-wallet/TIF-deltas | 0 | PASS |
| SPOT-WALLET-GTC-PARTIAL | Spot GTC partial lifecycle applied to wallet | Exact fill delta plus quote lock for remaining quantity | focused hermetic test passed | strategy-wallet/TIF-deltas | 0 | PASS |
| SPOT-WALLET-IOC-PARTIAL | Spot IOC partial-expired lifecycle applied to wallet | Exact partial fill delta and zero remaining lock | focused hermetic test passed | strategy-wallet/TIF-deltas | 0 | PASS |
| SPOT-WALLET-FOK-FULL | Spot FOK full lifecycle applied to wallet | Exact atomic fill delta; no open order remains | focused hermetic test passed | strategy-wallet/TIF-deltas | 0 | PASS |
| SPOT-WALLET-FOK-ZERO | Spot FOK zero-fill expiry applied to wallet | No asset mutation and no open order | focused hermetic test passed | strategy-wallet/TIF-deltas | 0 | PASS |
| FUT-WALLET-GTC-FULL | Futures GTC full lifecycle applied to wallet | Exact fee/wallet and position delta; no open order remains | focused hermetic test passed | strategy-wallet/TIF-deltas | 0 | PASS |
| FUT-WALLET-GTC-PARTIAL | Futures GTC partial lifecycle applied to wallet | Exact partial position/fee delta and remaining open order | focused hermetic test passed | strategy-wallet/TIF-deltas | 0 | PASS |
| FUT-WALLET-IOC-PARTIAL | Futures IOC partial-expired lifecycle applied to wallet | Exact partial position/fee delta and no open order | focused hermetic test passed | strategy-wallet/TIF-deltas | 0 | PASS |
| FUT-WALLET-FOK-FULL | Futures FOK full lifecycle applied to wallet | Exact atomic position/fee delta; no open order remains | focused hermetic test passed | strategy-wallet/TIF-deltas | 0 | PASS |
| FUT-WALLET-FOK-ZERO | Futures FOK zero-fill expiry applied to wallet | No wallet or position mutation and no open order | focused hermetic test passed | strategy-wallet/TIF-deltas | 0 | PASS |

Overall: **PASS**.
