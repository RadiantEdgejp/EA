//+------------------------------------------------------------------+
//|                                                    EA.mq5        |
//|                                        Auto FX Trading Tool     |
//+------------------------------------------------------------------+
#property copyright ""
#property version   "1.16"
#property strict

#include <Trade/Trade.mqh>

input double InpLots               = 0.1;
input int    InpMagicNumber        = 221122;
input bool   InpDebug              = true;
input int    InpERLen              = 28;
input double InpERTrendEnter       = 0.30;
input double InpERTrendHold        = 0.20;
input double InpERRangeExit        = 0.15;
input int    InpMaxSpreadPoints    = 30;
input int    InpSessionStartHour   = 7;
input int    InpSessionStartMinute = 0;
input int    InpSessionEndHour     = 23;
input int    InpSessionEndMinute   = 0;
input int    InpCooldownBars       = 1;
input int    InpSameZonePoints     = 40;
input int    InpEMA200Period       = 200;
input int    InpEMA21Period        = 21;
input int    InpEMA50Period        = 50;
input int    InpATRPeriod          = 14;
input double InpSLATRMult          = 1.0;
input double InpTP1RR              = 1.0;
input double InpTP2RR              = 2.4;
input double InpTP1ClosePercent    = 30.0;
input bool   InpUseBreakeven       = true;
input int    InpBreakevenOffsetPts = 0;
input bool   InpUseTrailingAfterTP1 = true;
input double InpTrailATRMult        = 1.0;
input int    InpSummaryEveryBars    = 200;
input int    InpMASlopeLookback    = 3;
input double InpATRMinDistMult     = 0.1;
input double InpATRMaxDistMult     = 2.0;
input int    InpMomentumLookback   = 5;
input bool   InpUseAlignmentFilter = false;
input bool   InpUseSlopeFilter     = false;
input bool   InpUseDistanceFilter  = true;
input bool   InpUseMomentumFilter  = false;

enum ModeState
{
   MODE_TREND = 0,
   MODE_RANGE = 1
};

enum TrendDir
{
   TREND_OFF = 0,
   TREND_LONG = 1,
   TREND_SHORT = -1
};

enum SkipReason
{
   SKIP_NONE = 0,
   SKIP_SPREAD,
   SKIP_TIME,
   SKIP_COOLDOWN,
   SKIP_SAMEZONE,
   SKIP_RANGE,
   SKIP_TREND_OFF,
   SKIP_ALIGN,
   SKIP_SLOPE,
   SKIP_DISTANCE,
   SKIP_MOMENTUM,
   SKIP_INVALID_HANDLE,
   SKIP_NO_SIGNAL,
   SKIP_TRADE_DISABLED,
   SKIP_POSITION_EXISTS,
   SKIP_ORDER_FAIL,
   SKIP_LOT_INVALID,
   SKIP_STOPLEVEL
};

CTrade trade;

int handleEma200H1 = INVALID_HANDLE;
int handleEma21M15 = INVALID_HANDLE;
int handleEma50M15 = INVALID_HANDLE;
int handleAtrM15   = INVALID_HANDLE;

datetime lastBarTime = 0;
datetime lastEntryBarTime = 0;
double lastEntryPrice = 0.0;
bool tp1Done = false;
double tp1Price = 0.0;
double tp2Price = 0.0;
ModeState currentMode = MODE_RANGE;
long barsProcessed = 0;

long skipCounts[18];

double PipsToPoints(double pips)
{
   double pip = (_Digits == 3 || _Digits == 5) ? 10.0 : 1.0;
   return pips * pip;
}

bool IsNewBarM15()
{
   datetime barTime = iTime(_Symbol, PERIOD_M15, 1);
   if(barTime != lastBarTime)
   {
      lastBarTime = barTime;
      return true;
   }
   return false;
}

bool SessionAllowed(datetime time)
{
   MqlDateTime tm;
   TimeToStruct(time, tm);
   int nowMinutes = tm.hour * 60 + tm.min;
   int startMinutes = InpSessionStartHour * 60 + InpSessionStartMinute;
   int endMinutes = InpSessionEndHour * 60 + InpSessionEndMinute;
   if(startMinutes == endMinutes)
      return true;
   if(startMinutes < endMinutes)
      return (nowMinutes >= startMinutes && nowMinutes < endMinutes);
   return (nowMinutes >= startMinutes || nowMinutes < endMinutes);
}

double NormalizeLots(double lots)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      return 0.0;
   double clipped = MathMax(minLot, MathMin(lots, maxLot));
   double steps = MathFloor(clipped / step);
   double normalized = steps * step;
   if(normalized < minLot)
      return 0.0;
   return normalized;
}

bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) <= 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         return true;
   }
   return false;
}

double GetIndicatorValue(int handle, int shift, bool &ok)
{
   double buffer[];
   if(CopyBuffer(handle, 0, shift, 1, buffer) != 1)
   {
      ok = false;
      return 0.0;
   }
   ok = true;
   return buffer[0];
}

double CalculateER(int period, bool &ok)
{
   int total = period + 2;
   double closes[];
   if(CopyClose(_Symbol, PERIOD_M15, 1, total, closes) != total)
   {
      ok = false;
      return 0.0;
   }
   double change = MathAbs(closes[0] - closes[period]);
   double volatility = 0.0;
   for(int i = 1; i <= period; i++)
      volatility += MathAbs(closes[i - 1] - closes[i]);
   if(volatility <= 0.0)
   {
      ok = false;
      return 0.0;
   }
   ok = true;
   return change / volatility;
}

ModeState UpdateMode(double er)
{
   if(currentMode == MODE_TREND)
   {
      if(er <= InpERRangeExit)
         return MODE_RANGE;
      if(er >= InpERTrendHold)
         return MODE_TREND;
      return currentMode;
   }
   if(er >= InpERTrendEnter)
      return MODE_TREND;
   if(er <= InpERRangeExit)
      return MODE_RANGE;
   return currentMode;
}

TrendDir TrendGate(bool &ok)
{
   bool emaOk = true;
   double ema200 = GetIndicatorValue(handleEma200H1, 1, emaOk);
   double h1Close;
   double closeBuf[];
   if(CopyClose(_Symbol, PERIOD_H1, 1, 1, closeBuf) != 1)
   {
      ok = false;
      return TREND_OFF;
   }
   h1Close = closeBuf[0];
   if(!emaOk)
   {
      ok = false;
      return TREND_OFF;
   }
   ok = true;
   if(h1Close > ema200)
      return TREND_LONG;
   if(h1Close < ema200)
      return TREND_SHORT;
   return TREND_OFF;
}

bool CooldownOK(datetime currentBarTime)
{
   if(lastEntryBarTime == 0)
      return true;
   int barsSince = iBarShift(_Symbol, PERIOD_M15, lastEntryBarTime, true);
   if(barsSince < 0)
      return true;
   return (barsSince >= InpCooldownBars);
}

bool SameZoneOK(double price)
{
   if(lastEntryPrice == 0.0)
      return true;
   double distancePoints = MathAbs(price - lastEntryPrice) / _Point;
   return (distancePoints >= InpSameZonePoints);
}

bool ValidateStops(double entryPrice, double sl, double tp)
{
   int stops = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   int freeze = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double minDistance = (double)MathMax(stops, freeze) * _Point;
   if(minDistance <= 0.0)
      return true;
   if(MathAbs(entryPrice - sl) < minDistance)
      return false;
   if(MathAbs(entryPrice - tp) < minDistance)
      return false;
   return true;
}

void TrackSkip(SkipReason reason)
{
   int idx = (int)reason;
   if(idx >= 0 && idx < ArraySize(skipCounts))
      skipCounts[idx]++;
}

void LogSkipSummary()
{
   if(!InpDebug)
      return;
   PrintFormat("Skip summary: spread=%ld time=%ld cooldown=%ld samezone=%ld range=%ld trend_off=%ld align=%ld slope=%ld distance=%ld momentum=%ld invalid_handle=%ld no_signal=%ld trade_disabled=%ld position_exists=%ld order_fail=%ld lot_invalid=%ld stop_level=%ld",
               skipCounts[SKIP_SPREAD],
               skipCounts[SKIP_TIME],
               skipCounts[SKIP_COOLDOWN],
               skipCounts[SKIP_SAMEZONE],
               skipCounts[SKIP_RANGE],
               skipCounts[SKIP_TREND_OFF],
               skipCounts[SKIP_ALIGN],
               skipCounts[SKIP_SLOPE],
               skipCounts[SKIP_DISTANCE],
               skipCounts[SKIP_MOMENTUM],
               skipCounts[SKIP_INVALID_HANDLE],
               skipCounts[SKIP_NO_SIGNAL],
               skipCounts[SKIP_TRADE_DISABLED],
               skipCounts[SKIP_POSITION_EXISTS],
               skipCounts[SKIP_ORDER_FAIL],
               skipCounts[SKIP_LOT_INVALID],
               skipCounts[SKIP_STOPLEVEL]);
}

