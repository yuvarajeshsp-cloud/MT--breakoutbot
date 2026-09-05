#property copyright "BreakoutStopBot"
#property version   "1.00"
#property strict
#property description "Candle breakout bot: places an OCO pair at the prior candle's high/low "
#property description "every bar (Buy Stop/Sell Stop, or Sell Limit/Buy Limit to fade in reverse "
#property description "mode), manages TP/SL, breakeven, early drawdown exit."

#include <Trade/Trade.mqh>
#include "../Include/BreakoutStopBot/TradeUtils.mqh"
#include "../Include/BreakoutStopBot/RiskManager.mqh"
#include "../Include/BreakoutStopBot/Dashboard.mqh"

// Capped at M1/M3/M5 - this is a short-timeframe breakout system and isn't
// intended (or validated) for slower candles.
enum ENUM_BOT_TIMEFRAME
  {
   BOT_PERIOD_M1=PERIOD_M1,
   BOT_PERIOD_M3=PERIOD_M3,
   BOT_PERIOD_M5=PERIOD_M5
  };

input group "=== Timeframe ==="
input ENUM_BOT_TIMEFRAME InpTimeframe = BOT_PERIOD_M1;  // Candle timeframe (M1/M3/M5 only)

input group "=== Take Profit / Stop Loss ==="
input double InpTakeProfitPips         = 100.0;  // Take profit distance (pips)
input double InpStopLossPips           = 50.0;   // Stop loss distance (pips)

input group "=== Breakeven ==="
input double InpBreakevenTriggerPips   = 20.0;   // Floating profit (pips) needed before breakeven arms
input double InpBreakevenBufferPips    = 0.25;   // Extra pips locked in beyond spread at breakeven

input group "=== Entry ==="
input double InpEntryBufferPips        = 0.0;    // Offset beyond prior candle's high/low
input int    InpPendingExpiryMinutes   = 0;       // 0 = GTC (orders are replaced every bar regardless)
input bool   InpReverseSignal          = false;  // Fade the breakout instead of following it: Sell Limit at prior high, Buy Limit at prior low

input group "=== Position Sizing ==="
input bool   InpUseRiskPercent         = false;  // Use risk-percent sizing instead of fixed lot
input double InpRiskPercent            = 1.0;    // Risk per trade, % of balance (if InpUseRiskPercent)
input double InpLotSize                = 0.01;   // Fixed lot size (if !InpUseRiskPercent)

input group "=== Risk Controls ==="
input int    InpMaxConcurrentPositions = 3;      // Max simultaneously open positions from this EA
input double InpMaxSpreadPips          = 3.0;    // Skip placing new stops if spread exceeds this; 0 = disabled

input group "=== Session Filter ==="
input bool   InpUseSessionFilter       = false;  // Restrict new stop placement to a time window
input int    InpTradingStartHour       = 0;      // Server-time hour, inclusive
input int    InpTradingEndHour         = 24;     // Server-time hour, exclusive

input group "=== Volume Filter ==="
input bool   InpUseVolumeFilter        = true;   // Only place new stops when the candle's tick volume is above the recent average
input int    InpVolumeLookbackBars     = 20;     // Number of prior candles averaged for comparison
input double InpMinVolumeRatio         = 1.0;    // Required ratio: candle volume >= this x average volume

input group "=== Execution ==="
input int    InpSlippagePips           = 2;      // Max slippage for market operations (pips)
input ulong  InpMagicNumber            = 20260904;
input bool   InpCancelPendingOnRemove  = true;   // Cancel our pending stops when the EA is removed

input group "=== Dashboard ==="
input bool   InpShowDashboard          = true;   // Show on-chart P/L dashboard
input int    InpDashboardRefreshSeconds= 5;      // How often the dashboard recalculates

input group "=== Chart Display ==="
input bool   InpHideTradeLevels        = true;   // Hide the SL/TP/entry lines MT5 draws on the chart

input group "=== Virtual Exit Management ==="
input bool   InpUseVirtualExits        = true;   // Manage TP/SL/breakeven in the EA instead of on the broker order
input double InpBackstopSLMultiplier   = 4.0;    // Real broker-side SL = InpStopLossPips x this, as a disconnect/crash backstop only (virtual exits mode)

