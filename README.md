# BreakoutStopBot

MT5 Expert Advisor implementing a short-timeframe candle breakout system: on
every new candle (M1, M3, or M5 — see `InpTimeframe`), it places a Buy Stop
above and a Sell Stop below the just-closed candle's high/low (OCO pair),
manages take-profit/stop-loss, moves losing-risk to breakeven once a position
is far enough in profit, and closes any position still in floating loss at
the next candle close. An on-chart dashboard shows today/week/month P/L and
other live stats.

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
3. **Exit management** — depends on `InpUseVirtualExits` (see below):
   `ManageVirtualExits()` when enabled (default), `ManageBreakeven()` (moves
   the real broker-side SL) when disabled.

On every new candle (once, at the bar's first tick):
1. **Drawdown close** — any open position (from this EA) currently in
   floating loss is closed at market immediately, rather than waiting for the
   fixed stop loss.
2. **Trailing stop** — see Trailing Stop below.
3. **Stale order cleanup** — the previous bar's Buy Stop / Sell Stop are
   cancelled if they never filled.
4. **New OCO pair** — if spread, session, and volume filters pass and the EA
   is below `InpMaxConcurrentPositions`, a fresh Buy Stop is placed at
   `previous candle high + InpEntryBufferPips` and a fresh Sell Stop at
   `previous candle low − InpEntryBufferPips`, each with its own
   `InpTakeProfitPips` / `InpStopLossPips`.

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
| `InpEntryBufferPips` | 0 | Offset added beyond the prior candle's high/low |
| `InpPendingExpiryMinutes` | 0 | Pending order expiry; 0 = GTC (orders are replaced every bar regardless) |
| `InpReverseSignal` | false | Fade the breakout instead of following it (see Reverse Signal Mode below) |
| `InpUseRiskPercent` | false | Use risk-percent position sizing instead of a fixed lot |
| `InpRiskPercent` | 1.0 | Risk per trade, % of account balance (if `InpUseRiskPercent`) |
| `InpLotSize` | 0.01 | Fixed lot size (if not using risk-percent sizing) |
| `InpMaxConcurrentPositions` | 3 | Cap on simultaneously open positions from this EA |
| `InpMaxSpreadPips` | 3.0 | Skip placing new stops this bar if spread exceeds this; `0` disables the filter |
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
| `InpHideTradeLevels` | true | Hide the SL/TP/entry lines MT5 draws on the chart (see Chart Display note below) |
| `InpUseVirtualExits` | true | Manage TP/SL/breakeven in the EA instead of on the broker order (see Virtual Exit Management below) |
| `InpBackstopSLMultiplier` | 4.0 | Real broker-side SL = `InpStopLossPips` × this, kept only as a crash/disconnect backstop (virtual exits mode) |
| `InpUseTrailingStop` | true | Trail the SL for any position in profit at candle close, taking over from the fixed TP (see Trailing Stop below) |
| `InpTrailingDistancePips` | 20 | Distance kept between price and the trailing SL |
| `InpUseDailyFlatten` | true | Close all positions and cancel all pending orders once per day (see Daily Flatten below) |
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

## Chart display

`InpHideTradeLevels` toggles the terminal's `CHART_SHOW_TRADE_LEVELS`
property, which is the only control MT5 exposes for these lines — it hides
entry, SL, and TP lines together for **every** order/position on that chart,
not just this EA's, and it's chart-wide rather than per-EA. The EA records
whatever the setting was when it started and restores it on removal, so it
won't permanently change your terminal's chart behavior.

## Reverse Signal Mode

`InpReverseSignal` fades the breakout instead of following it. A stop order
can't sit on the wrong side of the current price, so this isn't a simple
Buy↔Sell swap at the same levels — it switches order types entirely:

- Normal mode: **Buy Stop** at the prior high (buy if price breaks above),
  **Sell Stop** at the prior low (sell if price breaks below).
- Reverse mode: **Sell Limit** at the prior high (sell if price rallies back
  up to it, betting on rejection), **Buy Limit** at the prior low (buy if
  price dips back down to it, betting on a bounce).

Everything downstream — TP/SL/breakeven (virtual or broker-side), the
drawdown-close rule, OCO enforcement, the dashboard — already operates on the
resulting position's BUY/SELL type rather than how it was opened, so none of
that needed to change; only order placement did.

**Reversing a losing configuration is not a guaranteed fix.** Spread and
slippage cost the same in both directions, and a breakout system that loses
money isn't mathematically guaranteed to become a winning fade system when
inverted — it depends on why it was losing. Backtest the reversed mode with
the same rigor (realistic spread, a meaningful sample size, more than a few
days) before trusting it any more than the original.

## Virtual Exit Management

With `InpUseVirtualExits` enabled (default), the broker order carries **no
real TP and only a wide backstop SL** (`InpStopLossPips × InpBackstopSLMultiplier`).
The actual TP, SL, and breakeven logic all live in the EA (`ManageVirtualExits()`,
called every tick) and close the position at market via `trade.PositionClose()`
when a level is crossed — so under normal operation, the chart shows no TP
line at all and, if `InpHideTradeLevels` is also on, no SL/entry line either.

**This is a deliberate trade-off, not free correctness:**
- A real broker-side SL/TP is enforced by the broker's server even if your
  terminal, EA, or VPS goes offline. A virtual one only works while the EA is
  running and receiving ticks.
- The wide backstop SL exists specifically to bound the damage if that
  happens — under normal operation the tight virtual SL should always trigger
  first, so the backstop should rarely if ever be hit. But if the terminal is
  disconnected, crashed, or AutoTrading is off when price moves against an
  open position, the position is protected only down to the backstop
  distance, not the intended `InpStopLossPips`.
- There is intentionally no backstop TP — a missed virtual TP just leaves a
  winning trade open longer, which isn't an account-risk failure mode the
  same way an unprotected loss is.
- Per-position exit state (current protective SL, whether trailing has taken
  over) is tracked in memory (`g_positionStates`) since it depends on price
  history, not just the current tick. That state is lost if the EA restarts
  before a position closes; a position already above the breakeven/trailing
  trigger re-arms immediately on the next tick, but one that had improved its
  stop and then pulled back before an EA restart would revert to a wider
  fallback level rather than keeping the improvement.

Set `InpUseVirtualExits = false` to go back to real broker-side SL/TP and
breakeven (the original behavior), if you'd rather have guaranteed
broker-side protection than hidden lines.

## Trailing Stop

With `InpUseTrailingStop` enabled (default), any position that is profitable
at a candle close gets its protective stop trailed to
`InpTrailingDistancePips` behind the candle-close price (Bid for a buy, Ask
for a sell) — and, from that point on, the **fixed TP no longer applies** to
that position; it keeps running until the trailing stop is hit instead of
capping out at `InpTakeProfitPips`.

- **Evaluated once per candle close, not on every tick.** A position that
  turns profitable intrabar doesn't get trailed until that candle finishes —
  this avoids reacting to intrabar noise the moment a trade first ticks into
  profit.
- **Ratchets only — never loosens.** The trailing stop only moves if the new
  candidate is more favorable than whatever's currently set (the original SL,
  a breakeven lock, or a previous trailing level). Early on, if
  `InpTrailingDistancePips` is wider than the current profit, the candidate
  can still be behind entry (not yet at breakeven) — trailing will simply
  make no change until price has moved far enough for its candidate to beat
  the existing stop.
