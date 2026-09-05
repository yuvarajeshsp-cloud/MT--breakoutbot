# BreakoutStopBot

MT5 Expert Advisor implementing a short-timeframe candle breakout system: on
every new candle (M1, M3, or M5 — see `InpTimeframe`), it places a Buy Stop
above and a Sell Stop below the just-closed candle's high/low (OCO pair),
manages take-profit/stop-loss, moves the stop to breakeven once a position is
far enough in profit, closes any position still in floating loss at the next
candle close, and flattens everything once a day. An on-chart dashboard
shows today/week/month P/L and other live stats.

## Requirements

- **Hedging account.** Each filled stop order becomes its own position with
  its own SL/TP. This EA has not been validated on netting accounts (only one
  net position per symbol) and will log a warning on `OnInit` if the account
  isn't in `ACCOUNT_MARGIN_MODE_RETAIL_HEDGING`.
- Run on a chart matching `InpTimeframe`. The EA reads candle data for that
  timeframe internally regardless of the chart's own period, but relies on
  `iTime()` changing to detect new bars — run it on a matching chart so tick
  delivery lines up as expected.

## Logic

Every tick:
1. **Daily flatten check** — see Daily Flatten below.
2. **OCO enforcement** — if one pending stop order of the current pair filled
   or disappeared while the other is still pending, the sibling is cancelled.
3. **Breakeven** — for each open position, if floating profit has reached
   `InpBreakevenTriggerPips`, the real stop loss moves to
   `entry ± (current spread + InpBreakevenBufferPips + InpLatencyBufferPips)`,
   locking in a small guaranteed profit. Recomputed idempotently every tick
   from position state (no separate "already armed" flag), so it's safe
   across EA restarts and self-heals if a modify is rejected.

On every new candle (once, at the bar's first tick):
1. **Drawdown close** — decides whether to cut a losing position early rather
   than wait for the fixed stop loss; behavior depends on
   `InpDrawdownCloseMode` (see Drawdown Close Modes below).
2. **Stale order cleanup** — the previous bar's Buy Stop / Sell Stop are
   cancelled if they never filled.
3. **New OCO pair** — if spread, session, and volume filters pass and the EA
   is below `InpMaxConcurrentPositions`, a fresh Buy Stop is placed at
   `previous candle high + InpEntryBufferPips` and a fresh Sell Stop at
   `previous candle low − InpEntryBufferPips`, each with its own
   `InpTakeProfitPips` / `InpStopLossPips` sent as the order's real SL/TP.

On a timer (every `InpDashboardRefreshSeconds`) and after each new candle's
maintenance pass, the on-chart dashboard recalculates from trade history and
current positions.

## Inputs

| Input | Default | Description |
|---|---|---|
| `InpTimeframe` | M1 | Candle timeframe the breakout logic runs on; only M1, M3, M5 are selectable |
| `InpTakeProfitPips` | 100 | Take profit distance from entry, in pips |
| `InpStopLossPips` | 50 | Stop loss distance from entry, in pips |
| `InpBreakevenTriggerPips` | 20 | Floating profit needed before breakeven arms |
| `InpBreakevenBufferPips` | 0.25 | Extra pips locked in beyond spread at breakeven |
| `InpLatencyBufferPips` | 1.0 | Extra pips added to the breakeven lock to survive round-trip order latency to your broker |
| `InpEntryBufferPips` | 0 | Offset added beyond the prior candle's high/low |
| `InpPendingExpiryMinutes` | 0 | Pending order expiry; 0 = GTC (orders are replaced every bar regardless) |
| `InpUseRiskPercent` | false | Use risk-percent position sizing instead of a fixed lot |
| `InpRiskPercent` | 1.0 | Risk per trade, % of account balance (if `InpUseRiskPercent`) |
| `InpLotSize` | 0.01 | Fixed lot size (if not using risk-percent sizing) |
| `InpMaxConcurrentPositions` | 3 | Cap on simultaneously open positions from this EA |
| `InpMaxSpreadPips` | 3.0 | Skip placing new stops this bar if spread exceeds this; `0` disables the filter |
| `InpDrawdownCloseMode` | Min Threshold | How to decide when to close a losing position early (see Drawdown Close Modes below) |
| `InpDrawdownMinLossPips` | 3.0 | (Min Threshold mode) Close only once the loss exceeds this many pips |
| `InpDrawdownGraceCandles` | 2 | (Wait N Candles mode) Consecutive negative closes allowed before closing |
| `InpDrawdownPercentOfSL` | 50.0 | (Percent of SL mode) Close once loss reaches this % of `InpStopLossPips` |
| `InpUseSessionFilter` | false | Restrict new stop placement to a server-time window |
| `InpTradingStartHour` / `InpTradingEndHour` | 0 / 24 | Session window (server time, hour granularity) |
| `InpUseVolumeFilter` | true | Only place new stops when the closed candle's tick volume is above the recent average |
| `InpVolumeLookbackBars` | 20 | Number of prior candles averaged for the volume comparison |
| `InpMinVolumeRatio` | 1.0 | Required ratio: candle volume must be ≥ this × the lookback average |
| `InpSlippagePips` | 2 | Max slippage allowed for market operations (e.g. drawdown close) |
| `InpMagicNumber` | 20260904 | Identifies this EA's orders/positions |
| `InpCancelPendingOnRemove` | true | Cancel this EA's pending stop orders when it's removed from the chart |
| `InpShowDashboard` | true | Show the on-chart P/L dashboard |
| `InpDashboardRefreshSeconds` | 5 | How often the dashboard recalculates from trade history |
| `InpUseDailyFlatten` | true | Close all positions and cancel all pending orders once per day |
| `InpDailyFlattenHour` | 0 | Server-time hour to flatten everything; 0 = midnight |

## Dashboard

When `InpShowDashboard` is enabled, a panel appears in the chart's top-left
corner (rendered as chart objects, prefixed `BOS_DASH_`, removed automatically
on `OnDeinit`) showing:

- Account balance / equity and current spread / open position count
- **Today**, **Week** (Monday–now), and **Month** (1st–now) realized P/L and
  trade counts, computed from `HistorySelect` filtered to this EA's symbol
  and magic number
- Current floating P/L across this EA's open positions
- Win rate for the week and month

It updates on a timer (`InpDashboardRefreshSeconds`) and after each new
candle's maintenance pass, and works in the Strategy Tester's visual mode as
well as live/demo charts.

## Daily Flatten

With `InpUseDailyFlatten` enabled (default), the EA closes every open
position and cancels every pending order it owns once per calendar day, the
first time the server-time hour reaches `InpDailyFlattenHour` (default 0 =
midnight). It's checked every tick for prompt firing, tracked so it only
fires once per day, and simply resumes normal candle-by-candle operation
afterward — it's a one-time flatten, not a trading pause (use
`InpUseSessionFilter` / `InpTradingStartHour` / `InpTradingEndHour` if you
also want to block new entries during a window).

