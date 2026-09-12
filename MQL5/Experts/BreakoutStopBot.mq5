#property copyright "BreakoutStopBot"
#property version   "3.00"
#property strict
#property description "Sideways-range breakout bot: locks a consolidation range, waits for a "
#property description "full-body breakout, enters on retracement into a fair value gap (or a "
#property description "breaker block if no gap formed), stops at the far side of the range, "
#property description "takes a partial at 1:1, and trails the remainder past 2:1."

#include <Trade/Trade.mqh>
#include "../Include/BreakoutStopBot/TradeUtils.mqh"
#include "../Include/BreakoutStopBot/RiskManager.mqh"
#include "../Include/BreakoutStopBot/Dashboard.mqh"

// Capped at M1/M3/M5 - this is a short-timeframe system and isn't intended
// (or validated) for slower candles.
enum ENUM_BOT_TIMEFRAME
  {
   BOT_PERIOD_M1=PERIOD_M1,
   BOT_PERIOD_M3=PERIOD_M3,
   BOT_PERIOD_M5=PERIOD_M5
  };

// One full range->breakout->retracement->trade cycle runs at a time; the bot only
// ever occupies one of these states.
enum ENUM_BOT_STATE
  {
   STATE_SCANNING,       // hunting for a sideways range
   STATE_RANGE_LOCKED,   // range frozen, waiting for a full-body breakout
   STATE_PENDING_ENTRY,  // breakout confirmed, retracement limit order resting
   STATE_IN_TRADE        // position filled, under 1R/2R management
  };

enum ENUM_BREAKOUT_DIR
  {
   BREAKOUT_NONE,
   BREAKOUT_BULLISH,
   BREAKOUT_BEARISH
  };

input group "=== Timeframe ==="
input ENUM_BOT_TIMEFRAME InpTimeframe        = BOT_PERIOD_M1;  // Candle timeframe (M1/M3/M5 only)

input group "=== Range Detection ==="
input int    InpRangeLookbackBars    = 20;    // Bars used to measure the sideways range
input int    InpATRPeriod            = 14;    // ATR period used to judge range compression
input double InpRangeMaxATRMult      = 1.5;   // Range height must be <= this x ATR to qualify as sideways
input int    InpRangeMinConfirmBars  = 3;     // Consecutive sideways-qualifying candles required before locking
input int    InpRangeMaxAgeBars      = 0;     // Give up and re-scan if no breakout within this many bars; 0 = never expires

input group "=== Breakout Confirmation ==="
input double InpMinBreakoutBodyPips  = 0.0;   // Minimum candle body size to count as a breakout; 0 = disabled

input group "=== Retracement Zone ==="
input double InpEntryZonePct         = 50.0;  // Where in the FVG/breaker zone to enter: 0=near edge, 50=mid, 100=far edge
input int    InpRetracementTimeoutBars = 10;  // Cancel the pending retracement order if not filled within this many bars

input group "=== Stop Loss ==="
input double InpSlBufferPips         = 2.0;   // Extra buffer beyond the opposite side of the range

input group "=== Breakeven ==="
input double InpBreakevenBufferPips  = 0.25;  // Extra pips locked in beyond spread at breakeven
input double InpLatencyBufferPips    = 1.0;   // Extra pips added to the breakeven lock to survive round-trip order latency

input group "=== Trade Management ==="
input double InpPartialClosePercent  = 50.0;  // % of position closed once profit reaches 1R
input double InpTrailStepPips        = 15.0;  // Trailing distance kept behind price once profit passes 2R

input group "=== Position Sizing ==="
input bool   InpUseRiskPercent       = false; // Use risk-percent sizing instead of fixed lot
input double InpRiskPercent          = 1.0;   // Risk per trade, % of balance (if InpUseRiskPercent)
input double InpLotSize              = 0.01;  // Fixed lot size (if !InpUseRiskPercent)

input group "=== Risk Controls ==="
input int    InpMaxConcurrentPositions = 1;   // Max simultaneously open positions from this EA
input double InpMaxSpreadPips        = 3.0;   // Skip placing the retracement order if spread exceeds this; 0 = disabled

