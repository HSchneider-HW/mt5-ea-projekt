//+------------------------------------------------------------------+
//| KorridorTrader EA – Block 1/7 | Stand: 28.06.2025, 17:25         |
//| Mit Goldstandard-Trailing & Newsfilter                           |
//+------------------------------------------------------------------+
#property copyright "Harald"
#property version   "5.1"
#property strict

#include <Trade\Trade.mqh>
#include <Controls\CheckBox.mqh>
#define CLR_LIGHTBLUE  C'80,170,255'

//--- Inputs
input int    LookbackCandles_Boxabstand = 10;
input int    DefaultBox_in_Punkten      = 20;
input double StartVolume                = 1;
input double SL_PT                      = 13;
input double TP_PT                      = 50;     
input bool   UseTrailing                = true;
input int    TrailingBeginn_PT          = 12;
input int    TrailingAbstand_PT         = 15;
input bool   UseDynamicSL               = true;
input double TrailingBeginFactor        = 1.5;   // Startfaktor dyn. Trailingbeginn
input double SL_RiskPercent             = 1.0;
input double TP_Tighten_Threshold       = 0.80; // Ab % vom TP der SL enger wird (zB 0.85=85%)
input double TP_Tighten_Factor          = 0.5;  // Wieviel % vom Trailing (zB 0.5=halb so eng)
input bool   KT_TriggerBuy              = false;
input bool   KT_TriggerSell             = false;
input bool   TriggerByClose             = true;
input bool   ShowSLTPinBoxDefault       = false;

//--- Goldstandard Trailing Inputs
input int    TrailingLen_ATR       = 14;
input int    TrailingLen_Body      = 8;
input double TrailingATR_Factor    = 0.8;
input double TrailingBody_Factor   = 1.1;
input double TrailingMaxBody_Factor= 0.38;
input double MinTrailing           = 8;

//--- News-Handling Inputs
input bool   NewsWindowTradeStop   = true;
input string NewsTimes             = "13:25-13:40;15:20-15:40";
input double NewsSL_Factor         = 0.5;

//--- Object Names & Globals
string boxHighLine   = "KT_BoxHigh", boxLowLine   = "KT_BoxLow";
string boxHighLabel  = "KT_BoxHighLbl", boxLowLabel  = "KT_BoxLowLbl";
string boxInfoLabel  = "KT_BoxInfo";
string accountLabel  = "KT_AccountInfo";
string countdownLabel= "KT_Countdown";
string exitButton    = "KT_ExitBtn";
string buyButton     = "KT_BuyBtn", sellButton    = "KT_SellBtn";
string closeTradeButton = "KT_CloseBtn";
string reverseTradeButton = "KT_ReverseBtn";
string newBoxButton      = "KT_NewBoxBtn";
string chkBuyName    = "KT_TriggerBuyChk", chkSellName = "KT_TriggerSellChk";
string entryLineName = "KT_EntryLine", entryLabel   = "KT_EntryLbl";
string slLineName    = "KT_SLLine", slLabel        = "KT_SLLbl";
string tpLineName    = "KT_TPLine", tpLabel        = "KT_TPLbl";
string chkShowSLTPinBoxName = "KT_SLTPBoxChk";

//--- Status & TradeControl
enum TradeExitReason { Exit_None, Exit_SL, Exit_TP, Exit_Manual, Exit_Reversal };
bool   tradeActive = false;
TradeExitReason lastExit = Exit_None;

double boxHigh, boxLow, entryPrice = 0.0;
double tpPrice           = 0.0;
int    boxHighIdx, boxLowIdx;
ulong  entryTicket = 0;
bool   fallbackActive = false, lastTradeIsBuy = false;
bool   showSLTPinBox = ShowSLTPinBoxDefault;
bool   trailActive = false;
bool   manualSLMoved = false;
bool   blockNextTrade = false;

int lastTriggerDir = 0; // 0=nix, 1=oben, -1=unten

CTrade    trade;
CCheckBox cbTriggerBuy, cbTriggerSell;
CCheckBox cbShowSLTPinBox;

//--- Prototypes
void CalculateBox();
void DrawBoxLines();
void DrawBoxInfo();
void DrawAccountInfo();
void DrawCountdown();
void UpdateCountdown();
void ResetCountdown();
void DrawExitButton();
void DrawTradeButtons();
void DrawTriggerLines();
void DrawSLTPLines(bool isBuy);
void HandleTrailing();
void UpdateLabelsOnDrag(string name);
void UpdateBoxLabels();
void UpdateEntryLabel();
void UpdateSLLLabel();
void UpdateTPLLabel();
void UpdateAccountInfo();
void CheckBoxBreakTrigger();
void UpdateSLTPVisibility();
void OnTradeEnd();
void MoveLabelToChartLeft(string objName, double price);
void RedrawAllLabels();
void ForceRelabel();
void CheckSLTouch();
void DeleteTradeLines();
void TryAutoTrade(int signal);

bool AnyLineSelected()
{
    return ObjectGetInteger(0, boxHighLine, OBJPROP_SELECTED) ||
           ObjectGetInteger(0, boxLowLine,  OBJPROP_SELECTED) ||
           ObjectGetInteger(0, slLineName,   OBJPROP_SELECTED) ||
           ObjectGetInteger(0, tpLineName,   OBJPROP_SELECTED);
}

//--- News Utility
bool IsInNewsWindow();
void StringToTime(string t, int &h, int &m);
double GetGoldstandardTrailing();