input group "=== Trailing Stop ==="
input bool   InpUseTrailingStop        = true;   // Trail the SL for any position in profit at candle close, taking over from the fixed TP
input double InpTrailingDistancePips   = 20.0;   // Distance kept between price and the trailing SL

input group "=== Daily Flatten ==="
input bool   InpUseDailyFlatten        = true;   // Close all positions and cancel all pending orders once per day
input int    InpDailyFlattenHour       = 0;      // Server-time hour to flatten (0 = midnight)

CTrade           trade;
ENUM_TIMEFRAMES  g_timeframe             = PERIOD_M1;
datetime         g_lastBarTime           = 0;
ulong            g_pendingUpperTicket    = 0;
ulong            g_pendingLowerTicket    = 0;
bool             g_originalShowTradeLevels = true;
int              g_lastFlattenDay        = -1;

// Per-position exit state. sl is the current committed protective stop (only ever
// ratchets to a more favorable price - by breakeven, then by trailing once active).
// trailingActive, once set, means the fixed virtual TP no longer applies to this
// position; only the trailing sl does.
struct PositionState
  {
   ulong  ticket;
   double sl;
   bool   trailingActive;
  };
PositionState g_positionStates[];

int FindPositionState(ulong ticket)
  {
   for(int i=0;i<ArraySize(g_positionStates);i++)
      if(g_positionStates[i].ticket==ticket)
         return i;
   return -1;
  }

int EnsurePositionState(ulong ticket,double initialSl)
  {
   int idx=FindPositionState(ticket);
   if(idx>=0) return idx;
   int n=ArraySize(g_positionStates);
   ArrayResize(g_positionStates,n+1);
   g_positionStates[n].ticket=ticket;
   g_positionStates[n].sl=initialSl;
   g_positionStates[n].trailingActive=false;
   return n;
  }

void PrunePositionStates(const string symbol,ulong magic)
  {
   ulong openTickets[];
   int openCount=GetPositionTickets(symbol,magic,openTickets);
   for(int i=ArraySize(g_positionStates)-1;i>=0;i--)
     {
      bool stillOpen=false;
      for(int j=0;j<openCount;j++)
         if(openTickets[j]==g_positionStates[i].ticket) { stillOpen=true; break; }
      if(!stillOpen)
         ArrayRemove(g_positionStates,i,1);
     }
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

   g_lastBarTime=iTime(_Symbol,g_timeframe,0);

   Print("BreakoutStopBot init: timeframe=",TimeframeLabel(g_timeframe),
         " TP=",DoubleToString(InpTakeProfitPips,1),"pips SL=",DoubleToString(InpStopLossPips,1),"pips",
         " virtualExits=",InpUseVirtualExits,
         " backstopSL=",DoubleToString(InpStopLossPips*InpBackstopSLMultiplier,1),"pips",
         " hideTradeLevels=",InpHideTradeLevels,
         " volumeFilter=",InpUseVolumeFilter,"(",InpVolumeLookbackBars,"bars,>=",DoubleToString(InpMinVolumeRatio,2),"x)",
         " reverseSignal=",InpReverseSignal,
         " trailingStop=",InpUseTrailingStop,"(",DoubleToString(InpTrailingDistancePips,1),"pips)",
         " dailyFlatten=",InpUseDailyFlatten,"(hour ",InpDailyFlattenHour,")");

   g_originalShowTradeLevels=(bool)ChartGetInteger(0,CHART_SHOW_TRADE_LEVELS);
   if(InpHideTradeLevels)
     {
      ChartSetInteger(0,CHART_SHOW_TRADE_LEVELS,false);
      ChartRedraw(0);
     }

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

   if(InpHideTradeLevels)
      ChartSetInteger(0,CHART_SHOW_TRADE_LEVELS,g_originalShowTradeLevels);

   if(InpCancelPendingOnRemove && reason==REASON_REMOVE)
     {
      if(g_pendingUpperTicket!=0 && OrderSelect(g_pendingUpperTicket))
         trade.OrderDelete(g_pendingUpperTicket);
      if(g_pendingLowerTicket!=0 && OrderSelect(g_pendingLowerTicket))
         trade.OrderDelete(g_pendingLowerTicket);
     }
  }

void OnTimer()
  {
   if(InpShowDashboard)
      UpdateDashboard(_Symbol,InpMagicNumber,g_timeframe);
  }