input group "=== Session Filter ==="
input bool   InpUseSessionFilter     = false; // Restrict new retracement orders to a time window
input int    InpTradingStartHour     = 0;     // Server-time hour, inclusive
input int    InpTradingEndHour       = 24;    // Server-time hour, exclusive

input group "=== Volume Filter ==="
input bool   InpUseVolumeFilter      = true;  // Only accept a breakout candle if its volume is above the recent average
input int    InpVolumeLookbackBars   = 20;    // Number of prior candles averaged for comparison
input double InpMinVolumeRatio       = 1.0;   // Required ratio: breakout candle volume >= this x average volume

input group "=== Execution ==="
input int    InpSlippagePips         = 2;     // Max slippage for market operations (pips)
input ulong  InpMagicNumber          = 20260904;
input bool   InpCancelPendingOnRemove = true; // Cancel our pending retracement order when the EA is removed

input group "=== Dashboard ==="
input bool   InpShowDashboard        = true;  // Show on-chart P/L dashboard
input int    InpDashboardRefreshSeconds= 5;   // How often the dashboard recalculates

input group "=== Daily Flatten ==="
input bool   InpUseDailyFlatten      = true;  // Close all positions and cancel pending orders once per day
input int    InpDailyFlattenHour     = 0;     // Server-time hour to flatten (0 = midnight)

CTrade           trade;
ENUM_TIMEFRAMES  g_timeframe        = PERIOD_M1;
datetime         g_lastBarTime      = 0;
int              g_lastFlattenDay   = -1;
int              g_atrHandle        = INVALID_HANDLE;
ENUM_BOT_STATE   g_state            = STATE_SCANNING;

// --- Range/cycle state (valid once g_state != STATE_SCANNING) ---
double   g_boxHigh          = 0.0;
double   g_boxLow           = 0.0;
datetime g_boxStartTime     = 0;
int      g_sidewaysConfirmCount = 0;
int      g_barsSinceLock    = 0;

// --- Pending-entry state (valid once g_state == STATE_PENDING_ENTRY) ---
ulong    g_pendingEntryTicket = 0;
int      g_plannedDirection   = 0;   // 1=buy, -1=sell
double   g_plannedInitialSl   = 0.0;
int      g_barsWaitingForFill = 0;
string   g_cycleComment       = "";

// Per-position management state once a retracement order fills. Mirrors the
// ticket-keyed struct-array pattern used elsewhere in this file (see the
// removed DrawdownStreak tracker in git history) - here tracking each
// position's frozen R distance and how far its exit has progressed.
struct PositionMgmt
  {
   ulong  ticket;
   double entryPrice;
   double initialSl;       // frozen R reference, fixed at fill, never changes
   int    direction;       // 1=buy, -1=sell
   double rPips;           // |entryPrice-initialSl| in pips, computed once
   bool   partialDone;
   double currentSl;       // current committed protective SL, ratchets only
   bool   trailingActive;
  };
PositionMgmt g_positionMgmt[];

int FindPositionMgmt(ulong ticket)
  {
   for(int i=0;i<ArraySize(g_positionMgmt);i++)
      if(g_positionMgmt[i].ticket==ticket)
         return i;
   return -1;
  }

void InitPositionMgmt(ulong ticket,int direction)
  {
   if(!PositionSelectByTicket(ticket)) return;
   double entry=PositionGetDouble(POSITION_PRICE_OPEN);
   int idx=ArraySize(g_positionMgmt);
   ArrayResize(g_positionMgmt,idx+1);
   g_positionMgmt[idx].ticket=ticket;
   g_positionMgmt[idx].entryPrice=entry;
   g_positionMgmt[idx].initialSl=g_plannedInitialSl;
   g_positionMgmt[idx].direction=direction;
   g_positionMgmt[idx].rPips=PriceToPips(_Symbol,MathAbs(entry-g_plannedInitialSl));
   g_positionMgmt[idx].partialDone=false;
   g_positionMgmt[idx].currentSl=g_plannedInitialSl;
   g_positionMgmt[idx].trailingActive=false;
  }