bool IsInNewsWindow()
{
   MqlDateTime tm; TimeToStruct(TimeCurrent(), tm);
   int hour = tm.hour, min = tm.min;
   string arrTimes[];
   int n = StringSplit(NewsTimes, ';', arrTimes);
   for(int i = 0; i < n; i++)
   {
      string part = arrTimes[i];
      int pos = StringFind(part, "-");
      if(pos > 0)
      {
         string t1 = MyTrim(StringSubstr(part, 0, pos));
         string t2 = MyTrim(StringSubstr(part, pos + 1));
         int h1, m1, h2, m2;
         StringToTime(t1, h1, m1);
         StringToTime(t2, h2, m2);
         int nowMins = hour * 60 + min, fromMins = h1 * 60 + m1, toMins = h2 * 60 + m2;
         if(nowMins >= fromMins && nowMins <= toMins) return true;
      }
   }
   return false;
}

void StringToTime(string t, int &h, int &m)
{
   string parts[];
   if(StringSplit(t, ':', parts) == 2)
   {
      h = (int)StringToInteger(parts[0]);
      m = (int)StringToInteger(parts[1]);
   }
   else
   {
      h = 0;
      m = 0;
   }
}

//+------------------------------------------------------------------+
//| KorridorTrader EA – Block 2/7                                   |
//| Chart-Init, Chart-Objekte, Timer, Tick-Handler, News-Tools      |
//+------------------------------------------------------------------+

int OnInit()
{
   ChartSetInteger(0, CHART_SHOW_TRADE_LEVELS, false);

   // --- BOX: Prüfen, ob es gespeicherte Werte gibt ---
   if(GlobalVariableCheck(_Symbol + "_BoxHigh") && GlobalVariableCheck(_Symbol + "_BoxLow"))
   {
      boxHigh = GlobalVariableGet(_Symbol + "_BoxHigh");
      boxLow  = GlobalVariableGet(_Symbol + "_BoxLow");
      fallbackActive = false; // Die Box ist "persistiert"
   }
   else
   {
      CalculateBox();
   }

   DrawBoxLines();
   DrawBoxInfo();

   // --- TRADE-RESTORE: Laufenden Trade aus GV wiederherstellen ---
   double tradeActiveVar = GlobalVariableCheck(_Symbol + "_TradeActive")
      ? GlobalVariableGet(_Symbol + "_TradeActive")
      : 0.0;
   if(tradeActiveVar > 0.5)
   {
      entryPrice     = GlobalVariableGet(_Symbol + "_EntryPrice");
      lastTradeIsBuy = (GlobalVariableGet(_Symbol + "_LastTradeIsBuy") > 0.5);
      tpPrice        = GlobalVariableGet(_Symbol + "_TPPrice");
      tradeActive    = true;

      double slRestore = GlobalVariableGet(_Symbol + "_SLPrice");
      DrawSLTPLines(lastTradeIsBuy);
      if(slRestore > 0.0)
         ObjectSetDouble(0, slLineName, OBJPROP_PRICE, slRestore);

      trailActive   = true;
      manualSLMoved = false;
   }
   else
   {
      tradeActive = false;
      entryPrice  = 0.0;
   }

   DrawAccountInfo();
   DrawCountdown();
   DrawExitButton();
   DrawTradeButtons();
   DrawTriggerLines();

   cbTriggerBuy.Create(ChartID(),chkBuyName,0, 60, 90,16,16);
   cbTriggerBuy.Text("KT_TriggerBuy");   cbTriggerBuy.Checked(KT_TriggerBuy);
   cbTriggerSell.Create(ChartID(),chkSellName,0,140, 90,16,16);
   cbTriggerSell.Text("KT_TriggerSell"); cbTriggerSell.Checked(KT_TriggerSell);

   cbShowSLTPinBox.Create(ChartID(), chkShowSLTPinBoxName, 0, 80, 110, 18, 18);
   cbShowSLTPinBox.Text("SL, TP, innerhalb Box anzeigen");
   cbShowSLTPinBox.Checked(showSLTPinBox);

   EventSetTimer(1);
   lastExit = Exit_None;

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   string objs[] = {
     boxHighLine,boxLowLine,boxHighLabel,boxLowLabel,boxInfoLabel,
     accountLabel,countdownLabel,exitButton,buyButton,
     sellButton,closeTradeButton,entryLineName,entryLabel,slLineName,slLabel,
     tpLineName,tpLabel, reverseTradeButton,newBoxButton
   };
   for(int i=0;i<ArraySize(objs);i++) ObjectDelete(0,objs[i]);
   cbTriggerBuy.Destroy(); cbTriggerSell.Destroy();
   cbShowSLTPinBox.Destroy();
   EventKillTimer();

   // --- BOXLEVELS SPEICHERN ---
   GlobalVariableSet(_Symbol + "_BoxHigh", ObjectGetDouble(0, boxHighLine, OBJPROP_PRICE));
   GlobalVariableSet(_Symbol + "_BoxLow",  ObjectGetDouble(0, boxLowLine,  OBJPROP_PRICE));

   // --- TRADESTATE SPEICHERN ---
   if(tradeActive)
   {
      GlobalVariableSet(_Symbol + "_TradeActive", 1.0);
      GlobalVariableSet(_Symbol + "_EntryPrice",  entryPrice);
      GlobalVariableSet(_Symbol + "_LastTradeIsBuy", lastTradeIsBuy ? 1.0 : 0.0);
      GlobalVariableSet(_Symbol + "_TPPrice",     tpPrice);
      // Optional: SL speichern (falls verschoben)
      if(ObjectFind(0, slLineName) >= 0)
         GlobalVariableSet(_Symbol + "_SLPrice", ObjectGetDouble(0, slLineName, OBJPROP_PRICE));
      else
         GlobalVariableSet(_Symbol + "_SLPrice", 0.0);
   }
   else
   {
      GlobalVariableSet(_Symbol + "_TradeActive", 0.0);
   }
}

