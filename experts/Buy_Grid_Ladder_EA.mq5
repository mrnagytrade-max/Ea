//+------------------------------------------------------------------+
//|                                        Buy_Grid_Ladder_EA.mq5    |
//|                                   شبكة أوامر معلقة Buy Limit /   |
//|                                   Buy Stop حوالين السعر الحالي   |
//+------------------------------------------------------------------+
#property copyright "Arbah Markets"
#property version   "1.00"
#property strict
#property description "يفتح شبكة من Buy Stop فوق السعر و Buy Limit تحت السعر، بمسافة ثابتة"
#property description "بين كل أمر والتاني، وهدف ربح ثابت لكل أمر. أي أمر يقفل على هدفه بيتم"
#property description "استبداله فورًا بأمر جديد بنفس المسافة من السعر الحالي (شبكة ذاتية التجديد)."

#include <Trade/Trade.mqh>

//====================================================================
// إعدادات الشبكة (Grid Settings)
//====================================================================
input group "=== إعدادات الشبكة ==="
input double InpLotSize          = 0.01;   // حجم اللوت لكل أمر (Lot Size)
input int    InpOrdersPerSide    = 50;     // عدد الأوامر لكل اتجاه (Buy Stop و Buy Limit كل واحد لوحده)
input double InpStartOffsetPips  = 5.0;    // مسافة أول أمر عن السعر الحالي (بالبيبس Pips)
input double InpStepPips         = 5.0;    // المسافة بين كل أمر والتالي (بالبيبس Pips)
input double InpTakeProfitPips   = 5.0;    // هدف الربح (Take Profit) لكل أمر (بالبيبس Pips)

input group "=== إعدادات عامة ==="
input ulong  InpMagicNumber      = 990050; // الرقم التعريفي (Magic Number) الخاص بالـ EA
input int    InpSlippagePoints   = 10;     // الانزلاق المسموح به (Points)
input int    InpRefreshSeconds   = 3;      // كل كام ثانية يعيد فحص الشبكة ويسد أي فجوة

//====================================================================
// متغيرات عامة
//====================================================================
CTrade   trade;
double   g_pipSize   = 0.0;
datetime g_lastRefresh = 0;

#define SLOT_PREFIX_STOP  "GS-"   // Grid Stop  (Buy Stop  - فوق السعر)
#define SLOT_PREFIX_LIMIT "GL-"   // Grid Limit (Buy Limit - تحت السعر)

//+------------------------------------------------------------------+
//| حساب حجم البيب الصحيح حسب عدد خانات الرمز (3/5 أرقام = بيب = 10 نقاط)|
//+------------------------------------------------------------------+
double CalcPipSize()
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(digits == 3 || digits == 5)
      return point * 10.0;
   return point;
}

//+------------------------------------------------------------------+
//| تطبيع اللوت حسب حدود الرمز (أدنى/أقصى/خطوة)                      |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(stepLot <= 0.0) stepLot = 0.01;

   lot = MathMax(minLot, MathMin(maxLot, lot));
   lot = MathRound(lot / stepLot) * stepLot;
   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| بناء نص التعليق (Comment) الخاص بالسلوت                          |
//+------------------------------------------------------------------+
string SlotComment(const string prefix, const int slot)
{
   return prefix + IntegerToString(slot);
}

//+------------------------------------------------------------------+
//| استخراج رقم السلوت من التعليق لو بيبدأ بنفس البادئة              |
//+------------------------------------------------------------------+
bool ParseSlot(const string comment, const string prefix, int &slot)
{
   int prefixLen = StringLen(prefix);
   if(StringSubstr(comment, 0, prefixLen) != prefix)
      return false;

   string numPart = StringSubstr(comment, prefixLen);
   slot = (int)StringToInteger(numPart);
   return (slot > 0);
}