void OnTick()
  {
   CheckDailyFlatten();

   EnforceOco();

   if(InpUseVirtualExits)
      ManageVirtualExits();
   else
      ManageBreakeven();

   if(IsNewBar(_Symbol,g_timeframe,g_lastBarTime))
      OnNewBar();
  }

void OnNewBar()
  {
   CloseDrawdownPositions();
   ManageTrailing();
   CancelStalePendingOrders();

   if(InpShowDashboard)
      UpdateDashboard(_Symbol,InpMagicNumber,g_timeframe);

   if(!SpreadOk())
     {
      Print("Spread ",DoubleToString(CurrentSpreadPips(_Symbol),1)," pips exceeds max ",
            DoubleToString(InpMaxSpreadPips,1),", skipping new stop orders this bar.");
      return;
     }

   if(InpUseSessionFilter && !WithinSession())
      return;

   if(!VolumeOk())
     {
      Print("Candle volume below ",DoubleToString(InpMinVolumeRatio,2),"x the ",InpVolumeLookbackBars,
            "-bar average, skipping new stop orders this bar.");
      return;
     }

   int openCount=CountPositionsByMagic(_Symbol,InpMagicNumber);
   if(openCount>=InpMaxConcurrentPositions)
     {
      Print("Max concurrent positions reached (",openCount,"/",InpMaxConcurrentPositions,
            "), skipping new stop orders.");
      return;
     }

   PlaceBreakoutStops();
  }

// Cancels the previous bar's OCO pair if it never filled, so stale breakout levels
// don't accumulate. Positions already open are left untouched.
void CancelStalePendingOrders()
  {
   if(g_pendingUpperTicket!=0)
     {
      if(OrderSelect(g_pendingUpperTicket))
         trade.OrderDelete(g_pendingUpperTicket);
      g_pendingUpperTicket=0;
     }
   if(g_pendingLowerTicket!=0)
     {
      if(OrderSelect(g_pendingLowerTicket))
         trade.OrderDelete(g_pendingLowerTicket);
      g_pendingLowerTicket=0;
     }
  }

// If one side of the current OCO pair filled or vanished and the other is still
// pending, cancel the sibling so only one direction can be active at a time.
void EnforceOco()
  {
   if(g_pendingUpperTicket==0 && g_pendingLowerTicket==0)
      return;

   bool upperExists=g_pendingUpperTicket!=0 && OrderSelect(g_pendingUpperTicket);
   bool lowerExists=g_pendingLowerTicket!=0 && OrderSelect(g_pendingLowerTicket);

   if(g_pendingUpperTicket!=0 && !upperExists)
      g_pendingUpperTicket=0;
   if(g_pendingLowerTicket!=0 && !lowerExists)
      g_pendingLowerTicket=0;

   if(g_pendingUpperTicket==0 && g_pendingLowerTicket!=0 && lowerExists)
     {
      trade.OrderDelete(g_pendingLowerTicket);
      g_pendingLowerTicket=0;
     }
   else if(g_pendingLowerTicket==0 && g_pendingUpperTicket!=0 && upperExists)
     {
      trade.OrderDelete(g_pendingUpperTicket);
      g_pendingUpperTicket=0;
     }
  }

