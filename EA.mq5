//+------------------------------------------------------------------+
//|                                                    EA.mq5        |
//|                                    Auto FX Trading Tool         |
//+------------------------------------------------------------------+
#property copyright ""
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

input double   Lots                  = 0.1;
input int      MagicNumber           = 221122;
input int      ERPeriod              = 20;
input double   ERTrendThreshold      = 0.35;
input double   ERChopThreshold       = 0.25;
input int      H1SlopeLookback       = 5;
input bool     UseH1SlopeFilter      = true;
input int      MA21Period            = 21;
input int      MA50Period            = 50;
input int      MA200Period           = 200;
input int      ATRPeriod             = 14;
input double   ATRMinDistanceMult    = 0.2;
input double   ATRMaxDistanceMult    = 1.2;
input int      MomentumLookback      = 5;
input int      MASlopeLookback       = 3;
input bool     UseSpreadAtrFilter    = false;
input int      MaxSpreadPoints       = 30;
input double   SpreadAtrMult         = 0.2;
input int      SessionStartHour      = 16; // server time
input int      SessionEndHour        = 2;  // server time (can cross midnight)
input int      CooldownBars          = 3;
input double   SameLevelPips         = 8.0;
input int      SwingLookback         = 8;
input double   SLBufferAtrMult       = 0.3;
input double   TP1RR                 = 1.0;
input double   TP2RR                 = 1.8;
input double   BreakevenOffsetPips   = 0.0;

enum ModeState
{
   MODE_TREND = 0,
   MODE_CHOP  = 1,
   MODE_GRAY  = 2
};

CTrade trade;
datetime lastBarTime = 0;
datetime lastExitTime = 0;
double lastEntryPrice = 0.0;

double PipsToPrice(double pips)
{
   double pip = (_Digits == 3 || _Digits == 5) ? _Point * 10.0 : _Point;
   return pips * pip;
}

bool IsNewBar()
{
   datetime current = iTime(_Symbol, PERIOD_M15, 0);
   if(current != lastBarTime)
   {
      lastBarTime = current;
      return true;
   }
   return false;
}

bool SessionAllowed(datetime time)
{
   MqlDateTime tm;
   TimeToStruct(time, tm);
   if(SessionStartHour == SessionEndHour)
   {
      return true;
   }
   if(SessionStartHour < SessionEndHour)
   {
      return (tm.hour >= SessionStartHour && tm.hour < SessionEndHour);
   }
   return (tm.hour >= SessionStartHour || tm.hour < SessionEndHour);
}

double GetMA(ENUM_TIMEFRAMES tf, int period, int shift)
{
   int handle = iMA(_Symbol, tf, period, 0, MODE_SMA, PRICE_CLOSE);
   if(handle == INVALID_HANDLE)
      return 0.0;
   double buffer[];
   if(CopyBuffer(handle, 0, shift, 1, buffer) != 1)
      return 0.0;
   return buffer[0];
}

double GetATR(ENUM_TIMEFRAMES tf, int period, int shift)
{
   int handle = iATR(_Symbol, tf, period);
   if(handle == INVALID_HANDLE)
      return 0.0;
   double buffer[];
   if(CopyBuffer(handle, 0, shift, 1, buffer) != 1)
      return 0.0;
   return buffer[0];
}

double GetClose(ENUM_TIMEFRAMES tf, int shift)
{
   double buffer[];
   if(CopyClose(_Symbol, tf, shift, 1, buffer) != 1)
      return 0.0;
   return buffer[0];
}

double GetHigh(ENUM_TIMEFRAMES tf, int shift)
{
   double buffer[];
   if(CopyHigh(_Symbol, tf, shift, 1, buffer) != 1)
      return 0.0;
   return buffer[0];
}

double GetLow(ENUM_TIMEFRAMES tf, int shift)
{
   double buffer[];
   if(CopyLow(_Symbol, tf, shift, 1, buffer) != 1)
      return 0.0;
   return buffer[0];
}

double CalculateER(int period)
{
   int total = period + 2;
   double closes[];
   if(CopyClose(_Symbol, PERIOD_M15, 1, total, closes) != total)
      return 0.0;
   double change = MathAbs(closes[0] - closes[period]);
   double volatility = 0.0;
   for(int i = 1; i <= period; i++)
   {
      volatility += MathAbs(closes[i - 1] - closes[i]);
   }
   if(volatility <= 0.0)
      return 0.0;
   return change / volatility;
}

ModeState DetermineMode(double er)
{
   if(er >= ERTrendThreshold)
      return MODE_TREND;
   if(er <= ERChopThreshold)
      return MODE_CHOP;
   return MODE_GRAY;
}

bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            return true;
      }
   }
   return false;
}

bool CooldownOK()
{
   if(lastExitTime == 0)
      return true;
   int barsSince = iBarShift(_Symbol, PERIOD_M15, lastExitTime, true);
   return (barsSince >= CooldownBars);
}

bool SameLevelOK(double price)
{
   if(lastEntryPrice == 0.0)
      return true;
   double distance = MathAbs(price - lastEntryPrice);
   return (distance > PipsToPrice(SameLevelPips));
}

bool MAAlignment(bool bullish, double ma21, double ma50)
{
   if(bullish)
      return ma21 > ma50;
   return ma21 < ma50;
}

bool MASlopeOK(bool bullish, ENUM_TIMEFRAMES tf, int period, int lookback)
{
   double current = GetMA(tf, period, 1);
   double past = GetMA(tf, period, 1 + lookback);
   if(bullish)
      return current > past;
   return current < past;
}

bool MomentumOK(bool bullish)
{
   bool maSlope = MASlopeOK(bullish, PERIOD_M15, MA21Period, MASlopeLookback);
   double highest = -DBL_MAX;
   double lowest = DBL_MAX;
   for(int i = 1; i <= MomentumLookback; i++)
   {
      highest = MathMax(highest, GetHigh(PERIOD_M15, i));
      lowest = MathMin(lowest, GetLow(PERIOD_M15, i));
   }
   double close1 = GetClose(PERIOD_M15, 1);
   bool breakHigh = close1 > highest;
   bool breakLow = close1 < lowest;
   return maSlope || (bullish ? breakHigh : breakLow);
}

double GetSwingLow()
{
   double low = DBL_MAX;
   for(int i = 1; i <= SwingLookback; i++)
   {
      low = MathMin(low, GetLow(PERIOD_M15, i));
   }
   return low;
}

double GetSwingHigh()
{
   double high = -DBL_MAX;
   for(int i = 1; i <= SwingLookback; i++)
   {
      high = MathMax(high, GetHigh(PERIOD_M15, i));
   }
   return high;
}

void LogDecision(const string modeText, const string trendText, double er, int spread, bool sessionOk,
                 bool cooldownOk, bool entryOk, const string reasons)
{
   string line = StringFormat("%s,%s,M15,%s,%s,%.3f,%d,%s,%s,%s,%s",
                              TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
                              _Symbol,
                              modeText,
                              trendText,
                              er,
                              spread,
                              sessionOk ? "1" : "0",
                              cooldownOk ? "1" : "0",
                              entryOk ? "1" : "0",
                              reasons);
   Print(line);
}

void ManageBreakeven()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) <= 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      long type = PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double risk = (type == POSITION_TYPE_BUY) ? (openPrice - sl) : (sl - openPrice);
      if(risk <= 0.0)
         continue;
      double tp1Level = (type == POSITION_TYPE_BUY) ? (openPrice + risk * TP1RR) : (openPrice - risk * TP1RR);
      double beOffset = PipsToPrice(BreakevenOffsetPips);
      if(type == POSITION_TYPE_BUY)
      {
         if(SymbolInfoDouble(_Symbol, SYMBOL_BID) >= tp1Level)
         {
            double newSl = MathMax(openPrice + beOffset, sl);
            trade.PositionModify(_Symbol, newSl, PositionGetDouble(POSITION_TP));
         }
      }
      else
      {
         if(SymbolInfoDouble(_Symbol, SYMBOL_ASK) <= tp1Level)
         {
            double newSl = MathMin(openPrice - beOffset, sl);
            trade.PositionModify(_Symbol, newSl, PositionGetDouble(POSITION_TP));
         }
      }
   }
}