void PrunePositionMgmt(const string symbol,ulong magic)
  {
   ulong openTickets[];
   int openCount=GetPositionTickets(symbol,magic,openTickets);
   for(int i=ArraySize(g_positionMgmt)-1;i>=0;i--)
     {
      bool stillOpen=false;
      for(int j=0;j<openCount;j++)
         if(openTickets[j]==g_positionMgmt[i].ticket) { stillOpen=true; break; }
      if(!stillOpen)
         ArrayRemove(g_positionMgmt,i,1);
     }
  }

// Clears all cycle/pending-entry/position-management state and returns to scanning.
// Does not touch open positions or orders - callers that need those cancelled/closed
// do so before calling this.
void ResetCycle()
  {
   g_boxHigh=0.0; g_boxLow=0.0; g_boxStartTime=0;
   g_sidewaysConfirmCount=0; g_barsSinceLock=0;
   g_pendingEntryTicket=0; g_plannedDirection=0; g_plannedInitialSl=0.0;
   g_barsWaitingForFill=0; g_cycleComment="";
   ArrayResize(g_positionMgmt,0);
   g_state=STATE_SCANNING;
  }

void CancelPendingEntry()
  {
   if(g_pendingEntryTicket!=0 && OrderSelect(g_pendingEntryTicket))
      trade.OrderDelete(g_pendingEntryTicket);
   g_pendingEntryTicket=0;
  }