// Normal mode: Buy Stop at the prior high (follow an upward breakout), Sell Stop at
// the prior low (follow a downward breakout). InpReverseSignal fades instead of
// following - Sell Limit at the prior high, Buy Limit at the prior low - since a
// stop order can't sit on the wrong side of price; only a limit order can fade a level.
void PlaceBreakoutStops()
  {
   double prevHigh=iHigh(_Symbol,g_timeframe,1);
   double prevLow =iLow(_Symbol,g_timeframe,1);
   if(prevHigh<=0.0 || prevLow<=0.0)
     {
      Print("Invalid previous candle data, skipping stop placement.");
      return;
     }

   ENUM_ORDER_TYPE upperType=InpReverseSignal?ORDER_TYPE_SELL_LIMIT:ORDER_TYPE_BUY_STOP;
   ENUM_ORDER_TYPE lowerType=InpReverseSignal?ORDER_TYPE_BUY_LIMIT :ORDER_TYPE_SELL_STOP;
   bool upperIsBuy=!InpReverseSignal;
   bool lowerIsBuy= InpReverseSignal;

   double upperPrice=AdjustStopPrice(_Symbol,upperType,prevHigh+PipsToPrice(_Symbol,InpEntryBufferPips));
   double lowerPrice=AdjustStopPrice(_Symbol,lowerType,prevLow -PipsToPrice(_Symbol,InpEntryBufferPips));

   double lot=InpUseRiskPercent
              ? CalcLotByRisk(_Symbol,InpRiskPercent,InpStopLossPips)
              : NormalizeVolume(_Symbol,InpLotSize);

   int digits=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   double upperSl,upperTp,lowerSl,lowerTp;

   if(InpUseVirtualExits)
     {
      // No real TP (a missed TP just leaves a winner open, not an account risk), and a
      // wide real SL kept only as a crash/disconnect backstop - the tight virtual SL
      // below is what actually protects the trade under normal operation.
      double backstopPips=InpStopLossPips*InpBackstopSLMultiplier;
      upperSl=NormalizeDouble(upperIsBuy?upperPrice-PipsToPrice(_Symbol,backstopPips):upperPrice+PipsToPrice(_Symbol,backstopPips),digits);
      upperTp=0.0;
      lowerSl=NormalizeDouble(lowerIsBuy?lowerPrice-PipsToPrice(_Symbol,backstopPips):lowerPrice+PipsToPrice(_Symbol,backstopPips),digits);
      lowerTp=0.0;
     }
   else
     {
      upperSl=NormalizeDouble(upperIsBuy?upperPrice-PipsToPrice(_Symbol,InpStopLossPips)  :upperPrice+PipsToPrice(_Symbol,InpStopLossPips),  digits);
      upperTp=NormalizeDouble(upperIsBuy?upperPrice+PipsToPrice(_Symbol,InpTakeProfitPips):upperPrice-PipsToPrice(_Symbol,InpTakeProfitPips),digits);
      lowerSl=NormalizeDouble(lowerIsBuy?lowerPrice-PipsToPrice(_Symbol,InpStopLossPips)  :lowerPrice+PipsToPrice(_Symbol,InpStopLossPips),  digits);
      lowerTp=NormalizeDouble(lowerIsBuy?lowerPrice+PipsToPrice(_Symbol,InpTakeProfitPips):lowerPrice-PipsToPrice(_Symbol,InpTakeProfitPips),digits);
     }

   ENUM_ORDER_TYPE_TIME typeTime=ORDER_TIME_GTC;
   datetime expiration=0;
   if(InpPendingExpiryMinutes>0)
     {
      typeTime=ORDER_TIME_SPECIFIED;
      expiration=TimeCurrent()+InpPendingExpiryMinutes*60;
     }

   string comment=StringFormat("BOS_%d",(int)g_lastBarTime);

   if(trade.OrderOpen(_Symbol,upperType,lot,0.0,upperPrice,upperSl,upperTp,typeTime,expiration,comment))
      g_pendingUpperTicket=trade.ResultOrder();
   else
      Print(EnumToString(upperType)," failed: ",trade.ResultRetcodeDescription()," price=",DoubleToString(upperPrice,digits));

   if(trade.OrderOpen(_Symbol,lowerType,lot,0.0,lowerPrice,lowerSl,lowerTp,typeTime,expiration,comment))
      g_pendingLowerTicket=trade.ResultOrder();
   else
      Print(EnumToString(lowerType)," failed: ",trade.ResultRetcodeDescription()," price=",DoubleToString(lowerPrice,digits));
  }

void CloseDrawdownPositions()
  {
   ulong tickets[];
   int n=GetPositionTickets(_Symbol,InpMagicNumber,tickets);
   for(int i=0;i<n;i++)
     {
      if(!PositionSelectByTicket(tickets[i]))
         continue;
      double profit=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      if(profit<0.0)
        {
         if(trade.PositionClose(tickets[i]))
            Print("Closed drawdown position #",tickets[i]," profit=",DoubleToString(profit,2));
         else
            Print("Failed to close drawdown position #",tickets[i]," error=",GetLastError());
        }
     }
  }