## Install

1. Copy `MQL5/Experts/BreakoutStopBot.mq5` and the
   `MQL5/Include/BreakoutStopBot/` folder into your terminal's `MQL5/Experts`
   and `MQL5/Include` directories (Data Folder → `MQL5/`) — **not** into a
   subfolder that nests another `MQL5/Experts/...` inside it. If you clone
   this whole repo directly under your terminal's `MQL5/Experts/`, the
   `Include/BreakoutStopBot/` folder ends up one level too deep for the
   include paths to resolve; the `.mq5` uses relative includes
   (`../Include/BreakoutStopBot/...`) specifically so the repo layout still
   works as long as `MQL5/Experts/BreakoutStopBot.mq5` and
   `MQL5/Include/BreakoutStopBot/*.mqh` keep that same relative position to
   each other, wherever the repo folder itself sits.
2. Compile `BreakoutStopBot.mq5` in MetaEditor and check the **Errors** tab
   shows 0 errors — if includes can't be found, the old `.ex5` on disk is
   left untouched and MT5 will keep running stale behavior without any
   obvious warning.
3. **Remove and re-attach the EA** on the chart after recompiling — MT5 does
   not hot-reload a running EA instance's code, so a chart that already had
   the EA attached before you recompiled will keep executing the old binary
   until you detach and re-attach it (or restart the terminal).
4. Attach to a chart matching `InpTimeframe` (M1/M3/M5), enable AutoTrading,
   set inputs. Check the **Experts/Journal** log for the
   `BreakoutStopBot init: ...` line printed on startup — it echoes the
   active timeframe, TP/SL, breakeven trigger, volume filter, session
   filter, and daily flatten settings, so you can confirm what's actually
   running.

## Drawdown Close Modes

A freshly-opened position is valued at the opposite side of the spread from
where it entered (bought at Ask, marked to market at Bid), so it typically
starts out slightly negative from spread alone, independent of whether the
trade idea was any good. `InpDrawdownCloseMode` controls how much room a
losing position gets before it's cut, rather than left to run to the real
stop loss:

- **Any Loss** (`DRAWDOWN_CLOSE_ANY_LOSS`, the original behavior): closes on
  any floating loss at all, however small. Simple, but can realize a small
  loss on ordinary spread noise before a trade has any real chance to
  develop — this is a likely contributor if you see more/smaller losing
  trades on realistic spread data than on tighter backtest conditions.
- **Min Threshold** (`DRAWDOWN_CLOSE_MIN_THRESHOLD`, default): only closes
  once the loss exceeds `InpDrawdownMinLossPips`. Set this above your typical
  spread so ordinary noise doesn't trigger it, but a real adverse move still
  does.