int OnInit()
  {
   g_timeframe=(ENUM_TIMEFRAMES)InpTimeframe;

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);

   double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   double pip=PipSize(_Symbol);
   int deviationPoints=(point>0.0)?(int)MathRound(InpSlippagePips*(pip/point)):(int)InpSlippagePips;
   trade.SetDeviationInPoints(deviationPoints);

   ENUM_ACCOUNT_MARGIN_MODE marginMode=(ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(marginMode!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      Print("WARNING: account is not a hedging account. This EA assumes independent per-order "
            "positions and has not been validated on netting accounts.");

   if(_Period!=g_timeframe)
      Print("WARNING: chart timeframe is not ",TimeframeLabel(g_timeframe),". This EA reads ",
            TimeframeLabel(g_timeframe)," candle data internally regardless of chart period, but "
            "run it on a matching chart for accurate new-bar timing.");

   g_atrHandle=iATR(_Symbol,g_timeframe,InpATRPeriod);
   if(g_atrHandle==INVALID_HANDLE)
     {
      Print("Failed to create ATR indicator handle, error=",GetLastError());
      return(INIT_FAILED);
     }

   g_lastBarTime=iTime(_Symbol,g_timeframe,0);
   g_state=STATE_SCANNING;

   Print("BreakoutStopBot init: timeframe=",TimeframeLabel(g_timeframe),
         " rangeLookback=",InpRangeLookbackBars,"bars atrPeriod=",InpATRPeriod,
         " rangeMaxATRMult=",DoubleToString(InpRangeMaxATRMult,2),
         " confirmBars=",InpRangeMinConfirmBars,
         " entryZonePct=",DoubleToString(InpEntryZonePct,1),
         " slBuffer=",DoubleToString(InpSlBufferPips,1),"pips",
         " partialClose=",DoubleToString(InpPartialClosePercent,1),"% at 1R",
         " trailStep=",DoubleToString(InpTrailStepPips,1),"pips past 2R",
         " volumeFilter=",InpUseVolumeFilter,"(",InpVolumeLookbackBars,"bars,>=",DoubleToString(InpMinVolumeRatio,2),"x)",
         " sessionFilter=",InpUseSessionFilter,
         " dailyFlatten=",InpUseDailyFlatten,"(hour ",InpDailyFlattenHour,")");

   if(InpShowDashboard)
     {
      CreateDashboardBackground();
      UpdateDashboard(_Symbol,InpMagicNumber,g_timeframe);
      EventSetTimer(MathMax(1,InpDashboardRefreshSeconds));
     }

   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   RemoveDashboard();

   if(g_atrHandle!=INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);

   if(InpCancelPendingOnRemove && reason==REASON_REMOVE)
      CancelPendingEntry();
  }

void OnTimer()
  {
   if(InpShowDashboard)
      UpdateDashboard(_Symbol,InpMagicNumber,g_timeframe);
  }

void OnTick()
  {
   CheckDailyFlatten();

   if(g_state==STATE_PENDING_ENTRY)
      CheckPendingEntryFill();

   if(g_state==STATE_IN_TRADE)
     {
      ManageTradeLifecycle();
      CheckCycleCompletion();
     }

   if(IsNewBar(_Symbol,g_timeframe,g_lastBarTime))
      OnNewBar();
  }

void OnNewBar()
  {
   if(InpShowDashboard)
      UpdateDashboard(_Symbol,InpMagicNumber,g_timeframe);

   switch(g_state)
     {
      case STATE_SCANNING:
         EvaluateRangeDetection();
         break;
      case STATE_RANGE_LOCKED:
         ProcessRangeLocked();
         break;
      case STATE_PENDING_ENTRY:
         ProcessPendingEntry();
         break;
      case STATE_IN_TRADE:
         ManageTrailingStep();
         break;
     }
  }

//=== Range detection (SCANNING -> RANGE_LOCKED) =============================

// Sideways = the last InpRangeLookbackBars closed candles' high-low span is no
// more than InpRangeMaxATRMult x ATR, held for InpRangeMinConfirmBars consecutive
// closed candles in a row (any failing candle resets the streak). Only runs while
// scanning, and locking the box leaves STATE_SCANNING entirely, so an accepted
// range is never re-measured or shifted mid-cycle.
void EvaluateRangeDetection()
  {
   double atrBuf[];
   if(CopyBuffer(g_atrHandle,0,1,1,atrBuf)<=0)
      return;
   double atrPips=PriceToPips(_Symbol,atrBuf[0]);
   if(atrPips<=0.0)
      return;

   double boxHigh=iHigh(_Symbol,g_timeframe,1);
   double boxLow =iLow(_Symbol,g_timeframe,1);
   for(int s=2;s<=InpRangeLookbackBars;s++)
     {
      boxHigh=MathMax(boxHigh,iHigh(_Symbol,g_timeframe,s));
      boxLow =MathMin(boxLow, iLow(_Symbol,g_timeframe,s));
     }
   double rangePips=PriceToPips(_Symbol,boxHigh-boxLow);
   bool sideways=(rangePips<=InpRangeMaxATRMult*atrPips);

   if(!sideways)
     {
      g_sidewaysConfirmCount=0;
      return;
     }

   g_sidewaysConfirmCount++;
   if(g_sidewaysConfirmCount<InpRangeMinConfirmBars)
      return;

   g_boxHigh=boxHigh;
   g_boxLow=boxLow;
   g_boxStartTime=iTime(_Symbol,g_timeframe,InpRangeLookbackBars);
   g_barsSinceLock=0;
   g_sidewaysConfirmCount=0;
   g_state=STATE_RANGE_LOCKED;

   Print("Range locked: high=",DoubleToString(boxHigh,_Digits)," low=",DoubleToString(boxLow,_Digits),
         " (",DoubleToString(rangePips,1)," pips <= ",DoubleToString(InpRangeMaxATRMult*atrPips,1)," ATR-pips)");
  }

//=== Breakout confirmation + retracement setup (RANGE_LOCKED) ===============

ENUM_BREAKOUT_DIR DetectBreakout(double boxHigh,double boxLow,double minBodyPips)
  {
   double o=iOpen(_Symbol,g_timeframe,1);
   double c=iClose(_Symbol,g_timeframe,1);
   double bodyLow=MathMin(o,c);
   double bodyHigh=MathMax(o,c);

   if(minBodyPips>0.0 && PriceToPips(_Symbol,MathAbs(c-o))<minBodyPips)
      return BREAKOUT_NONE;

   if(bodyLow>=boxHigh) return BREAKOUT_BULLISH;
   if(bodyHigh<=boxLow) return BREAKOUT_BEARISH;
   return BREAKOUT_NONE;
  }

struct SZone
  {
   double zoneHigh;
   double zoneLow;
   int    direction;   // 1=bullish, -1=bearish
  };

// Bullish FVG: candle[s].low > candle[s+2].high (gap = [candle[s+2].high, candle[s].low]).
// Bearish FVG: candle[s].high < candle[s+2].low (gap = [candle[s].high, candle[s+2].low]).
// Scans s from the breakout candle backward to the range start so the match nearest
// the breakout wins; the breakout candle itself may be the newest leg of the triple.
bool FindFVGZone(int breakoutShift,int boxStartShift,int direction,SZone &zone)
  {
   for(int s=breakoutShift;s<=boxStartShift-2;s++)
     {
      double highOldest=iHigh(_Symbol,g_timeframe,s+2);
      double lowOldest =iLow(_Symbol,g_timeframe,s+2);
      double highNewest=iHigh(_Symbol,g_timeframe,s);
      double lowNewest =iLow(_Symbol,g_timeframe,s);

      if(direction==1 && lowNewest>highOldest)
        {
         zone.zoneLow=highOldest; zone.zoneHigh=lowNewest; zone.direction=1;
         return true;
        }
      if(direction==-1 && highNewest<lowOldest)
        {
         zone.zoneHigh=lowOldest; zone.zoneLow=highNewest; zone.direction=-1;
         return true;
        }
     }
   return false;
  }

// Breaker block fallback: the nearest candle (scanning backward from just before
// the breakout candle) whose close is opposite the breakout direction. Its full
// high-low range is the zone.
bool FindBreakerZone(int breakoutShift,int boxStartShift,int direction,SZone &zone)
  {
   for(int s=breakoutShift+1;s<=boxStartShift;s++)
     {
      double o=iOpen(_Symbol,g_timeframe,s);
      double c=iClose(_Symbol,g_timeframe,s);
      if(direction==1 && c<o)
        {
         zone.zoneHigh=iHigh(_Symbol,g_timeframe,s);
         zone.zoneLow =iLow(_Symbol,g_timeframe,s);
         zone.direction=1;
         return true;
        }
      if(direction==-1 && c>o)
        {
         zone.zoneHigh=iHigh(_Symbol,g_timeframe,s);
         zone.zoneLow =iLow(_Symbol,g_timeframe,s);
         zone.direction=-1;
         return true;
        }
     }
   return false;
  }

bool BuildRetracementZone(int breakoutShift,int boxStartShift,int direction,SZone &zone)
  {
   if(FindFVGZone(breakoutShift,boxStartShift,direction,zone))
      return true;
   return FindBreakerZone(breakoutShift,boxStartShift,direction,zone);
  }

// entryZonePct is direction-aware: a bullish retrace reaches the zone's high edge
// first (0% = zoneHigh, near/shallow) then works down toward zoneLow (100%, far/deep);
// mirrored for bearish.
double ComputeEntryPrice(const SZone &zone,double entryZonePct)
  {
   double pct=MathMax(0.0,MathMin(100.0,entryZonePct))/100.0;
   double height=zone.zoneHigh-zone.zoneLow;
   if(zone.direction==1)
      return zone.zoneHigh-pct*height;
   return zone.zoneLow+pct*height;
  }

bool PlaceRetracementOrder(const SZone &zone,int direction)
  {
   if(CountPositionsByMagic(_Symbol,InpMagicNumber)>=InpMaxConcurrentPositions)
     {
      Print("Max concurrent positions reached, skipping retracement order.");
      return false;
     }

   double entryRaw=ComputeEntryPrice(zone,InpEntryZonePct);
   double slRaw=(direction==1)
                ? g_boxLow -PipsToPrice(_Symbol,InpSlBufferPips)
                : g_boxHigh+PipsToPrice(_Symbol,InpSlBufferPips);

   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   ENUM_ORDER_TYPE orderType=(direction==1)?ORDER_TYPE_BUY_LIMIT:ORDER_TYPE_SELL_LIMIT;

   // Price already retraced through (or past) the planned entry before we could
   // place the order - don't chase it into the middle of the move.
   if(direction==1  && entryRaw>=ask) { Print("Zone already breached (bullish), skipping."); return false; }
   if(direction==-1 && entryRaw<=bid) { Print("Zone already breached (bearish), skipping."); return false; }

   int digits=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   double entryPrice=AdjustLimitPrice(_Symbol,orderType,entryRaw);
   double slPrice=NormalizeDouble(slRaw,digits);
   double slPips=PriceToPips(_Symbol,MathAbs(entryPrice-slPrice));
   if(slPips<=0.0)
     {
      Print("Computed zero/negative SL distance, skipping retracement order.");
      return false;
     }

   double lot=InpUseRiskPercent
              ? CalcLotByRisk(_Symbol,InpRiskPercent,slPips)
              : NormalizeVolume(_Symbol,InpLotSize);

   g_cycleComment=StringFormat("BOSR_%d",(int)g_boxStartTime);

   if(trade.OrderOpen(_Symbol,orderType,lot,0.0,entryPrice,slPrice,0.0,ORDER_TIME_GTC,0,g_cycleComment))
     {
      g_pendingEntryTicket=trade.ResultOrder();
      g_plannedInitialSl=slPrice;
      g_plannedDirection=direction;
      Print("Retracement order placed: ",EnumToString(orderType),
            " price=",DoubleToString(entryPrice,digits)," sl=",DoubleToString(slPrice,digits),
            " lot=",DoubleToString(lot,2));
      return true;
     }

   Print("Retracement order failed: ",trade.ResultRetcodeDescription()," price=",DoubleToString(entryPrice,digits));
   return false;
  }

void ProcessRangeLocked()
  {
   g_barsSinceLock++;
   if(InpRangeMaxAgeBars>0 && g_barsSinceLock>InpRangeMaxAgeBars)
     {
      Print("Range expired without breakout, resuming scan.");
      ResetCycle();
      return;
     }

   ENUM_BREAKOUT_DIR dir=DetectBreakout(g_boxHigh,g_boxLow,InpMinBreakoutBodyPips);
   if(dir==BREAKOUT_NONE)
      return; // keep watching, box stays valid

   if(InpUseVolumeFilter && !VolumeOk())
     {
      Print("Breakout candle volume below the ",InpVolumeLookbackBars,"-bar average, waiting for a better breakout.");
      return; // keep watching, box stays valid
     }

   int direction=(dir==BREAKOUT_BULLISH)?1:-1;
   int boxStartShift=iBarShift(_Symbol,g_timeframe,g_boxStartTime,false);

   SZone zone;
   if(!BuildRetracementZone(1,boxStartShift,direction,zone))
     {
      Print("No FVG or breaker zone found for this breakout, discarding range.");
      ResetCycle();
      return;
     }

   if(InpUseSessionFilter && !WithinSession())
     {
      Print("Breakout outside session window, discarding range.");
      ResetCycle();
      return;
     }

   if(!SpreadOk())
     {
      Print("Spread ",DoubleToString(CurrentSpreadPips(_Symbol),1)," pips exceeds max ",
            DoubleToString(InpMaxSpreadPips,1)," at breakout, discarding range.");
      ResetCycle();
      return;
     }

   if(!PlaceRetracementOrder(zone,direction))
     {
      ResetCycle();
      return;
     }

   g_barsWaitingForFill=0;
   g_state=STATE_PENDING_ENTRY;
  }

//=== Pending retracement order (PENDING_ENTRY) ==============================

void ProcessPendingEntry()
  {
   g_barsWaitingForFill++;
   if(InpRetracementTimeoutBars>0 && g_barsWaitingForFill>=InpRetracementTimeoutBars)
     {
      Print("Retracement order timed out without a fill, cancelling.");
      CancelPendingEntry();
      ResetCycle();
      return;
     }

   double close1=iClose(_Symbol,g_timeframe,1);
   bool invalidated=(g_plannedDirection==1) ? (close1<g_boxLow) : (close1>g_boxHigh);
   if(invalidated)
     {
      Print("Breakout thesis invalidated (closed back through the opposite side), cancelling.");
      CancelPendingEntry();
      ResetCycle();
     }
  }

// Runs every tick while PENDING_ENTRY. MT5 doesn't guarantee the filled position's
// ticket equals the pending order's ticket, so the fill is identified by matching
// this cycle's comment tag on a position that isn't already tracked.
void CheckPendingEntryFill()
  {
   if(g_pendingEntryTicket==0)
      return;
   if(OrderSelect(g_pendingEntryTicket))
      return; // still resting

   ulong tickets[];
   int n=GetPositionTickets(_Symbol,InpMagicNumber,tickets);
   ulong filled=0;
   for(int i=0;i<n;i++)
     {
      if(FindPositionMgmt(tickets[i])>=0) continue;
      if(!PositionSelectByTicket(tickets[i])) continue;
      if(PositionGetString(POSITION_COMMENT)==g_cycleComment)
        {
         filled=tickets[i];
         break;
        }
     }

   int direction=g_plannedDirection;
   g_pendingEntryTicket=0;

   if(filled!=0)
     {
      InitPositionMgmt(filled,direction);
      g_state=STATE_IN_TRADE;
      Print("Retracement order filled: #",filled);
     }
   else
     {
      Print("Pending retracement order disappeared without a matching fill, resuming scan.");
      ResetCycle();
     }
  }

//=== Trade management (IN_TRADE) ============================================

// Every tick: 1R triggers a partial close plus SL->breakeven and TP->2R (precise
// R-multiple levels can be touched and retreated from intrabar, so this can't wait
// for a candle close). 2R hands off the fixed TP to the candle-close-driven trail.
void ManageTradeLifecycle()
  {
   PrunePositionMgmt(_Symbol,InpMagicNumber);
   if(ArraySize(g_positionMgmt)==0)
      return;

   ulong ticket=g_positionMgmt[0].ticket;
   if(!PositionSelectByTicket(ticket))
      return;

   long type=PositionGetInteger(POSITION_TYPE);
   double entry=g_positionMgmt[0].entryPrice;
   double rPips=g_positionMgmt[0].rPips;
   if(rPips<=0.0)
      return;

   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   int digits=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   double profitPips=(type==POSITION_TYPE_BUY)
                      ? PriceToPips(_Symbol,bid-entry)
                      : PriceToPips(_Symbol,entry-ask);

   if(!g_positionMgmt[0].partialDone && profitPips>=rPips)
     {
      double volume=PositionGetDouble(POSITION_VOLUME);
      double partialVol=NormalizeVolume(_Symbol,volume*InpPartialClosePercent/100.0);
      double minVol=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);

      if(partialVol>0.0 && partialVol<volume && (volume-partialVol)>=minVol)
        {
         if(trade.PositionClosePartial(ticket,partialVol))
            Print("1R reached on #",ticket,": partial close ",DoubleToString(partialVol,2));
         else
            Print("1R: partial close failed on #",ticket," error=",GetLastError());
        }
      else
         Print("1R reached on #",ticket,": skipping partial close (remainder would be below broker minimum)");

      double bePips=CurrentSpreadPips(_Symbol)+InpBreakevenBufferPips+InpLatencyBufferPips;
      double beSl=(type==POSITION_TYPE_BUY)
                  ? NormalizeDouble(entry+PipsToPrice(_Symbol,bePips),digits)
                  : NormalizeDouble(entry-PipsToPrice(_Symbol,bePips),digits);
      double tp2R=(type==POSITION_TYPE_BUY)
                  ? NormalizeDouble(entry+PipsToPrice(_Symbol,2.0*rPips),digits)
                  : NormalizeDouble(entry-PipsToPrice(_Symbol,2.0*rPips),digits);

      if(trade.PositionModify(ticket,beSl,tp2R))
        {
         g_positionMgmt[0].currentSl=beSl;
         g_positionMgmt[0].partialDone=true;
         Print("1R: SL->breakeven=",DoubleToString(beSl,digits)," TP->2R=",DoubleToString(tp2R,digits)," on #",ticket);
        }
      else
         Print("1R: breakeven/TP2R modify failed on #",ticket," error=",GetLastError()," (retry next tick)");

      return;
     }

   if(g_positionMgmt[0].partialDone && !g_positionMgmt[0].trailingActive && profitPips>=2.0*rPips)
     {
      if(trade.PositionModify(ticket,g_positionMgmt[0].currentSl,0.0))
        {
         g_positionMgmt[0].trailingActive=true;
         Print("2R reached on #",ticket,": fixed TP cleared, trailing engaged.");
        }
      else
         Print("2R: trailing handoff failed on #",ticket," error=",GetLastError()," (retry next tick)");
     }
  }