// Idempotent breakeven check: recomputes the target SL from position state every call,
// so it self-heals across EA restarts without needing separate "already armed" tracking.
void ManageBreakeven()
  {
   ulong tickets[];
   int n=GetPositionTickets(_Symbol,InpMagicNumber,tickets);
   if(n==0) return;

   double spreadPips=CurrentSpreadPips(_Symbol);
   double bePips=spreadPips+InpBreakevenBufferPips;
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   int digits=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);

   for(int i=0;i<n;i++)
     {
      if(!PositionSelectByTicket(tickets[i]))
         continue;

      long type=PositionGetInteger(POSITION_TYPE);
      double entry=PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSl=PositionGetDouble(POSITION_SL);
      double tp=PositionGetDouble(POSITION_TP);

      if(type==POSITION_TYPE_BUY)
        {
         double profitPips=PriceToPips(_Symbol,bid-entry);
         double beSl=NormalizeDouble(entry+PipsToPrice(_Symbol,bePips),digits);
         if(profitPips>=InpBreakevenTriggerPips && currentSl<beSl)
           {
            if(trade.PositionModify(tickets[i],beSl,tp))
               Print("Breakeven applied to #",tickets[i]," new SL=",DoubleToString(beSl,digits));
           }
        }
      else if(type==POSITION_TYPE_SELL)
        {
         double profitPips=PriceToPips(_Symbol,entry-ask);
         double beSl=NormalizeDouble(entry-PipsToPrice(_Symbol,bePips),digits);
         if(profitPips>=InpBreakevenTriggerPips && (currentSl>beSl || currentSl==0.0))
           {
            if(trade.PositionModify(tickets[i],beSl,tp))
               Print("Breakeven applied to #",tickets[i]," new SL=",DoubleToString(beSl,digits));
           }
        }
     }
  }

void CloseVirtual(ulong ticket,string reason)
  {
   if(trade.PositionClose(ticket))
      Print("Closed position #",ticket," via ",reason);
   else
      Print("Failed to close position #",ticket," (",reason,") error=",GetLastError());
  }

// EA-side TP/SL/breakeven: the broker only holds a wide backstop SL (see
// PlaceBreakoutStops), so under normal operation this is what actually exits trades.
// Once ManageTrailing has marked a position's state trailingActive, the fixed TP
// check below is skipped for it - the trailing SL is its only exit from that point.
void ManageVirtualExits()
  {
   ulong tickets[];
   int n=GetPositionTickets(_Symbol,InpMagicNumber,tickets);
   if(n==0) { PrunePositionStates(_Symbol,InpMagicNumber); return; }

   PrunePositionStates(_Symbol,InpMagicNumber);

   double spreadPips=CurrentSpreadPips(_Symbol);
   double bePips=spreadPips+InpBreakevenBufferPips;
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   int digits=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);

   for(int i=0;i<n;i++)
     {
      if(!PositionSelectByTicket(tickets[i]))
         continue;

      long type=PositionGetInteger(POSITION_TYPE);
      double entry=PositionGetDouble(POSITION_PRICE_OPEN);

      if(type==POSITION_TYPE_BUY)
        {
         double originalSl=entry-PipsToPrice(_Symbol,InpStopLossPips);
         int idx=EnsurePositionState(tickets[i],originalSl);

         double profitPips=PriceToPips(_Symbol,bid-entry);
         if(profitPips>=InpBreakevenTriggerPips)
           {
            double beSl=NormalizeDouble(entry+PipsToPrice(_Symbol,bePips),digits);
            if(beSl>g_positionStates[idx].sl)
               g_positionStates[idx].sl=beSl;
           }

         double virtualTp=entry+PipsToPrice(_Symbol,InpTakeProfitPips);

         if(!g_positionStates[idx].trailingActive && bid>=virtualTp)
            CloseVirtual(tickets[i],"virtual TP");
         else if(bid<=g_positionStates[idx].sl)
            CloseVirtual(tickets[i],"virtual SL");
        }
      else if(type==POSITION_TYPE_SELL)
        {
         double originalSl=entry+PipsToPrice(_Symbol,InpStopLossPips);
         int idx=EnsurePositionState(tickets[i],originalSl);

         double profitPips=PriceToPips(_Symbol,entry-ask);
         if(profitPips>=InpBreakevenTriggerPips)
           {
            double beSl=NormalizeDouble(entry-PipsToPrice(_Symbol,bePips),digits);
            if(beSl<g_positionStates[idx].sl)
               g_positionStates[idx].sl=beSl;
           }

         double virtualTp=entry-PipsToPrice(_Symbol,InpTakeProfitPips);

         if(!g_positionStates[idx].trailingActive && ask<=virtualTp)
            CloseVirtual(tickets[i],"virtual TP");
         else if(ask>=g_positionStates[idx].sl)
            CloseVirtual(tickets[i],"virtual SL");
        }
     }
  }