void LogSkipSummaryIfNeeded()
{
   if(!InpDebug || InpSummaryEveryBars <= 0)
      return;
   if(barsProcessed % InpSummaryEveryBars != 0)
      return;
   LogSkipSummary();
}

string SkipReasonText(SkipReason reason)
{
   switch(reason)
   {
      case SKIP_SPREAD: return "SpreadTooHigh";
      case SKIP_TIME: return "TimeBlocked";
      case SKIP_COOLDOWN: return "Cooldown";
      case SKIP_SAMEZONE: return "SameZone";
      case SKIP_RANGE: return "RangeBlock";
      case SKIP_TREND_OFF: return "TrendGateOff";
      case SKIP_ALIGN: return "AlignFail";
      case SKIP_SLOPE: return "SlopeFail";
      case SKIP_DISTANCE: return "DistanceFail";
      case SKIP_MOMENTUM: return "MomentumFail";
      case SKIP_INVALID_HANDLE: return "InvalidHandle";
      case SKIP_NO_SIGNAL: return "NoSignal";
      case SKIP_TRADE_DISABLED: return "TradeDisabled";
      case SKIP_POSITION_EXISTS: return "PositionExists";
      case SKIP_ORDER_FAIL: return "OrderFail";
      case SKIP_LOT_INVALID: return "LotInvalid";
      case SKIP_STOPLEVEL: return "StopLevel";
      default: return "None";
   }
}

bool PrepareEntry(bool isLong, double ema21, double ema50)
{
   double close1 = iClose(_Symbol, PERIOD_M15, 1);
   double close2 = iClose(_Symbol, PERIOD_M15, 2);
   if(isLong)
      return (close2 < ema21 || close2 < ema50) && close1 > ema21;
   return (close2 > ema21 || close2 > ema50) && close1 < ema21;
}

bool MASlopeOK(bool isLong, double current, double past)
{
   if(isLong)
      return current > past;
   return current < past;
}

bool AlignmentOK(bool isLong, double ema21, double ema50)
{
   if(isLong)
      return ema21 > ema50;
   return ema21 < ema50;
}

bool DistanceOK(double price, double ema50, double atr)
{
   if(atr <= 0.0)
      return false;
   double distance = MathAbs(price - ema50);
   return (distance >= atr * InpATRMinDistMult && distance <= atr * InpATRMaxDistMult);
}

bool MomentumOK(bool isLong)
{
   double highest = -DBL_MAX;
   double lowest = DBL_MAX;
   for(int i = 1; i <= InpMomentumLookback; i++)
   {
      highest = MathMax(highest, iHigh(_Symbol, PERIOD_M15, i));
      lowest = MathMin(lowest, iLow(_Symbol, PERIOD_M15, i));
   }
   double close1 = iClose(_Symbol, PERIOD_M15, 1);
   if(isLong)
      return close1 > highest;
   return close1 < lowest;
}

void UpdateTP1Tracking()
{
   if(!HasOpenPosition())
   {
      tp1Done = false;
      tp1Price = 0.0;
      tp2Price = 0.0;
      return;
   }
   if(tp1Done)
      return;
   if(PositionSelect(_Symbol))
   {
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         return;
      long type = PositionGetInteger(POSITION_TYPE);
      double price = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      bool hit = (type == POSITION_TYPE_BUY) ? (price >= tp1Price) : (price <= tp1Price);
      if(hit)
      {
         double volume = PositionGetDouble(POSITION_VOLUME);
         double closeVol = volume * (InpTP1ClosePercent / 100.0);
         closeVol = NormalizeLots(closeVol);
         if(closeVol > 0.0)
         {
            trade.PositionClosePartial(_Symbol, closeVol);
            if((int)trade.ResultRetcode() != TRADE_RETCODE_DONE)
               PrintFormat("TP1 close failed retcode=%d lastError=%d", trade.ResultRetcode(), GetLastError());
         }
         if(InpUseBreakeven)
         {
            double entry = PositionGetDouble(POSITION_PRICE_OPEN);
            double sl = PositionGetDouble(POSITION_SL);
            double offset = InpBreakevenOffsetPts * _Point;
            double newSl = (type == POSITION_TYPE_BUY) ? (entry + offset) : (entry - offset);
            bool improve = (type == POSITION_TYPE_BUY) ? (newSl > sl) : (newSl < sl);
            if(improve)
            {
               trade.PositionModify(_Symbol, newSl, PositionGetDouble(POSITION_TP));
               if((int)trade.ResultRetcode() != TRADE_RETCODE_DONE)
                  PrintFormat("Breakeven modify failed retcode=%d lastError=%d", trade.ResultRetcode(), GetLastError());
            }
         }
         tp1Done = true;
      }
   }
}