//+------------------------------------------------------------------+
//| فحص الشبكة وسد أي سلوت ناقص (أول تشغيل أو بعد إغلاق أمر على TP)  |
//+------------------------------------------------------------------+
void EnsureGrid()
{
   int n = InpOrdersPerSide;
   if(n <= 0) return;

   bool stopUsed[];
   bool limitUsed[];
   ArrayResize(stopUsed, n + 1);
   ArrayResize(limitUsed, n + 1);
   ArrayInitialize(stopUsed, false);
   ArrayInitialize(limitUsed, false);

   //--- امسح الأوامر المعلقة الحالية الخاصة بالـ EA ده على نفس الرمز
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(!OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != (long)InpMagicNumber) continue;

      string cmt = OrderGetString(ORDER_COMMENT);
      int slot;
      if(ParseSlot(cmt, SLOT_PREFIX_STOP, slot) && slot <= n)
         stopUsed[slot] = true;
      else if(ParseSlot(cmt, SLOT_PREFIX_LIMIT, slot) && slot <= n)
         limitUsed[slot] = true;
   }

   //--- امسح الصفقات المفتوحة حاليًا (اللي كانت أوامر معلقة وانفذت ولسه TP مالحقهاش)
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber) continue;

      string cmt = PositionGetString(POSITION_COMMENT);
      int slot;
      if(ParseSlot(cmt, SLOT_PREFIX_STOP, slot) && slot <= n)
         stopUsed[slot] = true;
      else if(ParseSlot(cmt, SLOT_PREFIX_LIMIT, slot) && slot <= n)
         limitUsed[slot] = true;
   }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0) return;

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double stopsLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double lot = NormalizeLot(InpLotSize);
   double tpDist = InpTakeProfitPips * g_pipSize;

   for(int slot = 1; slot <= n; slot++)
   {
      double offsetPips = InpStartOffsetPips + (slot - 1) * InpStepPips;
      double distance = offsetPips * g_pipSize;
      if(distance < stopsLevel) distance = stopsLevel + g_pipSize; // حماية أقل مسافة يقبلها البروكر

      //--- Buy Stop فوق السعر
      if(!stopUsed[slot])
      {
         double price = NormalizeDouble(ask + distance, digits);
         double tp    = NormalizeDouble(price + tpDist, digits);
         if(!trade.BuyStop(lot, price, _Symbol, 0.0, tp, ORDER_TIME_GTC, 0, SlotComment(SLOT_PREFIX_STOP, slot)))
            PrintFormat("فشل وضع Buy Stop سلوت %d عند %s - Retcode: %d (%s)",
                        slot, DoubleToString(price, digits), trade.ResultRetcode(), trade.ResultRetcodeDescription());
      }

      //--- Buy Limit تحت السعر
      if(!limitUsed[slot])
      {
         double price = NormalizeDouble(bid - distance, digits);
         double tp    = NormalizeDouble(price + tpDist, digits);
         if(price > 0)
         {
            if(!trade.BuyLimit(lot, price, _Symbol, 0.0, tp, ORDER_TIME_GTC, 0, SlotComment(SLOT_PREFIX_LIMIT, slot)))
               PrintFormat("فشل وضع Buy Limit سلوت %d عند %s - Retcode: %d (%s)",
                           slot, DoubleToString(price, digits), trade.ResultRetcode(), trade.ResultRetcodeDescription());
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   g_pipSize = CalcPipSize();

   if(InpOrdersPerSide <= 0)
   {
      Alert("عدد الأوامر لكل اتجاه لازم يكون أكبر من صفر");
      return INIT_PARAMETERS_INCORRECT;
   }

   EnsureGrid();
   g_lastRefresh = TimeCurrent();
   EventSetTimer(1);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   if(TimeCurrent() - g_lastRefresh >= InpRefreshSeconds)
   {
      EnsureGrid();
      g_lastRefresh = TimeCurrent();
   }
}

//+------------------------------------------------------------------+
//| Timer function - شبكة أمان لو السوق واقف ومفيش تيك جديد           |
//+------------------------------------------------------------------+
void OnTimer()
{
   if(TimeCurrent() - g_lastRefresh >= InpRefreshSeconds)
   {
      EnsureGrid();
      g_lastRefresh = TimeCurrent();
   }
}

//+------------------------------------------------------------------+
//| رد فعل فوري لما أي أمر يتنفذ أو يقفل (بدل ما ننتظر التايمر)       |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                         const MqlTradeRequest &request,
                         const MqlTradeResult &result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD || trans.type == TRADE_TRANSACTION_ORDER_DELETE)
   {
      EnsureGrid();
      g_lastRefresh = TimeCurrent();
   }
}
//+------------------------------------------------------------------+