- **Interacts with breakeven and drawdown-close, doesn't replace them.**
  Breakeven can still lock in a small profit before trailing's own distance
  would improve on it. The existing "close on any floating loss at candle
  close" rule still applies independently — a trailing position that dips
  back into a loss before the next candle close gets closed by that rule,
  not by waiting for the trailing stop to be hit.
- Works in both `InpUseVirtualExits` modes: it updates the in-memory state
  (and, when not using virtual exits, the real broker SL via
  `trade.PositionModify`, clearing the real TP to 0 once trailing is active).

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
   active timeframe, TP/SL, virtual-exits setting, backstop SL distance,
   trade-levels, volume filter, reverse-signal, trailing stop, and daily
   flatten settings, so you can confirm what's actually running.

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
- **High-frequency stop placement**: a breakout system re-arming every minute
  is very sensitive to spread and slippage costs; backtest with realistic
  spread/commission modeling before running live.
- **Strategy Tester spread**: in "Every tick" (generated) mode without real
  tick data, MT5 synthesizes bid/ask using the symbol's default spread
  setting, which can be unrealistically wide (tens of pips) and cause
  `InpMaxSpreadPips` to block every bar. Use "Every tick based on real ticks"
  when available, or temporarily set `InpMaxSpreadPips = 0` to disable the
  filter while debugging the rest of the logic.