- **Wait N Candles** (`DRAWDOWN_CLOSE_WAIT_CANDLES`): only closes if the
  position has been negative at `InpDrawdownGraceCandles` *consecutive*
  candle closes in a row — a candle where it's no longer negative resets the
  count. Gives a trade time to develop before being judged.
- **Percent of SL** (`DRAWDOWN_CLOSE_PERCENT_OF_SL`): closes once the loss
  reaches `InpDrawdownPercentOfSL`% of `InpStopLossPips`, scaling
  automatically with whatever SL you configure.

All three non-original modes compare against the position's floating loss in
pips (not currency), computed from entry vs. current Bid/Ask in the losing
direction. Switching modes, or changing `InpStopLossPips`, takes effect
immediately on the next candle close — no restart needed.

## Backtesting: "Every tick" vs "Every tick based on real ticks"

These two Strategy Tester modes can show very different results for the same
EA and inputs, and that gap is itself meaningful information, not a bug:

- **"Every tick" (generated)** synthesizes intrabar price movement from OHLC
  bars using MT5's own interpolation, not real historical bid/ask data. For a
  system whose entries depend on exact price levels (a breakout stop-entry
  system, here), this can be more forgiving than reality — smoother paths,
  no real spread-widening events, no genuine quote gaps.
- **"Every tick based on real ticks"** replays actual historical tick data
  for the symbol, when your broker/data source has it. This is the closest
  the Strategy Tester gets to real execution.

If a strategy is profitable under generated ticks but draws down under real
ticks, that's the real-tick run telling you the apparent edge was likely an
artifact of synthetic data, not a real, repeatable market pattern — treat the
real-tick result as the credible one, and don't keep adjusting inputs just to
make the generated-tick run look good again; that's fitting noise, not
finding an edge.

**Calibrating for your actual latency**: the Strategy Tester's "Delays"
setting (in the tester's configuration panel, alongside the "Modelling"
dropdown) simulates the round-trip delay between the EA deciding to act and
that action landing on the broker's server. Set it to your real observed
ping to the broker (e.g. 145ms) so the backtest reflects your actual
execution conditions. This matters most for `ManageBreakeven()`'s
`trade.PositionModify()` calls and `CloseDrawdownPositions()`'s
`trade.PositionClose()` calls — both compute a target price from the current
tick, then send a request that only takes effect after the round trip, by
which point price may have moved. `InpLatencyBufferPips` widens the
breakeven lock specifically to survive that gap; there's no equivalent needed
for pending Buy Stop/Sell Stop orders, since those are triggered by the
broker's own server-side price feed once resting, not by the EA's client-side
timing.

No amount of latency-buffer tuning turns a strategy without a real edge into
a profitable one, though — it only makes the EA's own order handling honest
about a real, fixed constraint (your connection). If real-tick backtests
stay unprofitable after this, that's a signal about the strategy itself, not
something to engineer around with more parameters.

## Known limitations / risks

- **Tick volume, not exchange volume**: `InpUseVolumeFilter` uses MT5 tick
  volume (count of price changes per candle), since most forex/CFD brokers —
  including most gold CFD symbols — report zero real/exchange volume, which
  would silently block all trading forever if the filter required it. Tick
  volume is a reasonable proxy for activity but isn't literal traded volume.
- **Weekend / news gap risk**: resting stop orders through low-liquidity
  periods can fill with large slippage. Consider adding a news-avoidance or
  Friday-close-avoidance guard if you trade through those windows —
  not currently implemented.
- **Netting accounts**: not supported — multiple simultaneous positions with
  independent SL/TP require a hedging account.
- **Broker stop/freeze levels**: pending order and SL/TP prices are clamped to
  the symbol's minimum stop distance (`SYMBOL_TRADE_STOPS_LEVEL`), which can
  shift the actual entry away from the exact candle high/low on some
  brokers/symbols when the market is very close to those levels.
- **Real broker-side SL/TP means the lines are visible on chart**: MT5 draws
  the SL/TP/entry lines for any order that has them set. This version always
  sets real SL/TP, so those lines will show.
- **High-frequency stop placement**: a breakout system re-arming every minute
  is very sensitive to spread and slippage costs; backtest with realistic
  spread/commission modeling before running live.
- **Strategy Tester spread**: in "Every tick" (generated) mode without real
  tick data, MT5 synthesizes bid/ask using the symbol's default spread
  setting, which can be unrealistically wide (tens of pips) and cause
  `InpMaxSpreadPips` to block every bar. Use "Every tick based on real ticks"
  when available, or temporarily set `InpMaxSpreadPips = 0` to disable the
  filter while debugging the rest of the logic.
