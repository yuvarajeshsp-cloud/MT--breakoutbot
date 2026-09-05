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
1. **OCO enforcement** — if one pending stop order of the current pair filled
   or disappeared while the other is still pending, the sibling is cancelled.
2. **Exit management** — depends on `InpUseVirtualExits` (see below):
   `ManageVirtualExits()` when enabled (default), `ManageBreakeven()` (moves
   the real broker-side SL) when disabled.

On every new candle (once, at the bar's first tick):
1. **Drawdown close** — any open position (from this EA) currently in
   floating loss is closed at market immediately, rather than waiting for the
   fixed stop loss.
2. **Stale order cleanup** — the previous bar's Buy Stop / Sell Stop are
   cancelled if they never filled.
3. **New OCO pair** — if spread and session filters pass and the EA is below
   `InpMaxConcurrentPositions`, a fresh Buy Stop is placed at
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
| `InpUseRiskPercent` | false | Use risk-percent position sizing instead of a fixed lot |
| `InpRiskPercent` | 1.0 | Risk per trade, % of account balance (if `InpUseRiskPercent`) |
| `InpLotSize` | 0.01 | Fixed lot size (if not using risk-percent sizing) |
| `InpMaxConcurrentPositions` | 3 | Cap on simultaneously open positions from this EA |
| `InpMaxSpreadPips` | 3.0 | Skip placing new stops this bar if spread exceeds this; `0` disables the filter |
| `InpUseSessionFilter` | false | Restrict new stop placement to a server-time window |
| `InpTradingStartHour` / `InpTradingEndHour` | 0 / 24 | Session window (server time, hour granularity) |
| `InpSlippagePips` | 2 | Max slippage allowed for market operations (e.g. drawdown close) |
| `InpMagicNumber` | 20260904 | Identifies this EA's orders/positions |
| `InpCancelPendingOnRemove` | true | Cancel this EA's pending stop orders when it's removed from the chart |
| `InpShowDashboard` | true | Show the on-chart P/L dashboard |
| `InpDashboardRefreshSeconds` | 5 | How often the dashboard recalculates from trade history |
| `InpHideTradeLevels` | true | Hide the SL/TP/entry lines MT5 draws on the chart (see Chart Display note below) |
| `InpUseVirtualExits` | true | Manage TP/SL/breakeven in the EA instead of on the broker order (see Virtual Exit Management below) |
| `InpBackstopSLMultiplier` | 4.0 | Real broker-side SL = `InpStopLossPips` × this, kept only as a crash/disconnect backstop (virtual exits mode) |

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
- Breakeven-armed state is tracked in memory per ticket (`g_breakevenArmedTickets`)
  since, unlike SL/TP, it depends on whether profit ever reached the trigger —
  not just current price. That state is lost if the EA restarts before a
  position closes; if the position is still above the trigger when it
  restarts it re-arms immediately, but a position that armed breakeven, then
  pulled back below the trigger, then saw the EA restart, would revert to the
  wider original virtual SL rather than staying at breakeven.

Set `InpUseVirtualExits = false` to go back to real broker-side SL/TP and
breakeven (the original behavior), if you'd rather have guaranteed
broker-side protection than hidden lines.

## Install

1. Copy `MQL5/Experts/BreakoutStopBot.mq5` and the
   `MQL5/Include/BreakoutStopBot/` folder into your terminal's `MQL5/Experts`
   and `MQL5/Include` directories (Data Folder → `MQL5/`).
2. Compile `BreakoutStopBot.mq5` in MetaEditor.
3. Attach to a chart matching `InpTimeframe` (M1/M3/M5), enable AutoTrading,
   set inputs.

## Known limitations / risks

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