// Once per new candle close, while trailing is active: ratchet the SL to
// InpTrailStepPips behind price, only ever tightening. Matches the candle-close
// cadence of this project's earlier trailing-stop implementation rather than
// re-evaluating (and risking noise-driven whipsaw tightening) on every tick.
void ManageTrailingStep()
  {
   if(ArraySize(g_positionMgmt)==0 || !g_positionMgmt[0].trailingActive)
      return;

   ulong ticket=g_positionMgmt[0].ticket;
   if(!PositionSelectByTicket(ticket))
      return;

   long type=PositionGetInteger(POSITION_TYPE);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   int digits=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);

   double candidate=(type==POSITION_TYPE_BUY)
                     ? NormalizeDouble(bid-PipsToPrice(_Symbol,InpTrailStepPips),digits)
                     : NormalizeDouble(ask+PipsToPrice(_Symbol,InpTrailStepPips),digits);
   bool improved=(type==POSITION_TYPE_BUY)
                 ? (candidate>g_positionMgmt[0].currentSl)
                 : (candidate<g_positionMgmt[0].currentSl);

   if(improved)
     {
      if(trade.PositionModify(ticket,candidate,0.0))
         g_positionMgmt[0].currentSl=candidate;
      else
         Print("Trailing step failed on #",ticket," error=",GetLastError());
     }
  }

