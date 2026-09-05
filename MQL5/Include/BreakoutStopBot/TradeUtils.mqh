#ifndef __BREAKOUTSTOPBOT_TRADEUTILS_MQH__
#define __BREAKOUTSTOPBOT_TRADEUTILS_MQH__

// A "pip" is 10 points on 3/5-digit (fractional) symbols, 1 point otherwise.
double PipSize(const string symbol)
  {
   int digits=(int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);
   double point=SymbolInfoDouble(symbol,SYMBOL_POINT);
   return (digits==3 || digits==5) ? point*10.0 : point;
  }

double PipsToPrice(const string symbol,double pips)
  {
   return pips*PipSize(symbol);
  }

double PriceToPips(const string symbol,double priceDistance)
  {
   double pip=PipSize(symbol);
   return pip>0.0 ? priceDistance/pip : 0.0;
  }

double NormalizeVolume(const string symbol,double volume)
  {
   double step=SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);
   double minVol=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN);
   double maxVol=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MAX);
   if(step<=0.0) step=0.01;
   double normalized=MathRound(volume/step)*step;
   normalized=MathMax(minVol,MathMin(maxVol,normalized));
   return NormalizeDouble(normalized,2);
  }

// Clamps a pending order price to respect the broker's minimum stop distance,
// so a breakout (or fade, in reverse mode) level sitting too close to the
// current price doesn't get rejected. Handles both stop and limit orders since
// InpReverseSignal switches between them.
double AdjustStopPrice(const string symbol,ENUM_ORDER_TYPE orderType,double price)
  {
   long stopsLevelPoints=SymbolInfoInteger(symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double point=SymbolInfoDouble(symbol,SYMBOL_POINT);
   double minDistance=stopsLevelPoints*point;
   int digits=(int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);
   double ask=SymbolInfoDouble(symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(symbol,SYMBOL_BID);

   if(orderType==ORDER_TYPE_BUY_STOP)
     {
      double minPrice=ask+minDistance;
      if(price<minPrice) price=minPrice;
     }
   else if(orderType==ORDER_TYPE_SELL_STOP)
     {
      double maxPrice=bid-minDistance;
      if(price>maxPrice) price=maxPrice;
     }
   else if(orderType==ORDER_TYPE_BUY_LIMIT)
     {
      double maxPrice=ask-minDistance;
      if(price>maxPrice) price=maxPrice;
     }
   else if(orderType==ORDER_TYPE_SELL_LIMIT)
     {
      double minPrice=bid+minDistance;
      if(price<minPrice) price=minPrice;
     }
   return NormalizeDouble(price,digits);
  }

bool IsNewBar(const string symbol,ENUM_TIMEFRAMES timeframe,datetime &lastBarTime)
  {
   datetime currentBarTime=iTime(symbol,timeframe,0);
   if(currentBarTime==0) return false;
   if(currentBarTime!=lastBarTime)
     {
      lastBarTime=currentBarTime;
      return true;
     }
   return false;
  }

int GetPositionTickets(const string symbol,ulong magic,ulong &tickets[])
  {
   ArrayResize(tickets,0);
   int total=PositionsTotal();
   for(int i=0;i<total;i++)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=magic) continue;
      int n=ArraySize(tickets);
      ArrayResize(tickets,n+1);
      tickets[n]=ticket;
     }
   return ArraySize(tickets);
  }

int CountPositionsByMagic(const string symbol,ulong magic)
  {
   ulong tickets[];
   return GetPositionTickets(symbol,magic,tickets);
  }

double CurrentSpreadPips(const string symbol)
  {
   double ask=SymbolInfoDouble(symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(symbol,SYMBOL_BID);
   return PriceToPips(symbol,ask-bid);
  }

string TimeframeLabel(ENUM_TIMEFRAMES timeframe)
  {
   string label=EnumToString(timeframe);
   StringReplace(label,"PERIOD_","");
   return label;
  }

datetime StartOfDay(datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t,dt);
   dt.hour=0; dt.min=0; dt.sec=0;
   return StructToTime(dt);
  }

datetime StartOfWeek(datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t,dt);
   int daysSinceMonday=(dt.day_of_week==0)?6:(dt.day_of_week-1);
   return StartOfDay(t)-daysSinceMonday*86400;
  }

datetime StartOfMonth(datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t,dt);
   dt.day=1; dt.hour=0; dt.min=0; dt.sec=0;
   return StructToTime(dt);
  }

#endif
