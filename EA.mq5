//+------------------------------------------------------------------+
//|                                                    EA.mq5        |
//|                                        Auto FX Trading Tool     |
//+------------------------------------------------------------------+
#property copyright ""
#property version   "1.31"
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
input double InpSLATRMult          = 0.9;
input bool   InpUseFixedPips       = true;
input int    InpFixedPipSetTrend   = 0; // 0=A 1=B 2=C
input double InpRangeSLPips        = 10.0;
input double InpRangeTPPips        = 10.0;
input bool   InpAllowRangeEntries  = true;
input double InpMaxSpreadPips      = 1.5;
input bool   InpUseSpreadPipsFilter = true;
input double InpATRMinSLMult       = 0.6;
input double InpATRMaxSLMult       = 1.2;
input bool   InpUseATRRangeFilter  = true;
input double InpTP1FixedPercent   = 50.0;
input double InpTP1RR              = 1.2;
input double InpTP2RR              = 2.8;
input double InpTP1ClosePercent    = 25.0;
input bool   InpUseTP1             = true;
input bool   InpUseModeRR          = true;
input double InpTP1RRTrend         = 1.0;
input double InpTP2RRTrend         = 2.0;
input double InpTP1RRRange         = 0.8;
input double InpTP2RRRange         = 1.4;
input double InpTP1ClosePercentTrend = 35.0;
input double InpTP1ClosePercentRange = 60.0;
input bool   InpExitTPOnly         = true;
input bool   InpUseBreakeven       = false;
input int    InpBreakevenOffsetPts = 0;
input bool   InpUseTrailingAfterTP1 = false;
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
   SKIP_ATR_RANGE,
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
double tp1ClosePercentCurrent = 25.0;
ModeState currentMode = MODE_RANGE;
long barsProcessed = 0;

long skipCounts[19];

double PipsToPoints(double pips)
{
   double pip = (_Digits == 3 || _Digits == 5) ? 10.0 : 1.0;
   return pips * pip;
}