void OnTick()
{
   ManageBreakeven();
   if(!IsNewBar())
      return;

   string reasons = "";
   int spread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double atr = GetATR(PERIOD_M15, ATRPeriod, 1);
   int maxSpread = MaxSpreadPoints;
   if(UseSpreadAtrFilter && atr > 0.0)
      maxSpread = (int)MathRound((atr / _Point) * SpreadAtrMult);
   if(spread > maxSpread)
      reasons += "SPREAD_HIGH;";

   bool sessionOk = SessionAllowed(TimeCurrent());
   if(!sessionOk)
      reasons += "SESSION_BLOCK;";

   bool cooldownOk = CooldownOK();
   if(!cooldownOk)
      reasons += "COOLDOWN;";

   double er = CalculateER(ERPeriod);
   ModeState mode = DetermineMode(er);
   if(mode == MODE_CHOP)
      reasons += "MODE_CHOP;";
   if(mode == MODE_GRAY)
      reasons += "MODE_GRAY;";

   double h1Close = GetClose(PERIOD_H1, 1);
   double h1MA200 = GetMA(PERIOD_H1, MA200Period, 1);
   bool bullishTrend = h1Close > h1MA200;
   bool bearishTrend = h1Close < h1MA200;
   bool slopeOk = true;
   if(UseH1SlopeFilter)
   {
      slopeOk = MASlopeOK(bullishTrend, PERIOD_H1, MA200Period, H1SlopeLookback);
      if(!slopeOk)
         reasons += "MA_SLOPE_FAIL;";
   }

   bool entryOk = false;
   string trendText = bullishTrend ? "Bull" : (bearishTrend ? "Bear" : "Flat");
   string modeText = (mode == MODE_TREND) ? "Trend" : (mode == MODE_CHOP ? "Chop" : "Gray");

   bool canTrade = (reasons == "");
   if(canTrade && mode == MODE_TREND && slopeOk && !HasOpenPosition())
   {
      double close1 = GetClose(PERIOD_M15, 1);
      double close2 = GetClose(PERIOD_M15, 2);
      double ma21 = GetMA(PERIOD_M15, MA21Period, 1);
      double ma50 = GetMA(PERIOD_M15, MA50Period, 1);
      double atrDistance = MathAbs(close1 - ma50);

      bool alignmentOk = MAAlignment(bullishTrend, ma21, ma50);
      if(!alignmentOk)
         reasons += "ALIGN_FAIL;";

      bool slope50Ok = MASlopeOK(bullishTrend, PERIOD_M15, MA50Period, MASlopeLookback);
      if(!slope50Ok)
         reasons += "MA_SLOPE_FAIL;";

      bool distanceOk = (atr > 0.0 && atrDistance >= atr * ATRMinDistanceMult && atrDistance <= atr * ATRMaxDistanceMult);
      if(!distanceOk)
         reasons += "DISTANCE_FAIL;";

      bool pullback = false;
      if(bullishTrend)
         pullback = (close2 < ma21 || close2 < ma50) && close1 > ma21;
      else if(bearishTrend)
         pullback = (close2 > ma21 || close2 > ma50) && close1 < ma21;
      if(!pullback)
         reasons += "PULLBACK_NOT_CONFIRMED;";

      bool momentum = MomentumOK(bullishTrend);
      if(!momentum)
         reasons += "MOMENTUM_FAIL;";

      if(alignmentOk && slope50Ok && distanceOk && pullback && momentum)
      {
         double currentPrice = bullishTrend ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(!SameLevelOK(currentPrice))
            reasons += "SAME_LEVEL_BLOCK;";
         else
            entryOk = true;
      }
   }

   if(entryOk && sessionOk && cooldownOk && spread <= maxSpread && (bullishTrend || bearishTrend))
   {
      double atrLocal = atr;
      double sl = 0.0;
      double tp1 = 0.0;
      double tp2 = 0.0;
      if(bullishTrend)
      {
         double swingLow = GetSwingLow();
         sl = swingLow - atrLocal * SLBufferAtrMult;
         double entry = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double risk = entry - sl;
         tp1 = entry + risk * TP1RR;
         tp2 = entry + risk * TP2RR;
         double halfLots = Lots / 2.0;
         trade.SetExpertMagicNumber(MagicNumber);
         trade.Buy(halfLots, _Symbol, entry, sl, tp1, "TP1");
         trade.Buy(halfLots, _Symbol, entry, sl, tp2, "TP2");
         lastEntryPrice = entry;
      }
      else if(bearishTrend)
      {
         double swingHigh = GetSwingHigh();
         sl = swingHigh + atrLocal * SLBufferAtrMult;
         double entry = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double risk = sl - entry;
         tp1 = entry - risk * TP1RR;
         tp2 = entry - risk * TP2RR;
         double halfLots = Lots / 2.0;
         trade.SetExpertMagicNumber(MagicNumber);
         trade.Sell(halfLots, _Symbol, entry, sl, tp1, "TP1");
         trade.Sell(halfLots, _Symbol, entry, sl, tp2, "TP2");
         lastEntryPrice = entry;
      }
   }
   else
   {
      if(HasOpenPosition())
         reasons += "POSITION_EXISTS;";
      if(!bullishTrend && !bearishTrend)
         reasons += "TREND_MISMATCH;";
   }

   LogDecision(modeText, trendText, er, spread, sessionOk, cooldownOk, entryOk, reasons);
}

void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      if(trans.deal_entry == DEAL_ENTRY_OUT && trans.symbol == _Symbol)
      {
         lastExitTime = trans.time;
      }
   }
}