void ManageTrailingAfterTP1()
{
   if(!InpUseTrailingAfterTP1 || !tp1Done)
      return;
   if(!PositionSelect(_Symbol))
      return;
   if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
      return;
   bool atrOk = true;
   double atr = GetIndicatorValue(handleAtrM15, 1, atrOk);
   if(!atrOk || atr <= 0.0)
      return;
   long type = PositionGetInteger(POSITION_TYPE);
   double currentSl = PositionGetDouble(POSITION_SL);
   double newSl = currentSl;
   if(type == POSITION_TYPE_BUY)
   {
      double candidate = SymbolInfoDouble(_Symbol, SYMBOL_BID) - atr * InpTrailATRMult;
      if(candidate > newSl)
         newSl = candidate;
   }
   else
   {
      double candidate = SymbolInfoDouble(_Symbol, SYMBOL_ASK) + atr * InpTrailATRMult;
      if(newSl == 0.0 || candidate < newSl)
         newSl = candidate;
   }
   if(newSl != currentSl && ValidateStops(PositionGetDouble(POSITION_PRICE_OPEN), newSl, PositionGetDouble(POSITION_TP)))
   {
      trade.PositionModify(_Symbol, newSl, PositionGetDouble(POSITION_TP));
      if((int)trade.ResultRetcode() != TRADE_RETCODE_DONE)
         PrintFormat("Trail modify failed retcode=%d lastError=%d", trade.ResultRetcode(), GetLastError());
   }
}

int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   handleEma200H1 = iMA(_Symbol, PERIOD_H1, InpEMA200Period, 0, MODE_EMA, PRICE_CLOSE);
   handleEma21M15 = iMA(_Symbol, PERIOD_M15, InpEMA21Period, 0, MODE_EMA, PRICE_CLOSE);
   handleEma50M15 = iMA(_Symbol, PERIOD_M15, InpEMA50Period, 0, MODE_EMA, PRICE_CLOSE);
   handleAtrM15 = iATR(_Symbol, PERIOD_M15, InpATRPeriod);
   if(handleEma200H1 == INVALID_HANDLE || handleEma21M15 == INVALID_HANDLE || handleEma50M15 == INVALID_HANDLE || handleAtrM15 == INVALID_HANDLE)
   {
      Print("Invalid indicator handle.");
      return INIT_FAILED;
   }
   ArrayInitialize(skipCounts, 0);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(handleEma200H1 != INVALID_HANDLE)
      IndicatorRelease(handleEma200H1);
   if(handleEma21M15 != INVALID_HANDLE)
      IndicatorRelease(handleEma21M15);
   if(handleEma50M15 != INVALID_HANDLE)
      IndicatorRelease(handleEma50M15);
   if(handleAtrM15 != INVALID_HANDLE)
      IndicatorRelease(handleAtrM15);
   LogSkipSummary();
}

