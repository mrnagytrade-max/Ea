//+------------------------------------------------------------------------+
//|                                          Arbah_Sniper_V1_EA.mq5        |
//|                                              Arbah Markets             |
//|  Auto-trading port of the "Arbah Sniper V1" TradingView indicator.     |
//|  Same engine, two pillars only:                                        |
//|    1) Market Structure + CHoCH (Change of Character)                   |
//|    2) The Order Block that caused the CHoCH break, as the only entry   |
//|       zone - a real order is sent the moment price returns to tag it.  |
//|                                                                        |
//|  On every new bar the EA replays the full algorithm over recent        |
//|  history (closed bars only - the currently forming bar is never used,  |
//|  which is a deliberate safety choice for live trading and differs      |
//|  slightly from the indicator's own live/repainting chart behaviour).   |
//|  That replay tells it, as of the last closed bar: is there an active   |
//|  Order Block, what is the structure trend, and did a CHoCH / entry     |
//|  condition just fire. It then manages one real position per symbol:    |
//|  it closes early on an opposing CHoCH, and opens a new position with   |
//|  broker-native SL/TP when an entry condition fires and nothing is      |
//|  currently open.                                                       |
//+------------------------------------------------------------------------+
#property copyright "Arbah Markets"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

//====================== INPUTS ==============================================
input group "Structure & CHoCH"
input int    InpStructSwingLen   = 4;       // Swing length for structure/CHoCH

input group "Order Blocks"
input int    InpObLookback       = 15;      // Max candles back to find the OB candle
input int    InpObMaxAge         = 40;      // Max Order Block age (bars) before cancellation
input double InpObBufferAtr      = 0.15;    // SL buffer beyond OB edge (x ATR)
input double InpMaxStopAtrMult   = 3.0;     // Max accepted stop distance (x ATR)

input group "Risk Management"
input int    InpAtrPeriod        = 14;      // ATR period
input double InpRR               = 1.5;     // Reward:Risk ratio
input bool   InpUseRatioLotSizing = true;   // true = fixed $->lot ratio (matches dashboard), false = % risk based
input double InpLotCapitalUnit   = 100.0;   // $ per lot unit (ratio mode) -> "100$ - 0.01 Lot"
input double InpLotPerUnit       = 0.01;    // Lot size per capital unit (ratio mode)
input double InpRiskPercent      = 1.0;     // Risk % of balance (used only if ratio mode = false)

input group "Trade Settings"
input ulong  InpMagic            = 20260721;// EA magic number
input int    InpSlippage         = 10;      // Max slippage, points
input bool   InpAllowLong        = true;    // Allow BUY signals
input bool   InpAllowShort       = true;    // Allow SELL signals
input int    InpMaxSpreadPoints  = 0;       // Skip new entries if spread > this (0 = disabled)
input int    InpHistoryBars      = 1000;    // Closed bars replayed on every new bar

//====================== GLOBALS ==============================================
CTrade   trade;
datetime g_lastBarTime = 0;
int      g_atrHandle   = INVALID_HANDLE;

//====================== INIT / DEINIT =========================================
int OnInit()
{
   g_atrHandle = iATR(_Symbol, _Period, InpAtrPeriod);
   if(g_atrHandle == INVALID_HANDLE)
   {
      Print("Arbah Sniper V1 EA: failed to create ATR handle");
      return(INIT_FAILED);
   }
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
}

//====================== MAIN TICK =============================================
void OnTick()
{
   datetime t0 = iTime(_Symbol, _Period, 0);
   if(t0 == g_lastBarTime)
      return; // only act once per closed bar
   g_lastBarTime = t0;

   ProcessNewBar();
}

//====================== PIVOT HELPERS =========================================
// Approximates Pine's ta.pivothigh/pivotlow(len,len): true if rates[p] is the
// highest/lowest value in the [p-len, p+len] window.
bool IsPivotHigh(int p, int len, const MqlRates &rates[], int count)
{
   if(p - len < 0 || p + len >= count)
      return false;
   double v = rates[p].high;
   for(int k = p - len; k <= p + len; k++)
      if(rates[k].high > v)
         return false;
   return true;
}

bool IsPivotLow(int p, int len, const MqlRates &rates[], int count)
{
   if(p - len < 0 || p + len >= count)
      return false;
   double v = rates[p].low;
   for(int k = p - len; k <= p + len; k++)
      if(rates[k].low < v)
         return false;
   return true;
}