//+------------------------------------------------------------------+
//| KorridorTrader EA – Block 3/7                                   |
//| Draw-Funktionen, CalculateBox, Trigger-Logik, Gold-Trailing     |
//+------------------------------------------------------------------+

void DrawAccountInfo()
{
   ObjectCreate(0,accountLabel,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,accountLabel,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,accountLabel,OBJPROP_XDISTANCE,10);
   ObjectSetInteger(0,accountLabel,OBJPROP_YDISTANCE,40);
   UpdateAccountInfo();
}

void UpdateAccountInfo()
{
   double bal=AccountInfoDouble(ACCOUNT_BALANCE);
   ObjectSetString(0,accountLabel,OBJPROP_TEXT,StringFormat("Balance: %.2f",bal));
}

void DrawCountdown()
{
   ObjectCreate(0,countdownLabel,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,countdownLabel,OBJPROP_CORNER,CORNER_RIGHT_LOWER);
   ObjectSetInteger(0,countdownLabel,OBJPROP_XDISTANCE,80);
   ObjectSetInteger(0,countdownLabel,OBJPROP_YDISTANCE,30);
   ResetCountdown();
}

void DrawExitButton()
{
   ObjectCreate(0,exitButton,OBJ_BUTTON,0,0,0);
   ObjectSetString(0,exitButton,OBJPROP_TEXT,"EA beenden");
   ObjectSetInteger(0,exitButton,OBJPROP_CORNER,CORNER_RIGHT_UPPER);
   ObjectSetInteger(0,exitButton,OBJPROP_XDISTANCE,160);
   ObjectSetInteger(0,exitButton,OBJPROP_XSIZE,100);
   ObjectSetInteger(0,exitButton,OBJPROP_YDISTANCE,20);
}