void OnTick()
{
   UpdateTP1Tracking();
   ManageTrailingAfterTP1();
   if(!IsNewBarM15())
      return;
   barsProcessed++;
   LogSkipSummaryIfNeeded();

   datetime barTime = iTime(_Symbol, PERIOD_M15, 1);
   SkipReason skip = SKIP_NONE;
   string entryFlags = "";
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spreadPoints = (ask - bid) / _Point;

   if(spreadPoints > InpMaxSpreadPoints)
      skip = SKIP_SPREAD;
   else if(!SessionAllowed(TimeCurrent()))
      skip = SKIP_TIME;
   else if(!CooldownOK(barTime))
      skip = SKIP_COOLDOWN;

   bool erOk = true;
   double er = CalculateER(InpERLen, erOk);
   if(!erOk)
      skip = SKIP_INVALID_HANDLE;
   currentMode = UpdateMode(er);
   if(skip == SKIP_NONE && currentMode == MODE_RANGE)
      skip = SKIP_RANGE;

   bool trendOk = true;
   TrendDir trendDir = TrendGate(trendOk);
   if(skip == SKIP_NONE && !trendOk)
      skip = SKIP_INVALID_HANDLE;
   if(skip == SKIP_NONE && trendDir == TREND_OFF)
      skip = SKIP_TREND_OFF;

   bool ema21Ok = true;
   bool ema50Ok = true;
   double ema21 = GetIndicatorValue(handleEma21M15, 1, ema21Ok);
   double ema50 = GetIndicatorValue(handleEma50M15, 1, ema50Ok);
   bool ema50PastOk = true;
   double ema50Past = GetIndicatorValue(handleEma50M15, 1 + InpMASlopeLookback, ema50PastOk);
   bool atrOk = true;
   double atr = GetIndicatorValue(handleAtrM15, 1, atrOk);
   if((!ema21Ok || !ema50Ok || !atrOk || !ema50PastOk) && skip == SKIP_NONE)
      skip = SKIP_INVALID_HANDLE;

   bool signal = false;
   bool isLong = (trendDir == TREND_LONG);
   if(skip == SKIP_NONE && !HasOpenPosition())
   {
      signal = PrepareEntry(isLong, ema21, ema50);
      entryFlags = signal ? "Pullback" : "";
      if(!signal)
         skip = SKIP_NO_SIGNAL;
      if(skip == SKIP_NONE && signal && InpUseAlignmentFilter && !AlignmentOK(isLong, ema21, ema50))
         skip = SKIP_ALIGN;
      if(skip == SKIP_NONE && signal && InpUseSlopeFilter && !MASlopeOK(isLong, ema50, ema50Past))
         skip = SKIP_SLOPE;
      if(skip == SKIP_NONE && signal && InpUseDistanceFilter && !DistanceOK(isLong ? ask : bid, ema50, atr))
         skip = SKIP_DISTANCE;
      if(skip == SKIP_NONE && signal && InpUseMomentumFilter && !MomentumOK(isLong))
         skip = SKIP_MOMENTUM;
      if(skip == SKIP_NONE && signal && !SameZoneOK(isLong ? ask : bid))
         skip = SKIP_SAMEZONE;
   }
   else if(skip == SKIP_NONE && HasOpenPosition())
   {
      skip = SKIP_POSITION_EXISTS;
   }

   if(skip == SKIP_NONE)
   {
      double entryPrice = isLong ? ask : bid;
      double sl = isLong ? (entryPrice - atr * InpSLATRMult) : (entryPrice + atr * InpSLATRMult);
      double risk = MathAbs(entryPrice - sl);
      double tp1 = isLong ? (entryPrice + risk * InpTP1RR) : (entryPrice - risk * InpTP1RR);
      double tp2 = isLong ? (entryPrice + risk * InpTP2RR) : (entryPrice - risk * InpTP2RR);

      if(!ValidateStops(entryPrice, sl, tp2))
      {
         skip = SKIP_STOPLEVEL;
      }
      else
      {
         double lot = NormalizeLots(InpLots);
         if(lot <= 0.0)
         {
            skip = SKIP_LOT_INVALID;
         }
         else if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
         {
            skip = SKIP_TRADE_DISABLED;
         }
         else
         {
            trade.SetExpertMagicNumber(InpMagicNumber);
            bool result = false;
            if(isLong)
               result = trade.Buy(lot, _Symbol, entryPrice, sl, tp2, "EA");
            else
               result = trade.Sell(lot, _Symbol, entryPrice, sl, tp2, "EA");
            if(!result || (int)trade.ResultRetcode() != TRADE_RETCODE_DONE)
            {
               PrintFormat("Order failed retcode=%d lastError=%d", trade.ResultRetcode(), GetLastError());
               skip = SKIP_ORDER_FAIL;
            }
            else
            {
               lastEntryPrice = entryPrice;
               lastEntryBarTime = barTime;
               tp1Price = tp1;
               tp2Price = tp2;
               tp1Done = false;
            }
         }
      }
   }

   TrackSkip(skip);

   if(InpDebug)
   {
      PrintFormat("%s,mode=%s,ER=%.3f,spread=%.1f,timeOK=%d,cooldown=%d,trend=%d,entry=%s,skip=%s",
                  TimeToString(barTime, TIME_DATE|TIME_MINUTES),
                  currentMode == MODE_TREND ? "Trend" : "Range",
                  er,
                  spreadPoints,
                  SessionAllowed(TimeCurrent()) ? 1 : 0,
                  CooldownOK(barTime) ? 1 : 0,
                  (int)trendDir,
                  entryFlags,
                  SkipReasonText(skip));
   }
}

void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
{
   if(!InpDebug)
      return;
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   ulong dealTicket = trans.deal;
   if(dealTicket == 0)
      return;
   datetime endTime = TimeCurrent();
   if(!HistorySelect(endTime - 86400, endTime))
      return;
   long entryType = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
   string symbol = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
   if(symbol != _Symbol)
      return;
   double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
   PrintFormat("Deal: entry=%d profit=%.2f", (int)entryType, profit);
}