// Finds the offset (1..lookback) of the last opposite-colored candle before
// bar i. bearish=true looks for a bearish candle (bull Order Block source),
// bearish=false looks for a bullish candle (bear Order Block source).
int FindLastOppositeIdx(bool bearish, int i, int lookback, const MqlRates &rates[])
{
   for(int k = 1; k <= lookback && (i - k) >= 0; k++)
   {
      bool cond = bearish ? (rates[i-k].close < rates[i-k].open)
                           : (rates[i-k].close > rates[i-k].open);
      if(cond)
         return k;
   }
   return -1;
}

//====================== REPLAY + SIGNAL EXTRACTION ============================
void ProcessNewBar()
{
   MqlRates rates[];
   ArraySetAsSeries(rates, false);
   int copied = CopyRates(_Symbol, _Period, 1, InpHistoryBars, rates); // closed bars only
   if(copied < 2 * InpStructSwingLen + 5)
      return; // not enough history yet

   double atrBuf[];
   ArraySetAsSeries(atrBuf, false);
   if(CopyBuffer(g_atrHandle, 0, 1, copied, atrBuf) < copied)
      return;

   double lastSwingHigh = 0.0, lastSwingLow = 0.0;
   bool   haveSwingHigh = false, haveSwingLow = false;
   int    structTrend = 0;

   double obTopBull = 0.0, obBotBull = 0.0; int obBarBull = -1; bool obActiveBull = false;
   double obTopBear = 0.0, obBotBear = 0.0; int obBarBear = -1; bool obActiveBear = false;

   bool   finalChochUp = false, finalChochDown = false;
   bool   finalLongCond = false, finalShortCond = false;
   double finalStopLong = 0.0, finalTargetLong = 0.0;
   double finalStopShort = 0.0, finalTargetShort = 0.0;

   int S = InpStructSwingLen;

   for(int i = 0; i < copied; i++)
   {
      double h = rates[i].high, l = rates[i].low, c = rates[i].close;
      double atr = atrBuf[i];

      bool   oldHaveHigh = haveSwingHigh; double oldSwingHigh = lastSwingHigh;
      bool   oldHaveLow  = haveSwingLow;  double oldSwingLow  = lastSwingLow;

      // ---- structure pivots (confirmed S bars after the pivot bar) ----
      if(i >= 2 * S)
      {
         int p = i - S;
         if(IsPivotHigh(p, S, rates, copied)) { lastSwingHigh = rates[p].high; haveSwingHigh = true; }
         if(IsPivotLow(p, S, rates, copied))  { lastSwingLow  = rates[p].low;  haveSwingLow  = true; }
      }

      // ---- structure break (crossover/crossunder against the PREVIOUS swing value) ----
      bool bosUp   = haveSwingHigh && oldHaveHigh && i >= 1 && c > lastSwingHigh && rates[i-1].close <= oldSwingHigh;
      bool bosDown = haveSwingLow  && oldHaveLow  && i >= 1 && c < lastSwingLow  && rates[i-1].close >= oldSwingLow;

      // ---- CHoCH: break against the structure trend BEFORE it updates this bar ----
      bool chochUp   = bosUp   && structTrend <= 0;
      bool chochDown = bosDown && structTrend >= 0;

      if(bosUp)   structTrend = 1;
      if(bosDown) structTrend = -1;

      // ---- Order Blocks: created only off a CHoCH; opposite OB invalidated ----
      if(chochUp)
      {
         if(obActiveBear) obActiveBear = false;
         int idx = FindLastOppositeIdx(true, i, InpObLookback, rates);
         if(idx >= 0)
         {
            obTopBull = rates[i-idx].high;
            obBotBull = rates[i-idx].low;
            obBarBull = i - idx;
            obActiveBull = true;
         }
      }
      if(chochDown)
      {
         if(obActiveBull) obActiveBull = false;
         int idx = FindLastOppositeIdx(false, i, InpObLookback, rates);
         if(idx >= 0)
         {
            obTopBear = rates[i-idx].high;
            obBotBear = rates[i-idx].low;
            obBarBear = i - idx;
            obActiveBear = true;
         }
      }

      // ---- mitigation / age cleanup ----
      if(obActiveBull && (c < obBotBull || (i - obBarBull) > InpObMaxAge)) obActiveBull = false;
      if(obActiveBear && (c > obTopBear || (i - obBarBear) > InpObMaxAge)) obActiveBear = false;

      // ---- entry candidates ----
      double candStopLong  = obBotBull - atr * InpObBufferAtr;
      double candStopShort = obTopBear + atr * InpObBufferAtr;

      bool touchBullOB = obActiveBull && l <= obTopBull && h >= obBotBull;
      bool touchBearOB = obActiveBear && h >= obBotBear && l <= obTopBear;

      bool longCond  = touchBullOB && structTrend >= 0 && (c - candStopLong)  > 0 && (c - candStopLong)  <= atr * InpMaxStopAtrMult;
      bool shortCond = touchBearOB && structTrend <= 0 && (candStopShort - c) > 0 && (candStopShort - c) <= atr * InpMaxStopAtrMult;

      if(i == copied - 1) // last fully closed bar -> the "live" signal
      {
         finalChochUp   = chochUp;
         finalChochDown = chochDown;
         finalLongCond  = longCond;
         finalShortCond = shortCond;
         finalStopLong   = candStopLong;
         finalTargetLong  = c + (c - candStopLong) * InpRR;
         finalStopShort  = candStopShort;
         finalTargetShort = c - (candStopShort - c) * InpRR;
      }
   }

   ManageTrades(finalChochUp, finalChochDown, finalLongCond, finalShortCond,
                finalStopLong, finalTargetLong, finalStopShort, finalTargetShort);
}