void CheckCycleCompletion()
  {
   if(ArraySize(g_positionMgmt)==0)
      return;
   if(!PositionSelectByTicket(g_positionMgmt[0].ticket))
     {
      Print("Cycle complete, resuming scan.");
      ResetCycle();
     }
  }

//=== Shared filters (reused across breakout confirmation) ===================

bool SpreadOk()
  {
   if(InpMaxSpreadPips<=0.0)
      return true;
   return CurrentSpreadPips(_Symbol)<=InpMaxSpreadPips;
  }

// Compares the breakout candle's tick volume against the average of the preceding
// InpVolumeLookbackBars candles.
bool VolumeOk()
  {
   if(!InpUseVolumeFilter || InpVolumeLookbackBars<=0)
      return true;

   long currentVolume=iVolume(_Symbol,g_timeframe,1);

   long sum=0;
   int count=0;
   for(int i=2;i<2+InpVolumeLookbackBars;i++)
     {
      long v=iVolume(_Symbol,g_timeframe,i);
      if(v<=0) continue;
      sum+=v;
      count++;
     }
   if(count==0)
      return true;

   double avgVolume=(double)sum/count;
   if(avgVolume<=0.0)
      return true;

   return currentVolume>=InpMinVolumeRatio*avgVolume;
  }