double PointsToPips(double points)
{
   double pip = (_Digits == 3 || _Digits == 5) ? 10.0 : 1.0;
   return points / pip;
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

double EffectiveRR(double tp1RR, double tp2RR, double tp1ClosePercent)
{
   double w1 = MathMax(0.0, MathMin(tp1ClosePercent, 100.0)) / 100.0;
   double w2 = 1.0 - w1;
   return tp1RR * w1 + tp2RR * w2;
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

bool GetFixedPipSet(int setId, double &slPips, double &tpPips)
{
   switch(setId)
   {
      case 0:
         slPips = 16.0;
         tpPips = 28.0;
         return true;
      case 1:
         slPips = 20.0;
         tpPips = 32.0;
         return true;
      case 2:
         slPips = 12.0;
         tpPips = 24.0;
         return true;
      default:
         return false;
   }
}

bool GetModeFixedPips(ModeState mode, double &slPips, double &tpPips)
{
   if(mode == MODE_RANGE)
   {
      slPips = InpRangeSLPips;
      tpPips = InpRangeTPPips;
      return (slPips > 0.0 && tpPips > 0.0);
   }
   return GetFixedPipSet(InpFixedPipSetTrend, slPips, tpPips);
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
   PrintFormat("Skip summary: spread=%ld time=%ld cooldown=%ld samezone=%ld range=%ld trend_off=%ld atr_range=%ld align=%ld slope=%ld distance=%ld momentum=%ld invalid_handle=%ld no_signal=%ld trade_disabled=%ld position_exists=%ld order_fail=%ld lot_invalid=%ld stop_level=%ld",
               skipCounts[SKIP_SPREAD],
               skipCounts[SKIP_TIME],
               skipCounts[SKIP_COOLDOWN],
               skipCounts[SKIP_SAMEZONE],
               skipCounts[SKIP_RANGE],
               skipCounts[SKIP_TREND_OFF],
               skipCounts[SKIP_ATR_RANGE],
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
      case SKIP_ATR_RANGE: return "ATRRange";
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
   if(InpExitTPOnly)
      return;
   if(!HasOpenPosition())
   {
      tp1Done = false;
      tp1Price = 0.0;
      tp2Price = 0.0;
      tp1ClosePercentCurrent = InpTP1ClosePercent;
      return;
   }
   if(tp1Done)
      return;
   if(tp1ClosePercentCurrent <= 0.0)
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
         double closeVol = volume * (tp1ClosePercentCurrent / 100.0);
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
   if(InpExitTPOnly)
      return;
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
   PrintFormat("Exit mode: TP/SL only=%s", InpExitTPOnly ? "ON" : "OFF");
   if(InpUseModeRR)
   {
      PrintFormat("RR Trend: TP1RR=%.2f TP2RR=%.2f TP1%%=%.1f EffRR=%.2f",
                  InpTP1RRTrend, InpTP2RRTrend, InpTP1ClosePercentTrend,
                  EffectiveRR(InpTP1RRTrend, InpTP2RRTrend, InpTP1ClosePercentTrend));
      PrintFormat("RR Range: TP1RR=%.2f TP2RR=%.2f TP1%%=%.1f EffRR=%.2f",
                  InpTP1RRRange, InpTP2RRRange, InpTP1ClosePercentRange,
                  EffectiveRR(InpTP1RRRange, InpTP2RRRange, InpTP1ClosePercentRange));
   }
   else
   {
      PrintFormat("RR: TP1RR=%.2f TP2RR=%.2f TP1%%=%.1f EffRR=%.2f",
                  InpTP1RR, InpTP2RR, InpTP1ClosePercent,
                  EffectiveRR(InpTP1RR, InpTP2RR, InpTP1ClosePercent));
   }
   if(InpUseFixedPips)
   {
      double slPips = 0.0;
      double tpPips = 0.0;
      if(GetFixedPipSet(InpFixedPipSetTrend, slPips, tpPips))
      {
         PrintFormat("Fixed trend set=%d SL=%.1f TP=%.1f ATR range=%.2f-%.2f",
                     InpFixedPipSetTrend, slPips, tpPips,
                     slPips * InpATRMinSLMult, slPips * InpATRMaxSLMult);
      }
      PrintFormat("Fixed range SL=%.1f TP=%.1f ATR range=%.2f-%.2f allow_range=%s",
                  InpRangeSLPips, InpRangeTPPips,
                  InpRangeSLPips * InpATRMinSLMult, InpRangeSLPips * InpATRMaxSLMult,
                  InpAllowRangeEntries ? "ON" : "OFF");
      PrintFormat("Fixed filters: spread_pips=%s atr_range=%s max_spread=%.2f",
                  InpUseSpreadPipsFilter ? "ON" : "OFF",
                  InpUseATRRangeFilter ? "ON" : "OFF",
                  InpMaxSpreadPips);
      PrintFormat("Fixed TP1 percent=%.1f TP1Close%%=%.1f",
                  MathMax(0.0, MathMin(InpTP1FixedPercent, 100.0)),
                  InpUseTP1 ? InpTP1ClosePercent : 0.0);
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
   if(!InpExitTPOnly)
   {
      UpdateTP1Tracking();
      ManageTrailingAfterTP1();
   }
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
   double spreadPips = PointsToPips(spreadPoints);

   if(spreadPoints > InpMaxSpreadPoints)
      skip = SKIP_SPREAD;
   if(skip == SKIP_NONE && InpUseSpreadPipsFilter && InpMaxSpreadPips > 0.0 && spreadPips > InpMaxSpreadPips)
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
   if(skip == SKIP_NONE && currentMode == MODE_RANGE && !InpAllowRangeEntries)
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

   double fixedSlPips = 0.0;
   double fixedTpPips = 0.0;
   if(skip == SKIP_NONE && InpUseFixedPips)
   {
      if(!GetModeFixedPips(currentMode, fixedSlPips, fixedTpPips))
      {
         skip = SKIP_INVALID_HANDLE;
      }
      else if(InpUseATRRangeFilter)
      {
         double atrPips = PointsToPips(atr / _Point);
         double minAtr = fixedSlPips * InpATRMinSLMult;
         double maxAtr = fixedSlPips * InpATRMaxSLMult;
         if(atrPips < minAtr || atrPips > maxAtr)
            skip = SKIP_ATR_RANGE;
      }
   }

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
      double sl = 0.0;
      double tp2 = 0.0;
      double risk = 0.0;
      double entryCheckSl = 0.0;
      double entryCheckTp = 0.0;
      double pipValue = (_Digits == 3 || _Digits == 5) ? 10.0 * _Point : _Point;
      if(InpUseFixedPips)
      {
         double slDistance = fixedSlPips * pipValue;
         double tpDistance = fixedTpPips * pipValue;
         entryCheckSl = isLong ? (entryPrice - slDistance) : (entryPrice + slDistance);
         entryCheckTp = isLong ? (entryPrice + tpDistance) : (entryPrice - tpDistance);
         sl = entryCheckSl;
         tp2 = entryCheckTp;
         risk = MathAbs(entryPrice - sl);
      }
      else
      {
         sl = isLong ? (entryPrice - atr * InpSLATRMult) : (entryPrice + atr * InpSLATRMult);
         risk = MathAbs(entryPrice - sl);
      }
      double tp1RR = InpTP1RR;
      double tp2RR = InpTP2RR;
      double tp1ClosePercent = InpTP1ClosePercent;
      if(!InpUseFixedPips && InpUseModeRR)
      {
         if(currentMode == MODE_TREND)
         {
            tp1RR = InpTP1RRTrend;
            tp2RR = InpTP2RRTrend;
            tp1ClosePercent = InpTP1ClosePercentTrend;
         }
         else
         {
            tp1RR = InpTP1RRRange;
            tp2RR = InpTP2RRRange;
            tp1ClosePercent = InpTP1ClosePercentRange;
         }
      }
      if(!InpUseTP1)
         tp1ClosePercent = 0.0;
      double tp1 = 0.0;
      if(InpUseFixedPips)
      {
         double tp1Pct = MathMax(0.0, MathMin(InpTP1FixedPercent, 100.0));
         if(tp1ClosePercent <= 0.0)
            tp1Pct = 0.0;
         double tp1Points = PipsToPoints(fixedTpPips) * (tp1Pct / 100.0);
         if(tp1Points > 0.0)
            tp1 = isLong ? (entryPrice + tp1Points * _Point) : (entryPrice - tp1Points * _Point);
      }
      else
      {
         tp1 = isLong ? (entryPrice + risk * tp1RR) : (entryPrice - risk * tp1RR);
         tp2 = isLong ? (entryPrice + risk * tp2RR) : (entryPrice - risk * tp2RR);
      }

      if(InpUseFixedPips && !ValidateStops(entryPrice, entryCheckSl, entryCheckTp))
      {
         skip = SKIP_STOPLEVEL;
      }
      else if(!ValidateStops(entryPrice, sl, tp2))
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
            if(InpUseFixedPips)
            {
               if(isLong)
                  result = trade.Buy(lot, _Symbol, 0.0, 0.0, 0.0, "EA");
               else
                  result = trade.Sell(lot, _Symbol, 0.0, 0.0, 0.0, "EA");
            }
            else
            {
               if(isLong)
                  result = trade.Buy(lot, _Symbol, entryPrice, sl, tp2, "EA");
               else
                  result = trade.Sell(lot, _Symbol, entryPrice, sl, tp2, "EA");
            }
            if(!result || (int)trade.ResultRetcode() != TRADE_RETCODE_DONE)
            {
               PrintFormat("Order failed retcode=%d lastError=%d", trade.ResultRetcode(), GetLastError());
               skip = SKIP_ORDER_FAIL;
            }
            else
            {
               if(!InpUseFixedPips)
               {
                  lastEntryPrice = entryPrice;
                  lastEntryBarTime = barTime;
                  tp1Price = tp1;
                  tp2Price = tp2;
                  tp1Done = false;
                  tp1ClosePercentCurrent = tp1ClosePercent;
               }
               else
               {
                  double fillPrice = trade.ResultPrice();
                  if(fillPrice <= 0.0 && PositionSelect(_Symbol))
                     fillPrice = PositionGetDouble(POSITION_PRICE_OPEN);
                  if(fillPrice <= 0.0)
                  {
                     Print("Fill price unavailable, closing position for safety.");
                     trade.PositionClose(_Symbol);
                     skip = SKIP_ORDER_FAIL;
                  }
                  else
                  {
                     double slDistance = fixedSlPips * pipValue;
                     double tpDistance = fixedTpPips * pipValue;
                     double modifySl = isLong ? (fillPrice - slDistance) : (fillPrice + slDistance);
                     double modifyTp = isLong ? (fillPrice + tpDistance) : (fillPrice - tpDistance);
                     modifySl = NormalizeDouble(modifySl, _Digits);
                     modifyTp = NormalizeDouble(modifyTp, _Digits);
                     if(!ValidateStops(fillPrice, modifySl, modifyTp))
                     {
                        Print("Modify stops invalid after fill, closing position.");
                        trade.PositionClose(_Symbol);
                        skip = SKIP_STOPLEVEL;
                     }
                     else
                     {
                        trade.PositionModify(_Symbol, modifySl, modifyTp);
                        if((int)trade.ResultRetcode() != TRADE_RETCODE_DONE)
                        {
                           PrintFormat("Modify failed retcode=%d lastError=%d; closing position.", trade.ResultRetcode(), GetLastError());
                           trade.PositionClose(_Symbol);
                           skip = SKIP_ORDER_FAIL;
                        }
                        else
                        {
                           double actualSLPips = MathAbs(fillPrice - modifySl) / pipValue;
                           double actualTPPips = MathAbs(fillPrice - modifyTp) / pipValue;
                           double atrPips = PointsToPips(atr / _Point);
                           string modeText = currentMode == MODE_TREND ? "Trend" : "Range";
                           string setText = currentMode == MODE_TREND
                              ? (InpFixedPipSetTrend == 0 ? "A" : (InpFixedPipSetTrend == 1 ? "B" : "C"))
                              : "Range";
                           PrintFormat("ENTRY %s %s %s fill=%.5f sl=%.1f tp=%.1f actualSLpips=%.1f actualTPpips=%.1f spread=%.2f atr=%.2f",
                                       modeText,
                                       setText,
                                       isLong ? "BUY" : "SELL",
                                       fillPrice,
                                       fixedSlPips,
                                       fixedTpPips,
                                       actualSLPips,
                                       actualTPPips,
                                       spreadPips,
                                       atrPips);
                           lastEntryPrice = fillPrice;
                           lastEntryBarTime = barTime;
                           tp1Price = tp1;
                           tp2Price = modifyTp;
                           tp1Done = false;
                           tp1ClosePercentCurrent = tp1ClosePercent;
                        }
                     }
                  }
               }
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