//====================== POSITION HELPERS ======================================
bool GetMyPosition(ulong &ticket, long &type)
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      ticket = tk;
      type   = PositionGetInteger(POSITION_TYPE);
      return true;
   }
   return false;
}

double NormalizeLot(double lots)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(stepLot <= 0) stepLot = 0.01;
   lots = MathFloor(lots / stepLot) * stepLot;
   lots = MathMax(minLot, MathMin(maxLot, lots));
   return lots;
}

double CalcLotSize(double stopDistance)
{
   double lots = 0.0;
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);

   if(InpUseRatioLotSizing)
   {
      // Mirrors the indicator's dashboard rule, e.g. "100$ -> 0.01 Lot"
      if(InpLotCapitalUnit > 0)
         lots = (balance / InpLotCapitalUnit) * InpLotPerUnit;
   }
   else
   {
      double riskAmount   = balance * InpRiskPercent / 100.0;
      double tickValue    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize     = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double valuePerPoint = (tickSize > 0) ? tickValue / tickSize : 0.0;
      double stopValue = stopDistance * valuePerPoint;
      if(stopValue > 0)
         lots = riskAmount / stopValue;
   }
   return NormalizeLot(lots);
}

bool SpreadOk()
{
   if(InpMaxSpreadPoints <= 0) return true;
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return spread <= InpMaxSpreadPoints;
}

void OpenTrade(bool isLong, double sl, double tp)
{
   if(!SpreadOk())
   {
      Print("Arbah Sniper V1 EA: skipped entry, spread too wide");
      return;
   }

   double price = isLong ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double lots  = CalcLotSize(MathAbs(price - sl));
   if(lots <= 0)
   {
      Print("Arbah Sniper V1 EA: skipped entry, computed lot size is 0");
      return;
   }

   price = NormalizeDouble(price, _Digits);
   sl    = NormalizeDouble(sl, _Digits);
   tp    = NormalizeDouble(tp, _Digits);

   bool ok = isLong ? trade.Buy(lots, _Symbol, price, sl, tp, "Arbah Sniper V1")
                     : trade.Sell(lots, _Symbol, price, sl, tp, "Arbah Sniper V1");
   if(!ok)
      PrintFormat("Arbah Sniper V1 EA: order failed, retcode=%d (%s)", trade.ResultRetcode(), trade.ResultRetcodeDescription());
}

//====================== TRADE MANAGEMENT ======================================
void ManageTrades(bool chochUp, bool chochDown, bool longCond, bool shortCond,
                   double stopLong, double targetLong, double stopShort, double targetShort)
{
   ulong ticket = 0; long posType = -1;
   bool hasPos = GetMyPosition(ticket, posType);

   // Close early on an opposing CHoCH (SL/TP hits are already handled by the broker)
   if(hasPos)
   {
      if((posType == POSITION_TYPE_BUY && chochDown) || (posType == POSITION_TYPE_SELL && chochUp))
      {
         trade.PositionClose(ticket);
         hasPos = false;
      }
   }

   if(!hasPos)
   {
      if(longCond && InpAllowLong)
         OpenTrade(true, stopLong, targetLong);
      else if(shortCond && InpAllowShort)
         OpenTrade(false, stopShort, targetShort);
   }
}
//+------------------------------------------------------------------------+