// Runs once per new candle close (not on every tick): for any position that is
// currently profitable, ratchets its protective stop to InpTrailingDistancePips
// behind the candle-close price and marks it as trailing-active, which switches
// off the fixed TP for that position (see ManageVirtualExits/ManageBreakeven) so
// it can keep running instead of capping out at the original take profit.
void ManageTrailing()
  {
   if(!InpUseTrailingStop) return;

   ulong tickets[];
   int n=GetPositionTickets(_Symbol,InpMagicNumber,tickets);
   if(n==0) return;

   PrunePositionStates(_Symbol,InpMagicNumber);

   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   int digits=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);

   for(int i=0;i<n;i++)
     {
      if(!PositionSelectByTicket(tickets[i]))
         continue;

      double profit=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      if(profit<=0.0)
         continue;

      long type=PositionGetInteger(POSITION_TYPE);
      double entry=PositionGetDouble(POSITION_PRICE_OPEN);

      // In real-order mode there's no virtual state yet on first touch, so fall back
      // to the current real SL (which breakeven may have already tightened) rather
      // than the original entry-based SL - otherwise trailing could loosen it.
      double fallbackSl;
      if(InpUseVirtualExits)
         fallbackSl=(type==POSITION_TYPE_BUY)
                    ? entry-PipsToPrice(_Symbol,InpStopLossPips)
                    : entry+PipsToPrice(_Symbol,InpStopLossPips);
      else
         fallbackSl=PositionGetDouble(POSITION_SL);

      int idx=EnsurePositionState(tickets[i],fallbackSl);
      g_positionStates[idx].trailingActive=true;

      double candidateSl;
      bool improved=false;
      if(type==POSITION_TYPE_BUY)
        {
         candidateSl=NormalizeDouble(bid-PipsToPrice(_Symbol,InpTrailingDistancePips),digits);
         if(candidateSl>g_positionStates[idx].sl)
           {
            g_positionStates[idx].sl=candidateSl;
            improved=true;
           }
        }
      else
        {
         candidateSl=NormalizeDouble(ask+PipsToPrice(_Symbol,InpTrailingDistancePips),digits);
         if(candidateSl<g_positionStates[idx].sl)
           {
            g_positionStates[idx].sl=candidateSl;
            improved=true;
           }
        }

      if(!InpUseVirtualExits)
        {
         if(trade.PositionModify(tickets[i],g_positionStates[idx].sl,0.0))
           {
            if(improved)
               Print("Trailing SL updated for #",tickets[i]," new SL=",DoubleToString(g_positionStates[idx].sl,digits));
           }
         else
            Print("Failed to update trailing SL for #",tickets[i]," error=",GetLastError());
        }
      else if(improved)
         Print("Trailing SL updated (virtual) for #",tickets[i]," new SL=",DoubleToString(g_positionStates[idx].sl,digits));
     }
  }

// Closes every open position and cancels every pending order from this EA, once per
// calendar day at InpDailyFlattenHour (server time) - e.g. midnight to avoid holding
// overnight. Checked every tick so it fires promptly after the hour boundary.
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
   CancelStalePendingOrders();

   ulong tickets[];
   int n=GetPositionTickets(_Symbol,InpMagicNumber,tickets);
   for(int i=0;i<n;i++)
     {
      if(trade.PositionClose(tickets[i]))
         Print("Daily flatten: closed position #",tickets[i]);
      else
         Print("Daily flatten: failed to close #",tickets[i]," error=",GetLastError());
     }

   ArrayResize(g_positionStates,0);
  }

bool SpreadOk()
  {
   if(InpMaxSpreadPips<=0.0)
      return true;
   return CurrentSpreadPips(_Symbol)<=InpMaxSpreadPips;
  }

// Compares the just-closed candle's tick volume (the one whose high/low defines this
// bar's breakout levels) against the average of the preceding InpVolumeLookbackBars
// candles, so stops are only placed once activity picks up rather than every bar.
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
