#property copyright "BreakoutStopBot"
#property version   "2.00"
#property strict
#property description "Candle breakout bot: places a Buy Stop / Sell Stop OCO pair at the prior "
#property description "candle's high/low every bar, manages TP/SL/breakeven, closes drawdown "
#property description "positions at candle close, and flattens everything once a day."

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
input int    InpPendingExpiryMinutes   = 0;      // 0 = GTC (orders are replaced every bar regardless)

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

input group "=== Daily Flatten ==="
input bool   InpUseDailyFlatten        = true;   // Close all positions and cancel all pending orders once per day
input int    InpDailyFlattenHour       = 0;      // Server-time hour to flatten (0 = midnight)

CTrade           trade;
ENUM_TIMEFRAMES  g_timeframe            = PERIOD_M1;
datetime         g_lastBarTime          = 0;
ulong            g_pendingBuyStopTicket = 0;
ulong            g_pendingSellStopTicket= 0;
int              g_lastFlattenDay       = -1;

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
         " breakevenTrigger=",DoubleToString(InpBreakevenTriggerPips,1),"pips",
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

   if(InpCancelPendingOnRemove && reason==REASON_REMOVE)
     {
      if(g_pendingBuyStopTicket!=0 && OrderSelect(g_pendingBuyStopTicket))
         trade.OrderDelete(g_pendingBuyStopTicket);
      if(g_pendingSellStopTicket!=0 && OrderSelect(g_pendingSellStopTicket))
         trade.OrderDelete(g_pendingSellStopTicket);
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
   ManageBreakeven();

   if(IsNewBar(_Symbol,g_timeframe,g_lastBarTime))
      OnNewBar();
  }

void OnNewBar()
  {
   CloseDrawdownPositions();
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
   if(g_pendingBuyStopTicket!=0)
     {
      if(OrderSelect(g_pendingBuyStopTicket))
         trade.OrderDelete(g_pendingBuyStopTicket);
      g_pendingBuyStopTicket=0;
     }
   if(g_pendingSellStopTicket!=0)
     {
      if(OrderSelect(g_pendingSellStopTicket))
         trade.OrderDelete(g_pendingSellStopTicket);
      g_pendingSellStopTicket=0;
     }
  }

// If one side of the current OCO pair filled or vanished and the other is still
// pending, cancel the sibling so only one direction can be active at a time.
void EnforceOco()
  {
   if(g_pendingBuyStopTicket==0 && g_pendingSellStopTicket==0)
      return;

   bool buyExists =g_pendingBuyStopTicket!=0  && OrderSelect(g_pendingBuyStopTicket);
   bool sellExists=g_pendingSellStopTicket!=0 && OrderSelect(g_pendingSellStopTicket);

   if(g_pendingBuyStopTicket!=0 && !buyExists)
      g_pendingBuyStopTicket=0;
   if(g_pendingSellStopTicket!=0 && !sellExists)
      g_pendingSellStopTicket=0;

   if(g_pendingBuyStopTicket==0 && g_pendingSellStopTicket!=0 && sellExists)
     {
      trade.OrderDelete(g_pendingSellStopTicket);
      g_pendingSellStopTicket=0;
     }
   else if(g_pendingSellStopTicket==0 && g_pendingBuyStopTicket!=0 && buyExists)
     {
      trade.OrderDelete(g_pendingBuyStopTicket);
      g_pendingBuyStopTicket=0;
     }
  }

void PlaceBreakoutStops()
  {
   double prevHigh=iHigh(_Symbol,g_timeframe,1);
   double prevLow =iLow(_Symbol,g_timeframe,1);
   if(prevHigh<=0.0 || prevLow<=0.0)
     {
      Print("Invalid previous candle data, skipping stop placement.");
      return;
     }

   double buyStopPrice =AdjustStopPrice(_Symbol,ORDER_TYPE_BUY_STOP, prevHigh+PipsToPrice(_Symbol,InpEntryBufferPips));
   double sellStopPrice=AdjustStopPrice(_Symbol,ORDER_TYPE_SELL_STOP,prevLow -PipsToPrice(_Symbol,InpEntryBufferPips));

   double lot=InpUseRiskPercent
              ? CalcLotByRisk(_Symbol,InpRiskPercent,InpStopLossPips)
              : NormalizeVolume(_Symbol,InpLotSize);

   int digits=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   double buySl =NormalizeDouble(buyStopPrice -PipsToPrice(_Symbol,InpStopLossPips),  digits);
   double buyTp =NormalizeDouble(buyStopPrice +PipsToPrice(_Symbol,InpTakeProfitPips),digits);
   double sellSl=NormalizeDouble(sellStopPrice+PipsToPrice(_Symbol,InpStopLossPips),  digits);
   double sellTp=NormalizeDouble(sellStopPrice-PipsToPrice(_Symbol,InpTakeProfitPips),digits);

   ENUM_ORDER_TYPE_TIME typeTime=ORDER_TIME_GTC;
   datetime expiration=0;
   if(InpPendingExpiryMinutes>0)
     {
      typeTime=ORDER_TIME_SPECIFIED;
      expiration=TimeCurrent()+InpPendingExpiryMinutes*60;
     }

   string comment=StringFormat("BOS_%d",(int)g_lastBarTime);

   if(trade.OrderOpen(_Symbol,ORDER_TYPE_BUY_STOP,lot,0.0,buyStopPrice,buySl,buyTp,typeTime,expiration,comment))
      g_pendingBuyStopTicket=trade.ResultOrder();
   else
      Print("Buy stop failed: ",trade.ResultRetcodeDescription()," price=",DoubleToString(buyStopPrice,digits));

   if(trade.OrderOpen(_Symbol,ORDER_TYPE_SELL_STOP,lot,0.0,sellStopPrice,sellSl,sellTp,typeTime,expiration,comment))
      g_pendingSellStopTicket=trade.ResultOrder();
   else
      Print("Sell stop failed: ",trade.ResultRetcodeDescription()," price=",DoubleToString(sellStopPrice,digits));
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
  }