bool WithinSession()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(),dt);
   int hour=dt.hour;
   if(InpTradingStartHour<=InpTradingEndHour)
      return hour>=InpTradingStartHour && hour<InpTradingEndHour;
   return hour>=InpTradingStartHour || hour<InpTradingEndHour;
  }

//=== Daily flatten ============================================================

// Closes every open position and cancels the pending retracement order (if any)
// once per calendar day at InpDailyFlattenHour (server time), then resumes
// scanning from a clean state. Checked every tick so it fires promptly after
// the hour boundary.
void CheckDailyFlatten()
  {
   if(!InpUseDailyFlatten) return;

   datetime now=TimeCurrent();
   int today=(int)(now/86400);
   MqlDateTime dt;
   TimeToStruct(now,dt);

   if(dt.hour>=InpDailyFlattenHour && g_lastFlattenDay!=today)
     {
      FlattenAll();
      g_lastFlattenDay=today;
     }
  }

void FlattenAll()
  {
   CancelPendingEntry();

   ulong tickets[];
   int n=GetPositionTickets(_Symbol,InpMagicNumber,tickets);
   for(int i=0;i<n;i++)
     {
      if(trade.PositionClose(tickets[i]))
         Print("Daily flatten: closed position #",tickets[i]);
      else
         Print("Daily flatten: failed to close #",tickets[i]," error=",GetLastError());
     }

   ResetCycle();
  }
