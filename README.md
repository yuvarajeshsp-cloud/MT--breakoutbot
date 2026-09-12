# BreakoutStopBot

MT5 Expert Advisor implementing a structure-aware range-breakout-retracement
system on a short timeframe (M1, M3, or M5 — see `InpTimeframe`): it waits for
the market to go sideways, locks that range, waits for a **full-body candle
breakout** of it, then places a limit order back into the **Fair Value Gap**
(or, if none formed, the **breaker block**) left behind by the move. The stop
loss sits at the far side of the locked range so ordinary stop-hunt wicks at
the breakout edge don't take it out, and the winning trade is scaled out at
1:1 and trailed past 2:1. An on-chart dashboard shows today/week/month P/L
and other live stats.

## Requirements

- **Hedging account.** This EA has not been validated on netting accounts
  (only one net position per symbol) and will log a warning on `OnInit` if
  the account isn't in `ACCOUNT_MARGIN_MODE_RETAIL_HEDGING`.
- Run on a chart matching `InpTimeframe`. The EA reads candle data for that
  timeframe internally regardless of the chart's own period, but relies on
  `iTime()` changing to detect new bars — run it on a matching chart so tick
  delivery lines up as expected.

## Logic

The EA runs one range → breakout → retracement → trade cycle at a time; it
never hunts for a new range while a trade or pending retracement order from
the current cycle is still live. This is deliberate: taking an opposite-side
setup immediately after (or during) another is exactly the kind of
both-sides whipsaw the wide, range-based stop loss below is designed to
avoid.

**1. Scanning for a sideways range** (checked once per closed candle): the
highest-high/lowest-low span of the last `InpRangeLookbackBars` closed
candles is compared against `InpRangeMaxATRMult × ATR(InpATRPeriod)`. Once
that "sideways" condition holds for `InpRangeMinConfirmBars` *consecutive*
closed candles, the range is locked (its high/low frozen) and the EA starts
watching for a breakout. A range that never breaks out within
`InpRangeMaxAgeBars` closed candles is discarded and scanning resumes
(`0` = never expires).

**2. Waiting for a full-body breakout**: a closed candle counts as a breakout
only if its entire body — not just a wick — clears the locked range: for a
bullish break, `min(open,close) ≥ rangeHigh`; for a bearish break,
`max(open,close) ≤ rangeLow`. `InpMinBreakoutBodyPips` can additionally
require a minimum body size. A breakout candle that fails `InpUseVolumeFilter`
doesn't discard the range — the EA just keeps watching later candles for a
better one, subject to `InpRangeMaxAgeBars`.

**3. Retracement entry — FVG preferred, breaker block fallback**: once a
breakout is accepted (and session/spread filters pass), the EA looks inside
the range, from the breakout candle back to the range's start, for a
3-candle Fair Value Gap in the breakout's direction (the nearest one to the
breakout wins). If none exists, it falls back to the **breaker block** — the
nearest candle before the breakout whose close was the opposite color. A
`BUY_LIMIT` / `SELL_LIMIT` order is placed inside that zone at
`InpEntryZonePct` (0 = the zone's near edge, 50 = midpoint, 100 = the far
edge). If neither a gap nor a breaker block can be found, the range is
discarded. The pending order is cancelled and scanning resumes if it isn't
filled within `InpRetracementTimeoutBars` closed candles, or if a candle
closes back through the range's *opposite* boundary first (breakout
invalidated).

**4. Stop loss — opposite side of the range**: the stop is placed at
`rangeLow − InpSlBufferPips` (bullish) or `rangeHigh + InpSlBufferPips`
(bearish) — the far side of the whole range, not just beyond the breakout
point. This is deliberately wide: the usual stop-hunt target is a tight stop
sitting just past the breakout edge, and a wick that briefly pokes back into
the range and reverses is exactly what this stop is built to survive. Only a
genuine reversal all the way back through the range invalidates the trade.
This distance (in pips) also drives position sizing when `InpUseRiskPercent`
is enabled.

**5. Trade management — partial at 1:1, breakeven, trail past 2:1**: every
tick, once floating profit reaches 1R (the entry-to-SL distance), the EA
closes `InpPartialClosePercent`% of the position, moves the stop to
breakeven (`entry ± (spread + InpBreakevenBufferPips + InpLatencyBufferPips)`),
and sets the take-profit to 2R. Once profit reaches 2R, the fixed TP is
cleared and the stop instead trails `InpTrailStepPips` behind price — checked
once per closed candle, only ever tightening — so a strong trend can run for
more than 2R instead of being capped there.

On a timer (every `InpDashboardRefreshSeconds`) and after each new candle's
maintenance pass, the on-chart dashboard recalculates from trade history and
current positions. Daily flatten (see below) can interrupt any stage of the
cycle and always resumes scanning cleanly afterward.

## Inputs