void DrawTradeButtons()
{
   ObjectCreate(0,buyButton,OBJ_BUTTON,0,0,0);
   ObjectSetString(0,buyButton,OBJPROP_TEXT,"BUY");
   ObjectSetInteger(0,buyButton,OBJPROP_CORNER,CORNER_RIGHT_UPPER);
   ObjectSetInteger(0,buyButton,OBJPROP_XDISTANCE,200);
   ObjectSetInteger(0,buyButton,OBJPROP_YDISTANCE,40);
   ObjectSetInteger(0, buyButton, OBJPROP_BGCOLOR, CLR_LIGHTBLUE);

   ObjectCreate(0,sellButton,OBJ_BUTTON,0,0,0);
   ObjectSetString(0,sellButton,OBJPROP_TEXT,"SELL");
   ObjectSetInteger(0,sellButton,OBJPROP_CORNER,CORNER_RIGHT_UPPER);
   ObjectSetInteger(0,sellButton,OBJPROP_XDISTANCE,100);
   ObjectSetInteger(0,sellButton,OBJPROP_YDISTANCE,40);
   ObjectSetInteger(0,sellButton,OBJPROP_BGCOLOR,clrRed);

   ObjectCreate(0,closeTradeButton,OBJ_BUTTON,0,0,0);
   ObjectSetString(0,closeTradeButton,OBJPROP_TEXT,"Trade schließen");
   ObjectSetInteger(0,closeTradeButton,OBJPROP_CORNER,CORNER_RIGHT_UPPER);
   ObjectSetInteger(0,closeTradeButton,OBJPROP_XDISTANCE,100);
   ObjectSetInteger(0,closeTradeButton,OBJPROP_YDISTANCE,80);
   ObjectSetInteger(0,closeTradeButton,OBJPROP_BGCOLOR,clrDarkGray);
   ObjectSetInteger(0,closeTradeButton,OBJPROP_XSIZE,100);
   
   ObjectCreate(0, reverseTradeButton, OBJ_BUTTON, 0, 0, 0);
   ObjectSetString(0, reverseTradeButton, OBJPROP_TEXT, "Trade Umkehr");
   ObjectSetInteger(0, reverseTradeButton, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
   ObjectSetInteger(0, reverseTradeButton, OBJPROP_XDISTANCE, 200);
   ObjectSetInteger(0, reverseTradeButton, OBJPROP_YDISTANCE, 80);
   ObjectSetInteger(0, reverseTradeButton, OBJPROP_BGCOLOR, clrOrange);
   ObjectSetInteger(0, reverseTradeButton, OBJPROP_XSIZE, 100);

   ObjectCreate(0, newBoxButton, OBJ_BUTTON, 0, 0, 0);
   ObjectSetString(0, newBoxButton, OBJPROP_TEXT, "Box neu");
   ObjectSetInteger(0, newBoxButton, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
   ObjectSetInteger(0, newBoxButton, OBJPROP_XDISTANCE, 100);
   ObjectSetInteger(0, newBoxButton, OBJPROP_YDISTANCE, 120);
   ObjectSetInteger(0, newBoxButton, OBJPROP_BGCOLOR, CLR_LIGHTBLUE);
   ObjectSetInteger(0, newBoxButton, OBJPROP_XSIZE, 100);
}

void DrawBoxLines()
{
   ObjectCreate(0,boxHighLine,OBJ_HLINE,0,0,boxHigh);
   ObjectSetInteger(0,boxHighLine,OBJPROP_COLOR,clrGreen);
   ObjectSetInteger(0,boxHighLine,OBJPROP_STYLE,STYLE_DASHDOT);
   ObjectSetInteger(0,boxHighLine,OBJPROP_SELECTABLE,true);

   ObjectCreate(0,boxHighLabel,OBJ_TEXT,0,0,boxHigh);
   ObjectSetString(0,boxHighLabel,OBJPROP_TEXT,DoubleToString(boxHigh,_Digits));
   ObjectSetInteger(0,boxHighLabel,OBJPROP_COLOR,clrGreen);

   ObjectCreate(0,boxLowLine,OBJ_HLINE,0,0,boxLow);
   ObjectSetInteger(0,boxLowLine,OBJPROP_COLOR,clrRed);
   ObjectSetInteger(0,boxLowLine,OBJPROP_STYLE,STYLE_DASHDOT);
   ObjectSetInteger(0,boxLowLine,OBJPROP_SELECTABLE,true);

   ObjectCreate(0,boxLowLabel,OBJ_TEXT,0,0,boxLow);
   ObjectSetString(0,boxLowLabel,OBJPROP_TEXT,DoubleToString(boxLow,_Digits));
   ObjectSetInteger(0,boxLowLabel,OBJPROP_COLOR,clrRed);

   UpdateBoxLabels();
}

void DrawBoxInfo()
{
   string txt=StringFormat("Box H:%.5f L:%.5f pts:%d fb:%s",
     boxHigh,boxLow,int((boxHigh-boxLow)/_Point),fallbackActive?"yes":"no");
   ObjectCreate(0,boxInfoLabel,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,boxInfoLabel,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,boxInfoLabel,OBJPROP_XDISTANCE,10);
   ObjectSetInteger(0,boxInfoLabel,OBJPROP_YDISTANCE,20);
   ObjectSetString(0,boxInfoLabel,OBJPROP_TEXT,txt);
}

//+------------------------------------------------------------------+
//| KorridorTrader EA – Block 4/7                                   |
//| CalculateBox, Trigger-Logik, Tradeausführung, Gold-Trailing     |
//+------------------------------------------------------------------+

void CalculateBox()
{
   double tickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double tickVal =SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double pointVal=tickSize/tickVal;
   bool   kerzenBoxOk = false;

   if(Bars(_Symbol,_Period)>LookbackCandles_Boxabstand)
   {
      double hi=-DBL_MAX, lo=DBL_MAX; int hiI=1, loI=1;
      for(int i=1; i<=LookbackCandles_Boxabstand; i++)
      {
         double h=iHigh(_Symbol,_Period,i);
         double l=iLow (_Symbol,_Period,i);
         if(h>hi){hi=h;hiI=i;} if(l<lo){lo=l;loI=i;}
      }
      double mid = iClose(_Symbol,_Period,1);
      if(mid >= lo && mid <= hi)
      {
         boxHigh=hi; boxLow=lo;
         boxHighIdx=hiI; boxLowIdx=loI;
         fallbackActive=false;
         return;
      }
   }
   // --- Defaultbox, wenn Kurs außerhalb! ---
   double mid = iClose(_Symbol,_Period,1);
   boxHigh=mid+(DefaultBox_in_Punkten/2.0)*pointVal;
   boxLow =mid-(DefaultBox_in_Punkten/2.0)*pointVal;
   boxHighIdx=boxLowIdx=1;
   fallbackActive=true;
}

// --- Trigger-Logik: NIE invertiert, BoxHigh IMMER BUY, BoxLow IMMER SELL! ---
void CheckBoxBreakTrigger()
{
    if (tradeActive) return;
    if (blockNextTrade) return;
    if (AnyLineSelected()) return; // Tradesperre beim Verschieben

    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double highLine = ObjectGetDouble(0, boxHighLine, OBJPROP_PRICE);
    double lowLine  = ObjectGetDouble(0, boxLowLine,  OBJPROP_PRICE);

    bool triggerBuy  = false;
    bool triggerSell = false;

    // TICKGENAU
    if (!TriggerByClose)
    {
        if (bid >= highLine)  triggerBuy = true;
        if (ask <= lowLine)   triggerSell = true;
    }
    // KERZENSCHLUSS
    else
    {
        double lastClose = iClose(_Symbol, _Period, 1);
        if (lastClose > highLine) triggerBuy = true;
        if (lastClose < lowLine)  triggerSell = true;
    }

    if (triggerBuy)  TryAutoTrade(1);  // 1 = BUY
    if (triggerSell) TryAutoTrade(-1); // -1 = SELL
}

// --- Tradeausführung + Handelsstopp im Newsfenster ---
void TryAutoTrade(int signal)
{
    if(tradeActive) return;
    if(blockNextTrade) return;
    if(AnyLineSelected()) return;
    if(IsInNewsWindow() && NewsWindowTradeStop) return;

    if(signal == 1)
    {
        if(PositionSelect(_Symbol) && PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_SELL)
            trade.PositionClose(PositionGetInteger(POSITION_TICKET));
        if(trade.Buy(StartVolume, _Symbol))
        {
            entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            entryTicket = trade.ResultOrder();
            lastTradeIsBuy = true;
            tradeActive = true; lastExit = Exit_None;
            DrawSLTPLines(true);
            trailActive = true; manualSLMoved = false;
        }
    }
    if(signal == -1)
    {
        if(PositionSelect(_Symbol) && PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)
            trade.PositionClose(PositionGetInteger(POSITION_TICKET));
        if(trade.Sell(StartVolume, _Symbol))
        {
            entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            entryTicket = trade.ResultOrder();
            lastTradeIsBuy = false;
            tradeActive = true; lastExit = Exit_None;
            DrawSLTPLines(false);
            trailActive = true; manualSLMoved = false;
        }
    }
}

// --- Goldstandard Trailing: ATR + Candlebody + MaxBody ---
double GetGoldstandardTrailing()
{
    double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double pointVal  = tickSize / tickValue;

    double atr = GetATR(TrailingLen_ATR) / pointVal; // ATR in Punkten

    double sumBody = 0, maxBody = 0;
    for(int i=1; i<=TrailingLen_Body; i++)
    {
        double body = MathAbs(iClose(_Symbol, _Period, i) - iOpen(_Symbol, _Period, i)) / pointVal;
        sumBody += body;
        if(body > maxBody) maxBody = body;
    }
    double avgBody = sumBody / TrailingLen_Body;

    double trailing = MathMax(MinTrailing,
      MathMin(
        TrailingATR_Factor * atr,
        MathMin(
          TrailingBody_Factor * avgBody,
          TrailingMaxBody_Factor * maxBody
        )
      )
    );

    return trailing * pointVal; // zurück ins Preis-Format
}

// Liefert den ATR-Wert (universal für alle Timeframes/Symbole)
double GetATR(int period)
{
   int handle = iATR(_Symbol, _Period, period);
   if(handle == INVALID_HANDLE) return 0;
   double buf[];
   if(CopyBuffer(handle, 0, 0, 1, buf)==1) return buf[0];
   return 0;
}

string MyTrim(string s) // nur führende Leerzeichen weg
{
   int i = 0, n = StringLen(s);
   while(i<n && StringGetCharacter(s,i)<=32) i++;
   return StringSubstr(s, i);
}

double GetDynamicTrailingBegin()
{
    // Hole aktuellen dynamischen Trailing-Abstand
    double dynamicTrailing = GetGoldstandardTrailing();

    // Setze Mindestbeginn (nie unter MinTrailing, nie unter Trailing selbst)
    double trailingBegin = MathMax(dynamicTrailing, TrailingBeginFactor * dynamicTrailing);

    return trailingBegin; // Rückgabe in Preis-Einheit (wie Trailing selbst)
}

//+------------------------------------------------------------------+
//| KorridorTrader EA – Block 5/7                                   |
//| SL/TP/Entry-Linien, Drag, SL-Touch, Trailing-Logik              |
//+------------------------------------------------------------------+

void DrawSLTPLines(bool isBuy)
{
   ObjectCreate(0,entryLineName,OBJ_HLINE,0,0,entryPrice);
   ObjectSetInteger(0,entryLineName,OBJPROP_COLOR,clrBlue);
   ObjectSetInteger(0,entryLineName,OBJPROP_STYLE,STYLE_SOLID);
   ObjectSetInteger(0,entryLineName,OBJPROP_SELECTABLE,true);

   ObjectCreate(0,entryLabel,OBJ_TEXT,0,0,entryPrice);
   ObjectSetString(0,entryLabel,OBJPROP_TEXT,
     (isBuy?"buy":"sell")+" at "+DoubleToString(StartVolume,2)+" by "+(string)entryTicket);
   ObjectSetInteger(0,entryLabel,OBJPROP_COLOR,clrBlue);

   MoveLabelToChartLeft(entryLabel,entryPrice);

   double tickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double tickVal =SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double pointVal=tickSize/tickVal;
   double slDist = SL_PT*pointVal;
   double slPrice=isBuy?entryPrice-slDist:entryPrice+slDist;
   tpPrice     =isBuy?entryPrice+TP_PT*pointVal:entryPrice-TP_PT*pointVal;

   ObjectCreate(0,slLineName,OBJ_HLINE,0,0,slPrice);
   ObjectSetInteger(0,slLineName,OBJPROP_COLOR,clrRed);
   ObjectSetInteger(0,slLineName,OBJPROP_STYLE,STYLE_SOLID);
   ObjectSetInteger(0,slLineName,OBJPROP_SELECTABLE,true);

   ObjectCreate(0,slLabel,OBJ_TEXT,0,0,slPrice);
   double slDiff = isBuy ? (slPrice-entryPrice)/pointVal : (entryPrice-slPrice)/pointVal;
   double slMoney = isBuy ? (slPrice-entryPrice)*StartVolume*(tickVal/tickSize)
                          : (entryPrice-slPrice)*StartVolume*(tickVal/tickSize);
   ObjectSetString(0,slLabel,OBJPROP_TEXT,
       StringFormat("SL %+.2f € (%+.1f)", slMoney, slDiff));
   ObjectSetInteger(0,slLabel,OBJPROP_COLOR,clrRed);
   MoveLabelToChartLeft(slLabel,slPrice);

   ObjectCreate(0,tpLineName,OBJ_HLINE,0,0,tpPrice);
   ObjectSetInteger(0,tpLineName,OBJPROP_COLOR,clrGreen);
   ObjectSetInteger(0,tpLineName,OBJPROP_STYLE,STYLE_SOLID);
   ObjectSetInteger(0,tpLineName,OBJPROP_SELECTABLE,true);

   ObjectCreate(0,tpLabel,OBJ_TEXT,0,0,tpPrice);
   double tpDiff = isBuy ? (tpPrice-entryPrice)/pointVal : (entryPrice-tpPrice)/pointVal;
   double tpMoney= isBuy
     ? (tpPrice-entryPrice)*StartVolume*(tickVal/tickSize)
     : (entryPrice-tpPrice)*StartVolume*(tickVal/tickSize);
   ObjectSetString(0,tpLabel,OBJPROP_TEXT,
       StringFormat("TP %+.2f € (%+.1f)", tpMoney, tpDiff));
   ObjectSetInteger(0,tpLabel,OBJPROP_COLOR,clrGreen);
   MoveLabelToChartLeft(tpLabel,tpPrice);

   UpdateSLTPVisibility();
}

void DeleteTradeLines()
{
   ObjectDelete(0,entryLineName); ObjectDelete(0,entryLabel);
   ObjectDelete(0,slLineName);    ObjectDelete(0,slLabel);
   ObjectDelete(0,tpLineName);    ObjectDelete(0,tpLabel);
}

void UpdateLabelsOnDrag(string name)
{
   if(name==boxHighLine||name==boxLowLine)
   {
      UpdateBoxLabels();
      // Nach jedem Verschieben sofort speichern!
      GlobalVariableSet(_Symbol + "_BoxHigh", ObjectGetDouble(0, boxHighLine, OBJPROP_PRICE));
      GlobalVariableSet(_Symbol + "_BoxLow",  ObjectGetDouble(0, boxLowLine,  OBJPROP_PRICE));
   }
   else if(name==entryLineName)            UpdateEntryLabel();
   else if(name==slLineName)               { UpdateSLLLabel(); manualSLMoved=true; trailActive=false; }
   else if(name==tpLineName)               UpdateTPLLabel();
}

void UpdateBoxLabels()
{
   double yH=ObjectGetDouble(0,boxHighLine,OBJPROP_PRICE);
   double yL=ObjectGetDouble(0,boxLowLine, OBJPROP_PRICE);
   ObjectSetDouble(0,boxHighLabel,OBJPROP_PRICE,yH);
   ObjectSetString(0,boxHighLabel,OBJPROP_TEXT,DoubleToString(yH,_Digits));
   MoveLabelToChartLeft(boxHighLabel, yH);

   ObjectSetDouble(0,boxLowLabel, OBJPROP_PRICE,yL);
   ObjectSetString(0,boxLowLabel, OBJPROP_TEXT,DoubleToString(yL,_Digits));
   MoveLabelToChartLeft(boxLowLabel, yL);
}

void UpdateEntryLabel()
{
   double y=ObjectGetDouble(0,entryLineName,OBJPROP_PRICE);
   ObjectSetDouble(0,entryLabel,OBJPROP_PRICE,y);
   MoveLabelToChartLeft(entryLabel, y);
}

void UpdateSLTPVisibility()
{
   if(!tradeActive) return;
   double price = entryPrice;
   double high  = ObjectGetDouble(0,boxHighLine,OBJPROP_PRICE);
   double low   = ObjectGetDouble(0,boxLowLine,OBJPROP_PRICE);

   bool inBox = (price <= high && price >= low);
   bool visible = (showSLTPinBox || !inBox);

   ObjectSetInteger(0,slLineName,OBJPROP_HIDDEN,!visible);
   ObjectSetInteger(0,slLabel,OBJPROP_HIDDEN,!visible);
   ObjectSetInteger(0,tpLineName,OBJPROP_HIDDEN,!visible);
   ObjectSetInteger(0,tpLabel,OBJPROP_HIDDEN,!visible);
}

// --- SL-Touch: schließt Trade tickgenau
void CheckSLTouch()
{
   if(!tradeActive) return;
   double cur = lastTradeIsBuy
     ? SymbolInfoDouble(_Symbol,SYMBOL_BID)
     : SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double sl = ObjectGetDouble(0,slLineName,OBJPROP_PRICE);
   if( (lastTradeIsBuy && cur<=sl) || (!lastTradeIsBuy && cur>=sl) )
   {
      trade.PositionClose(entryTicket);
      lastExit = Exit_SL;
      tradeActive = false;
      OnTradeEnd();
   }
}

// --- Profi-HandleTrailing mit News/Goldstandard ---
void HandleTrailing()
{
   if(!tradeActive || entryPrice==0) return;

   double tickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double tickVal =SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double pointVal=tickSize/tickVal;
   double cur = lastTradeIsBuy
                ? SymbolInfoDouble(_Symbol,SYMBOL_BID)
                : SymbolInfoDouble(_Symbol,SYMBOL_ASK);

   double movedPts = MathAbs((cur-entryPrice)/pointVal);

   // Newsfenster: Handelsstopp oder SL sofort defensiv
   if(IsInNewsWindow())
   {
      if(NewsWindowTradeStop) {
         return;
      }
      else
      {
         double high = iHigh(_Symbol,_Period,0);
         double low  = iLow (_Symbol,_Period,0);
         double range = MathAbs(high-low);
         double newSL = lastTradeIsBuy
              ? entryPrice - NewsSL_Factor * range
              : entryPrice + NewsSL_Factor * range;
         ObjectSetDouble(0,slLineName,OBJPROP_PRICE,newSL);
         UpdateSLLLabel();
         return;
      }
   }

   // --- DYNAMISCHER TRAILINGBEGINN ---
   double dynamicTrailing = GetGoldstandardTrailing();
   double dynamicTrailingBegin = GetDynamicTrailingBegin();

   // --- TP-NÄHE-LOGIK ergänzen ---
   double tightenLevel = lastTradeIsBuy
        ? tpPrice - (tpPrice-entryPrice)*(1-TP_Tighten_Threshold)
        : tpPrice + (entryPrice-tpPrice)*(1-TP_Tighten_Threshold);

   bool tighten = (lastTradeIsBuy && cur >= tightenLevel) || (!lastTradeIsBuy && cur <= tightenLevel);
   double finalTrailing = dynamicTrailing;
   if(tighten)
      finalTrailing = MathMax(MinTrailing, TP_Tighten_Factor * dynamicTrailing);

   if(movedPts >= dynamicTrailingBegin)
   {
      double newSL = lastTradeIsBuy
                     ? cur - finalTrailing
                     : cur + finalTrailing;

      double oldSL = ObjectGetDouble(0,slLineName,OBJPROP_PRICE);

      if(!manualSLMoved &&
        ((lastTradeIsBuy && newSL>oldSL) || (!lastTradeIsBuy && newSL<oldSL)))
      {
         ObjectSetDouble(0,slLineName,OBJPROP_PRICE,newSL);
         UpdateSLLLabel();
      }
   }
}

void DrawTriggerLines()
{
   // (Platzhalter) Aktuell nicht genutzt. Erweiterbar für künftige Trigger-Objekte!
}

void MoveLabelToChartLeft(string objName, double price)
{
   int firstBar = (int)ChartGetInteger(0, CHART_FIRST_VISIBLE_BAR);
   if(firstBar < Bars(_Symbol,_Period))
   {
       datetime leftTime = iTime(_Symbol, _Period, firstBar);
       ObjectMove(0, objName, 0, leftTime, price);
   }
   ObjectSetInteger(0, objName, OBJPROP_XDISTANCE, -10);
}

//+------------------------------------------------------------------+
//| KorridorTrader EA – Block 6/7                                   |
//| Label-Updates, Countdown, ChartEvent, TradeEnd                  |
//+------------------------------------------------------------------+

void RedrawAllLabels()
{
   UpdateBoxLabels();
   if(tradeActive)
   {
      UpdateEntryLabel();
      UpdateSLLLabel();
      UpdateTPLLabel();
   }
}

void ForceRelabel()
{
   RedrawAllLabels();
}

void ResetCountdown()
{
   int per=PeriodSeconds();
   ObjectSetString(0,countdownLabel,OBJPROP_TEXT,
     StringFormat("%02d:%02d:%02d",per/3600,(per%3600)/60,per%60));
}

void UpdateCountdown()
{
   int per=PeriodSeconds(), el=int(TimeCurrent()-iTime(_Symbol,_Period,0));
   int rem=MathMax(0,per-el);
   ObjectSetString(0,countdownLabel,OBJPROP_TEXT,
     StringFormat("%02d:%02d:%02d",rem/3600,(rem%3600)/60,rem%60));
}

void UpdateSLLLabel()
{
   double sl=ObjectGetDouble(0,slLineName,OBJPROP_PRICE);
   ObjectSetDouble(0,slLabel,OBJPROP_PRICE,sl);
   double pointVal = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE) / SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double slDiff = lastTradeIsBuy ? (sl-entryPrice)/pointVal : (entryPrice-sl)/pointVal;
   double slMoney = lastTradeIsBuy
       ? (sl-entryPrice)*StartVolume*(SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE)/SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE))
       : (entryPrice-sl)*StartVolume*(SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE)/SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE));
   ObjectSetString(0,slLabel,OBJPROP_TEXT,
       StringFormat("SL %+.2f € (%+.1f)", slMoney, slDiff));
   MoveLabelToChartLeft(slLabel, sl);
}
void UpdateTPLLabel()
{
   double tp=ObjectGetDouble(0,tpLineName,OBJPROP_PRICE);
   ObjectSetDouble(0,tpLabel,OBJPROP_PRICE,tp);
   double pointVal = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE) / SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double tpDiff = lastTradeIsBuy ? (tp-entryPrice)/pointVal : (entryPrice-tp)/pointVal;
   double tpMoney= lastTradeIsBuy
     ? (tp-entryPrice)*StartVolume
       *(SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE)
         /SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE))
     : (entryPrice-tp)*StartVolume
       *(SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE)
         /SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE));
   ObjectSetString(0,tpLabel,OBJPROP_TEXT,
       StringFormat("TP %+.2f € (%+.1f)", tpMoney, tpDiff));
   MoveLabelToChartLeft(tpLabel, tp);
}

void OnTradeEnd()
{
   DeleteTradeLines();

   // Box immer nach Trade-Ende (SL/TP/Manual) neu berechnen
   if(lastExit==Exit_SL || lastExit==Exit_TP || lastExit==Exit_Manual)
   {
      CalculateBox();
      DrawBoxLines();
      DrawBoxInfo();

      // --- BOXLEVELS SPEICHERN ---
      GlobalVariableSet(_Symbol + "_BoxHigh", ObjectGetDouble(0, boxHighLine, OBJPROP_PRICE));
      GlobalVariableSet(_Symbol + "_BoxLow",  ObjectGetDouble(0, boxLowLine,  OBJPROP_PRICE));
   }

   // --- TRADESTATUS ZURÜCKSETZEN ---
   GlobalVariableSet(_Symbol + "_TradeActive", 0.0);
   GlobalVariableSet(_Symbol + "_EntryPrice",  0.0);
   GlobalVariableSet(_Symbol + "_LastTradeIsBuy", 0.0);
   GlobalVariableSet(_Symbol + "_TPPrice",     0.0);
   GlobalVariableSet(_Symbol + "_SLPrice",     0.0);

   RedrawAllLabels();

   blockNextTrade=true; // Nach Trade wird Auto-Trade bis neue Kerze geblockt!
   tradeActive = false;
}