| Input | Default | Description |
|---|---|---|
| `InpTimeframe` | M1 | Candle timeframe the strategy runs on; only M1, M3, M5 are selectable |
| `InpRangeLookbackBars` | 20 | Bars used to measure the sideways range |
| `InpATRPeriod` | 14 | ATR period used to judge range compression |
| `InpRangeMaxATRMult` | 1.5 | Range height must be ≤ this × ATR to qualify as sideways |
| `InpRangeMinConfirmBars` | 3 | Consecutive sideways-qualifying candles required before the range locks |
| `InpRangeMaxAgeBars` | 0 | Give up and re-scan if no breakout within this many bars; `0` = never expires |
| `InpMinBreakoutBodyPips` | 0.0 | Minimum candle body size to count as a breakout; `0` disables the filter |
| `InpEntryZonePct` | 50.0 | Where in the FVG/breaker zone to place the retracement order: 0=near edge, 50=mid, 100=far edge |
| `InpRetracementTimeoutBars` | 10 | Cancel the pending retracement order if not filled within this many bars |
| `InpSlBufferPips` | 2.0 | Extra buffer beyond the opposite side of the range for the stop loss |
| `InpBreakevenBufferPips` | 0.25 | Extra pips locked in beyond spread when moving to breakeven at 1R |
| `InpLatencyBufferPips` | 1.0 | Extra pips added to the breakeven lock to survive round-trip order latency |
| `InpPartialClosePercent` | 50.0 | % of the position closed once profit reaches 1R |
| `InpTrailStepPips` | 15.0 | Trailing distance kept behind price once profit passes 2R |
| `InpUseRiskPercent` | false | Use risk-percent position sizing instead of a fixed lot |
| `InpRiskPercent` | 1.0 | Risk per trade, % of account balance (if `InpUseRiskPercent`) |
| `InpLotSize` | 0.01 | Fixed lot size (if not using risk-percent sizing) |
| `InpMaxConcurrentPositions` | 1 | Cap on simultaneously open positions from this EA |
| `InpMaxSpreadPips` | 3.0 | Skip placing the retracement order if spread exceeds this at breakout time; `0` disables the filter |
| `InpUseSessionFilter` | false | Restrict new retracement orders to a server-time window |
| `InpTradingStartHour` / `InpTradingEndHour` | 0 / 24 | Session window (server time, hour granularity) |
| `InpUseVolumeFilter` | true | Only accept a breakout candle if its tick volume is above the recent average |
| `InpVolumeLookbackBars` | 20 | Number of prior candles averaged for the volume comparison |
| `InpMinVolumeRatio` | 1.0 | Required ratio: breakout candle volume must be ≥ this × the lookback average |
| `InpSlippagePips` | 2 | Max slippage allowed for market operations |
| `InpMagicNumber` | 20260904 | Identifies this EA's orders/positions |
| `InpCancelPendingOnRemove` | true | Cancel this EA's pending retracement order when it's removed from the chart |
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
position and cancels the pending retracement order (if any) once per
calendar day, the first time the server-time hour reaches
`InpDailyFlattenHour` (default 0 = midnight). It's checked every tick for
prompt firing, tracked so it only fires once per day, and always resets the
EA back to scanning for a fresh range afterward — it's a one-time flatten,
not a trading pause (use `InpUseSessionFilter` /
`InpTradingStartHour` / `InpTradingEndHour` if you also want to block new
entries during a window).

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
   active range/retracement/management settings, volume filter, session
   filter, and daily flatten settings, so you can confirm what's actually
   running. Every state transition (range locked, breakout accepted, order
   placed/filled/cancelled, 1R/2R reached, trailing engaged) is also logged,
   so the Journal doubles as a trace of the state machine while you watch it
   run.

## Backtesting: "Every tick" vs "Every tick based on real ticks"

These two Strategy Tester modes can show very different results for the same
EA and inputs, and that gap is itself meaningful information, not a bug:

- **"Every tick" (generated)** synthesizes intrabar price movement from OHLC
  bars using MT5's own interpolation, not real historical bid/ask data. For a
  system whose entries and exits depend on exact price levels, this can be
  more forgiving than reality — smoother paths, no real spread-widening
  events, no genuine quote gaps.
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
execution conditions. This matters most for the 1R breakeven/TP move and the
2R trailing handoff in `ManageTradeLifecycle()`/`ManageTrailingStep()`, both
of which compute a target price from the current tick, then send a request
that only takes effect after the round trip, by which point price may have
moved. `InpLatencyBufferPips` widens the breakeven lock specifically to
survive that gap; there's no equivalent needed for the resting retracement
limit order itself, since that's triggered by the broker's own server-side
price feed once placed, not by the EA's client-side timing.

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
- **TP-vs-trailing race at 2R**: the take-profit at 2R is a real broker-side
  order level; a fast single-tick move straight through it could let the
  broker fill that TP before the EA's tick-driven check clears it and hands
  off to trailing. Checking every tick (rather than waiting for a candle
  close) minimizes this window but can't eliminate it — an inherent
  client/server race, not a bug to "fix" away entirely.
- **Weekend / news gap risk**: a resting retracement limit order through a
  low-liquidity period can fill with large slippage, or a gap can jump clean
  over the whole zone without filling it at all. Consider adding a
  news-avoidance or Friday-close-avoidance guard if you trade through those
  windows — not currently implemented.
- **Netting accounts**: not supported — this EA assumes independent per-order
  positions with their own SL/TP, which requires a hedging account.
- **Broker stop/freeze levels**: the retracement order and SL prices are
  clamped to the symbol's minimum stop distance (`SYMBOL_TRADE_STOPS_LEVEL`),
  which can shift the actual entry away from the exact FVG/breaker zone edge
  on some brokers/symbols when the market is very close to those levels.
- **Real broker-side SL/TP means the lines are visible on chart**: MT5 draws
  the SL/TP/entry lines for any order that has them set. This EA always sets
  a real SL (and a real TP once 1R is reached), so those lines will show.
- **Range detection is a compression heuristic, not true market structure**:
  the ATR-based range check flags low-volatility compression, which
  correlates with sideways/consolidating price action but isn't a guarantee
  of it — a slow grinding trend can occasionally qualify too.
- **Strategy Tester spread**: in "Every tick" (generated) mode without real
  tick data, MT5 synthesizes bid/ask using the symbol's default spread
  setting, which can be unrealistically wide (tens of pips) and cause
  `InpMaxSpreadPips` to block every setup. Use "Every tick based on real
  ticks" when available, or temporarily set `InpMaxSpreadPips = 0` to
  disable the filter while debugging the rest of the logic.