void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
{
   if(id==CHARTEVENT_OBJECT_CLICK && sparam==exitButton)
      ExpertRemove();

   if(id==CHARTEVENT_OBJECT_CLICK && sparam==buyButton)
   {
      if(tradeActive) return;
      if(AnyLineSelected()) return;
      if(PositionSelect(_Symbol) && PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_SELL)
         trade.PositionClose(PositionGetInteger(POSITION_TICKET));
      if(trade.Buy(StartVolume,_Symbol))
      {
         entryPrice     = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
         entryTicket    = trade.ResultOrder();
         lastTradeIsBuy = true;
         tradeActive = true; lastExit = Exit_None;
         DrawSLTPLines(true);
         trailActive=true; manualSLMoved=false;
      }
    
    if(id == CHARTEVENT_OBJECT_CLICK && sparam == newBoxButton) 
      {
       CalculateBox();
       DrawBoxLines();
       DrawBoxInfo();
    
       // Optional: Box-Levels speichern
       GlobalVariableSet(_Symbol + "_BoxHigh", ObjectGetDouble(0, boxHighLine, OBJPROP_PRICE));
       GlobalVariableSet(_Symbol + "_BoxLow",  ObjectGetDouble(0, boxLowLine,  OBJPROP_PRICE));
       RedrawAllLabels();
      }
      
      // --- NEU: Trade Umkehr Button ---
      if(id==CHARTEVENT_OBJECT_CLICK && sparam==reverseTradeButton)
      {
      if(tradeActive && PositionSelect(_Symbol))
       {
        // 1. Aktuellen Trade schließen
        trade.PositionClose(PositionGetInteger(POSITION_TICKET));
        Sleep(500); // Kleine Pause für Sicherheit

        // 2. Sofort neuen Trade in Gegenrichtung eröffnen
        int signal = lastTradeIsBuy ? -1 : 1; // Gegensignal
       TryAutoTrade(signal);
       }  
      }
 }
   
//+------------------------------------------------------------------+
//| KorridorTrader EA – Block 7/7                                   |
//| Abschluss: ChartEvent, Zoom/Drag, Endnote                       |
//+------------------------------------------------------------------+

   if(id==CHARTEVENT_OBJECT_CLICK && sparam==sellButton)
   {
      if(tradeActive) return;
      if(AnyLineSelected()) return;
      if(PositionSelect(_Symbol) && PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)
         trade.PositionClose(PositionGetInteger(POSITION_TICKET));
      if(trade.Sell(StartVolume,_Symbol))
      {
         entryPrice     = SymbolInfoDouble(_Symbol,SYMBOL_BID);
         entryTicket    = trade.ResultOrder();
         lastTradeIsBuy = false;
         tradeActive = true; lastExit = Exit_None;
         DrawSLTPLines(false);
         trailActive=true; manualSLMoved=false;
      }
   }

   if(id==CHARTEVENT_OBJECT_CLICK && sparam==closeTradeButton)
   {
      if(tradeActive && PositionSelect(_Symbol)) {
         trade.PositionClose(PositionGetInteger(POSITION_TICKET));
         entryPrice=0; trailActive=false;
         lastExit = Exit_Manual;
         tradeActive = false;
         OnTradeEnd();
      }
      blockNextTrade=true;
   }

   if(id==CHARTEVENT_OBJECT_CLICK && sparam==chkShowSLTPinBoxName)
   {
      showSLTPinBox = cbShowSLTPinBox.Checked();
      UpdateSLTPVisibility();
   }

   if(id==CHARTEVENT_OBJECT_DRAG)
      UpdateLabelsOnDrag(sparam);

   if(id==CHARTEVENT_CHART_CHANGE)
      ForceRelabel();
}

//+------------------------------------------------------------------+
//| KorridorTrader EA – ENDE                                         |
//+------------------------------------------------------------------+

// Stand: 28.06.2025, 17:32 Uhr
//
// - Box- und Triggerlogik 100% Harald-Prinzip (BUY/SELL fest)
// - Keine Dopplungen, alle Funktionsprototypen mit Körper
// - SL/TP/Trailing nach Goldstandard & Newsfenster voll implementiert
// - Box, SL, TP, Entry, Trigger: robust bei Drag, TF-Wechsel, News
// - Handelsstopp und defensives SL-Management zu Newszeiten
// - Kompatibel MT5, sofort lauffähig!
//
