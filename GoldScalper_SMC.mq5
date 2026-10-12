//+------------------------------------------------------------------+
//|                                             GoldScalper_SMC.mq5  |
//| SMC + AMD-inspired setups + Tick Volume Profile                 |
//| Version 1.00                                                     |
//|                                                                  |
//| Research/testing version. Trading is disabled by default.        |
//+------------------------------------------------------------------+

#property strict
#property version "1.00"
#property description "SMC Gold Scalper with tick-volume profile filters"

#include <Trade/Trade.mqh>

CTrade trade;

//====================================================================
// USER SETTINGS
//====================================================================

// Trading
input bool   InpEnableTrading          = false;
input ulong  InpMagicNumber            = 26101101;
input double InpFixedLot               = 0.01;

// Risk is calculated from the initial deposit configured below.
input double InpInitialDeposit         = 20.00;
input double InpRiskPercent            = 5.0;
input double InpRewardRiskRatio        = 2.0;

// Timeframes
input ENUM_TIMEFRAMES InpEntryTF       = PERIOD_M1;
input ENUM_TIMEFRAMES InpConfirmTF     = PERIOD_M5;
input ENUM_TIMEFRAMES InpContextTF     = PERIOD_M15;

// Market structure
input int    InpSwingLookback          = 20;
input int    InpContextLookback        = 30;
input int    InpSweepLookback          = 12;
input int    InpEntryLookback          = 8;
input double InpStopBufferPoints       = 30;

// Volume profile
input bool   InpUseVolumeProfile       = true;
input int    InpFixedProfileBars       = 60;
input int    InpProfileBins            = 40;
input double InpValueAreaPercent       = 70.0;

// Session settings use BROKER SERVER TIME.
input int    InpSessionStartHour       = 8;
input int    InpSessionEndHour         = 18;

// Spread and execution
input int    InpMaxSpreadPoints        = 100;
input int    InpDeviationPoints        = 30;

// Safety
input int    InpMaxPositions           = 1;
input int    InpMaxTradesPerDay        = 3;
input double InpDailyLossLimitPercent  = 10.0;
input bool   InpCloseOnOppositeSignal  = false;

//====================================================================
// INTERNAL VARIABLES
//====================================================================

datetime lastEntryBar = 0;
datetime lastConfirmBar = 0;

int tradesToday = 0;
int dayIdentifier = -1;

double dayStartEquity = 0.0;
double initialRiskMoney = 0.0;

datetime lastProcessedSetupBar = 0;

//====================================================================
// ENUMERATIONS
//====================================================================

enum MarketBias
{
   BIAS_NEUTRAL = 0,
   BIAS_BULLISH = 1,
   BIAS_BEARISH = -1
};

//====================================================================
// INITIALIZATION
//====================================================================

int OnInit()
{
   if(InpInitialDeposit <= 0 ||
      InpRiskPercent <= 0 ||
      InpRewardRiskRatio <= 0 ||
      InpFixedLot <= 0)
   {
      Print("Invalid risk, deposit, reward-risk, or lot settings.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpSwingLookback < 3 ||
      InpSweepLookback < 3 ||
      InpEntryLookback < 3 ||
      InpProfileBins < 5)
   {
      Print("Lookback or profile settings are too small.");
      return INIT_PARAMETERS_INCORRECT;
   }

   initialRiskMoney =
      InpInitialDeposit * InpRiskPercent / 100.0;

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   ResetDailyCounters();

   Print("GoldScalper_SMC initialized.");
   Print("Symbol: ", _Symbol);
   Print("Initial deposit: $", InpInitialDeposit);
   Print("Planned risk per trade: $", initialRiskMoney);
   Print("Reward-to-risk: 1:", InpRewardRiskRatio);
   Print("Preferred lot: ", InpFixedLot);
   Print("Trading enabled: ", InpEnableTrading);

   if(!InpEnableTrading)
      Print("SAFE MODE: signals only; order execution is disabled.");

   return INIT_SUCCEEDED;
}

//====================================================================
// MAIN TICK FUNCTION
//====================================================================

void OnTick()
{
   UpdateDailyCounters();

   // Manage positions even if no new entry candle has formed.
   ManageOpenPositions();

   // Only evaluate entries once per new entry-timeframe candle.
   if(!IsNewBar(InpEntryTF, lastEntryBar))
      return;

   if(!InpEnableTrading)
   {
      EvaluateSignalOnly();
      return;
   }

   if(!CanOpenNewTrade())
      return;

   int signal = GetTradingSignal();

   if(signal == 0)
      return;

   // Prevent duplicate entries from the same confirmation candle.
   datetime confirmTime = iTime(_Symbol, InpConfirmTF, 1);

   if(confirmTime == 0 || confirmTime == lastProcessedSetupBar)
      return;

   if(OpenPosition(signal))
      lastProcessedSetupBar = confirmTime;
}

//====================================================================
// NEW BAR DETECTION
//====================================================================

bool IsNewBar(ENUM_TIMEFRAMES timeframe, datetime &storedTime)
{
   datetime currentTime = iTime(_Symbol, timeframe, 0);

   if(currentTime <= 0)
      return false;

   if(currentTime != storedTime)
   {
      storedTime = currentTime;
      return true;
   }

   return false;
}

//====================================================================
// DAILY COUNTERS
//====================================================================

int GetCurrentDayIdentifier()
{
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);

   return now.year * 10000 + now.mon * 100 + now.day;
}

void ResetDailyCounters()
{
   dayIdentifier = GetCurrentDayIdentifier();
   dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   tradesToday = 0;

   Print("Daily counters reset. Starting equity: ",
         dayStartEquity);
}

void UpdateDailyCounters()
{
   int currentDay = GetCurrentDayIdentifier();

   if(currentDay != dayIdentifier)
      ResetDailyCounters();
}

//====================================================================
// TRADING PERMISSION CHECKS
//====================================================================

bool CanOpenNewTrade()
{
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
   {
      Print("Trade blocked: terminal is disconnected.");
      return false;
   }

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      Print("Trade blocked: terminal trading is disabled.");
      return false;
   }

   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      Print("Trade blocked: EA trading permission is disabled.");
      return false;
   }

   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
   {
      Print("Trade blocked: account trading is disabled.");
      return false;
   }

   if(tradesToday >= InpMaxTradesPerDay)
   {
      Print("Trade blocked: daily trade limit reached.");
      return false;
   }

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   double dailyLossLimit =
      InpInitialDeposit * InpDailyLossLimitPercent / 100.0;

   if(dayStartEquity - equity >= dailyLossLimit)
   {
      Print("Trade blocked: daily equity-loss limit reached.");
      return false;
   }

   if(CurrentSpreadPoints() > InpMaxSpreadPoints)
   {
      Print("Trade blocked: spread is too high.");
      return false;
   }

   if(CountOurPositions() >= InpMaxPositions)
   {
      Print("Trade blocked: position limit reached.");
      return false;
   }

   return true;
}

//====================================================================
// SPREAD
//====================================================================

double CurrentSpreadPoints()
{
   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return 999999.0;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   if(point <= 0)
      return 999999.0;

   return (tick.ask - tick.bid) / point;
}

//====================================================================
// POSITION COUNT
//====================================================================

int CountOurPositions()
{
   int count = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) !=
         InpMagicNumber)
         continue;

      count++;
   }

   return count;
}

//====================================================================
// SWING HIGH / LOW
//====================================================================

// Uses closed candles only.
// Returns the highest high from bars 2 through lookback+1.
double RecentSwingHigh(ENUM_TIMEFRAMES timeframe, int lookback)
{
   if(Bars(_Symbol, timeframe) < lookback + 5)
      return 0.0;

   int index = iHighest(_Symbol, timeframe, MODE_HIGH,
                        lookback, 2);

   if(index < 0)
      return 0.0;

   return iHigh(_Symbol, timeframe, index);
}

// Returns the lowest low from bars 2 through lookback+1.
double RecentSwingLow(ENUM_TIMEFRAMES timeframe, int lookback)
{
   if(Bars(_Symbol, timeframe) < lookback + 5)
      return 0.0;

   int index = iLowest(_Symbol, timeframe, MODE_LOW,
                       lookback, 2);

   if(index < 0)
      return 0.0;

   return iLow(_Symbol, timeframe, index);
}

//====================================================================
// MARKET STRUCTURE
//====================================================================

MarketBias GetContextBias()
{
   if(Bars(_Symbol, InpContextTF) < InpContextLookback + 5)
      return BIAS_NEUTRAL;

   double close1 = iClose(_Symbol, InpContextTF, 1);

   double swingHigh =
      RecentSwingHigh(InpContextTF, InpContextLookback);

   double swingLow =
      RecentSwingLow(InpContextTF, InpContextLookback);

   if(close1 <= 0 || swingHigh <= 0 || swingLow <= 0)
      return BIAS_NEUTRAL;

   // A recent close beyond structure suggests a directional break.
   if(close1 > swingHigh)
      return BIAS_BULLISH;

   if(close1 < swingLow)
      return BIAS_BEARISH;

   // If no new break occurred, use the last two closed candles'
   // short-term direction only as a weak directional filter.
   double close2 = iClose(_Symbol, InpContextTF, 2);

   if(close1 > close2)
      return BIAS_BULLISH;

   if(close1 < close2)
      return BIAS_BEARISH;

   return BIAS_NEUTRAL;
}

//====================================================================
// LIQUIDITY SWEEPS
//====================================================================

bool BullishLiquiditySweep()
{
   double priorLow =
      RecentSwingLow(InpConfirmTF, InpSweepLookback);

   double candleLow = iLow(_Symbol, InpConfirmTF, 1);
   double candleClose = iClose(_Symbol, InpConfirmTF, 1);

   if(priorLow <= 0 || candleLow <= 0 || candleClose <= 0)
      return false;

   // Price traded below the previous low and closed back above it.
   return (candleLow < priorLow && candleClose > priorLow);
}

bool BearishLiquiditySweep()
{
   double priorHigh =
      RecentSwingHigh(InpConfirmTF, InpSweepLookback);

   double candleHigh = iHigh(_Symbol, InpConfirmTF, 1);
   double candleClose = iClose(_Symbol, InpConfirmTF, 1);

   if(priorHigh <= 0 || candleHigh <= 0 || candleClose <= 0)
      return false;

   return (candleHigh > priorHigh && candleClose < priorHigh);
}

//====================================================================
// CONFIRMATION STRUCTURE SHIFT
//====================================================================

bool BullishStructureShift()
{
   double priorHigh =
      RecentSwingHigh(InpConfirmTF, InpSwingLookback);

   double close1 = iClose(_Symbol, InpConfirmTF, 1);

   if(priorHigh <= 0 || close1 <= 0)
      return false;

   return close1 > priorHigh;
}

bool BearishStructureShift()
{
   double priorLow =
      RecentSwingLow(InpConfirmTF, InpSwingLookback);

   double close1 = iClose(_Symbol, InpConfirmTF, 1);

   if(priorLow <= 0 || close1 <= 0)
      return false;

   return close1 < priorLow;
}

//====================================================================
// ENTRY TIMEFRAME CONFIRMATION
//====================================================================

bool BullishEntryTrigger()
{
   double priorHigh =
      RecentSwingHigh(InpEntryTF, InpEntryLookback);

   double close1 = iClose(_Symbol, InpEntryTF, 1);

   if(priorHigh <= 0 || close1 <= 0)
      return false;

   return close1 > priorHigh;
}

bool BearishEntryTrigger()
{
   double priorLow =
      RecentSwingLow(InpEntryTF, InpEntryLookback);

   double close1 = iClose(_Symbol, InpEntryTF, 1);

   if(priorLow <= 0 || close1 <= 0)
      return false;

   return close1 < priorLow;
}

//====================================================================
// TICK-VOLUME PROFILE
//====================================================================

// Calculates a simplified profile using closed candles.
// Each candle's tick volume is assigned to its typical-price bin.
// This is not centralized exchange volume or true intrabar volume-at-price.

bool CalculateProfile(ENUM_TIMEFRAMES timeframe,
                      int startShift,
                      int barCount,
                      double &poc,
                      double &vah,
                      double &val)
{
   poc = 0.0;
   vah = 0.0;
   val = 0.0;

   if(barCount < 5 || InpProfileBins < 5)
      return false;

   if(Bars(_Symbol, timeframe) < startShift + barCount + 2)
      return false;

   double highest = -DBL_MAX;
   double lowest  = DBL_MAX;

   for(int i = startShift; i < startShift + barCount; i++)
   {
      double h = iHigh(_Symbol, timeframe, i);
      double l = iLow(_Symbol, timeframe, i);

      if(h > highest) highest = h;
      if(l < lowest)  lowest = l;
   }

   if(highest <= lowest)
      return false;

   double binSize = (highest - lowest) / InpProfileBins;

   if(binSize <= 0)
      return false;

   double volumeBins[];
   ArrayResize(volumeBins, InpProfileBins);
   ArrayInitialize(volumeBins, 0.0);

   double totalVolume = 0.0;

   for(int i = startShift; i < startShift + barCount; i++)
   {
      double h = iHigh(_Symbol, timeframe, i);
      double l = iLow(_Symbol, timeframe, i);
      double c = iClose(_Symbol, timeframe, i);

      long tickVol = iVolume(_Symbol, timeframe, i);

      double typical = (h + l + c) / 3.0;

      int bin = (int)((typical - lowest) / binSize);

      if(bin < 0)
         bin = 0;

      if(bin >= InpProfileBins)
         bin = InpProfileBins - 1;

      volumeBins[bin] += (double)tickVol;
      totalVolume += (double)tickVol;
   }

   if(totalVolume <= 0)
      return false;

   int pocBin = 0;
   double maximumVolume = -1.0;

   for(int i = 0; i < InpProfileBins; i++)
   {
      if(volumeBins[i] > maximumVolume)
      {
         maximumVolume = volumeBins[i];
         pocBin = i;
      }
   }

   poc = lowest + (pocBin + 0.5) * binSize;

   // Expand the value area from the POC, adding the larger
   // adjacent volume bin until the target volume is reached.
   double targetVolume =
      totalVolume * InpValueAreaPercent / 100.0;

   double accumulated = volumeBins[pocBin];

   int lowBin = pocBin;
   int highBin = pocBin;

   while(accumulated < targetVolume &&
         (lowBin > 0 || highBin < InpProfileBins - 1))
   {
      double below = -1.0;
      double above = -1.0;

      if(lowBin > 0)
         below = volumeBins[lowBin - 1];

      if(highBin < InpProfileBins - 1)
         above = volumeBins[highBin + 1];

      if(above >= below && highBin < InpProfileBins - 1)
      {
         highBin++;
         accumulated += volumeBins[highBin];
      }
      else if(lowBin > 0)
      {
         lowBin--;
         accumulated += volumeBins[lowBin];
      }
      else
      {
         break;
      }
   }

   val = lowest + lowBin * binSize;
   vah = lowest + (highBin + 1) * binSize;

   return true;
}

//====================================================================
// SESSION PROFILE
//====================================================================

// Session times use broker server time.
// Overnight sessions are supported.
// The current unfinished candle is excluded.

bool CalculateSessionProfile(double &poc,
                             double &vah,
                             double &val)
{
   poc = 0.0;
   vah = 0.0;
   val = 0.0;

   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);

   MqlDateTime startTime = now;
   MqlDateTime endTime = now;

   if(InpSessionStartHour == InpSessionEndHour)
      return false;

   startTime.hour = InpSessionStartHour;
   startTime.min = 0;
   startTime.sec = 0;

   endTime.hour = InpSessionEndHour;
   endTime.min = 0;
   endTime.sec = 0;

   datetime start = StructToTime(startTime);
   datetime end = StructToTime(endTime);

   if(InpSessionEndHour < InpSessionStartHour)
   {
      // Overnight session: if current time is before the end,
      // the session began on the previous server day.
      if(now.hour < InpSessionEndHour)
         start -= 86400;
      else
         end += 86400;
   }

   datetime current = TimeCurrent();

   if(current < start)
      return false;

   if(current > end)
      end = current;

   MqlRates rates[];

   int copied = CopyRates(_Symbol, InpEntryTF,
                          start, end, rates);

   if(copied < 5)
      return false;

   // CopyRates places the oldest copied element first.
   // Ignore the newest bar if it is still forming.
   int usable = copied;

   if(usable > 0 &&
      rates[usable - 1].time >= iTime(_Symbol, InpEntryTF, 0))
      usable--;

   if(usable < 5)
      return false;

   double highest = -DBL_MAX;
   double lowest  = DBL_MAX;

   for(int i = 0; i < usable; i++)
   {
      if(rates[i].high > highest) highest = rates[i].high;
      if(rates[i].low  < lowest)  lowest = rates[i].low;
   }

   if(highest <= lowest)
      return false;

   double binSize = (highest - lowest) / InpProfileBins;

   if(binSize <= 0)
      return false;

   double bins[];
   ArrayResize(bins, InpProfileBins);
   ArrayInitialize(bins, 0.0);

   double total = 0.0;

   for(int i = 0; i < usable; i++)
   {
      double typical =
         (rates[i].high + rates[i].low + rates[i].close) / 3.0;

      int bin = (int)((typical - lowest) / binSize);

      if(bin < 0) bin = 0;
      if(bin >= InpProfileBins) bin = InpProfileBins - 1;

      bins[bin] += (double)rates[i].tick_volume;
      total += (double)rates[i].tick_volume;
   }

   if(total <= 0)
      return false;

   int pocBin = 0;
   double maximum = -1.0;

   for(int i = 0; i < InpProfileBins; i++)
   {
      if(bins[i] > maximum)
      {
         maximum = bins[i];
         pocBin = i;
      }
   }

   poc = lowest + (pocBin + 0.5) * binSize;

   double target = total * InpValueAreaPercent / 100.0;
   double accumulated = bins[pocBin];

   int lowBin = pocBin;
   int highBin = pocBin;

   while(accumulated < target &&
         (lowBin > 0 || highBin < InpProfileBins - 1))
   {
      double below = -1.0;
      double above = -1.0;

      if(lowBin > 0)
         below = bins[lowBin - 1];

      if(highBin < InpProfileBins - 1)
         above = bins[highBin + 1];

      if(above >= below && highBin < InpProfileBins - 1)
      {
         highBin++;
         accumulated += bins[highBin];
      }
      else if(lowBin > 0)
      {
         lowBin--;
         accumulated += bins[lowBin];
      }
      else
      {
         break;
      }
   }

   val = lowest + lowBin * binSize;
   vah = lowest + (highBin + 1) * binSize;

   return true;
}

//====================================================================
// VOLUME PROFILE FILTER
//====================================================================

bool VolumeProfileAllowsTrade(int direction)
{
   if(!InpUseVolumeProfile)
      return true;

   double sessionPOC, sessionVAH, sessionVAL;

   double fixedPOC, fixedVAH, fixedVAL;

   bool sessionOK =
      CalculateSessionProfile(sessionPOC,
                              sessionVAH,
                              sessionVAL);

   bool fixedOK =
      CalculateProfile(InpConfirmTF, 1,
                       InpFixedProfileBars,
                       fixedPOC, fixedVAH, fixedVAL);

   if(!sessionOK || !fixedOK)
   {
      Print("Volume Profile unavailable; entry skipped.");
      return false;
   }

   double price = iClose(_Symbol, InpEntryTF, 1);

   if(price <= 0)
      return false;

   Print("Session POC: ", sessionPOC,
         " | Fixed-range POC: ", fixedPOC,
         " | Price: ", price);

   // Initial profile rule:
   // BUY requires price above both POCs.
   // SELL requires price below both POCs.
   if(direction > 0)
      return (price > sessionPOC && price > fixedPOC);

   if(direction < 0)
      return (price < sessionPOC && price < fixedPOC);

   return false;
}

//====================================================================
// FINAL SIGNAL
//====================================================================

int GetTradingSignal()
{
   MarketBias bias = GetContextBias();

   if(bias == BIAS_NEUTRAL)
   {
      Print("No signal: M15 context is neutral.");
      return 0;
   }

   bool bullishSweep = BullishLiquiditySweep();
   bool bearishSweep = BearishLiquiditySweep();

   bool bullishShift = BullishStructureShift();
   bool bearishShift = BearishStructureShift();

   bool bullishEntry = BullishEntryTrigger();
   bool bearishEntry = BearishEntryTrigger();

   bool buySignal =
      (bias == BIAS_BULLISH &&
       bullishSweep &&
       bullishShift &&
       bullishEntry);

   bool sellSignal =
      (bias == BIAS_BEARISH &&
       bearishSweep &&
       bearishShift &&
       bearishEntry);

   if(buySignal && VolumeProfileAllowsTrade(1))
   {
      Print("BUY SIGNAL: context, sweep, structure, entry, profile.");
      return 1;
   }

   if(sellSignal && VolumeProfileAllowsTrade(-1))
   {
      Print("SELL SIGNAL: context, sweep, structure, entry, profile.");
      return -1;
   }

   return 0;
}

//====================================================================
// SIGNAL-ONLY MODE
//====================================================================

void EvaluateSignalOnly()
{
   int signal = GetTradingSignal();

   if(signal == 1)
      Print("BUY setup detected. No order sent: trading disabled.");

   if(signal == -1)
      Print("SELL setup detected. No order sent: trading disabled.");
}

//====================================================================
// STOP-LOSS AND TAKE-PROFIT
//====================================================================

bool CalculateStops(int direction,
                    double entry,
                    double &sl,
                    double &tp)
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   if(point <= 0 || entry <= 0)
      return false;

   double buffer = InpStopBufferPoints * point;

   if(direction > 0)
   {
      double sweepLow =
         iLow(_Symbol, InpConfirmTF, 1);

      if(sweepLow <= 0)
         return false;

      sl = sweepLow - buffer;

      if(sl >= entry)
         return false;

      tp = entry + (entry - sl) * InpRewardRiskRatio;
   }
   else
   {
      double sweepHigh =
         iHigh(_Symbol, InpConfirmTF, 1);

      if(sweepHigh <= 0)
         return false;

      sl = sweepHigh + buffer;

      if(sl <= entry)
         return false;

      tp = entry - (sl - entry) * InpRewardRiskRatio;
   }

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   return ValidateStopDistances(direction, entry, sl, tp);
}

//====================================================================
// STOP DISTANCE VALIDATION
//====================================================================

bool ValidateStopDistances(int direction,
                           double entry,
                           double sl,
                           double tp)
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   long stopsLevel =
      SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);

   double minimumDistance = stopsLevel * point;

   if(point <= 0)
      return false;

   if(direction > 0)
   {
      if(entry - sl < minimumDistance ||
         tp - entry < minimumDistance)
      {
         Print("Trade rejected: BUY stop/target too close.");
         return false;
      }
   }
   else
   {
      if(sl - entry < minimumDistance ||
         entry - tp < minimumDistance)
      {
         Print("Trade rejected: SELL stop/target too close.");
         return false;
      }
   }

   return true;
}

//====================================================================
// LOT SIZE AND RISK VALIDATION
//====================================================================

bool CheckRiskForFixedLot(int direction,
                          double entry,
                          double sl)
{
   double estimatedProfit = 0.0;

   ENUM_ORDER_TYPE orderType =
      (direction > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);

   if(!OrderCalcProfit(orderType,
                       _Symbol,
                       InpFixedLot,
                       entry,
                       sl,
                       estimatedProfit))
   {
      Print("Trade rejected: cannot calculate monetary risk. Error ",
            GetLastError());
      return false;
   }

   double estimatedLoss = MathAbs(estimatedProfit);

   Print("Estimated risk at ", InpFixedLot,
         " lots: ", estimatedLoss,
         " | Risk limit: ", initialRiskMoney);

   if(estimatedLoss > initialRiskMoney)
   {
      Print("Trade rejected: fixed lot exceeds risk limit.");
      return false;
   }

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(InpFixedLot < minLot ||
      InpFixedLot > maxLot ||
      lotStep <= 0)
   {
      Print("Trade rejected: fixed lot is invalid for this symbol.");
      return false;
   }

   double stepCount = InpFixedLot / lotStep;

   if(MathAbs(stepCount - MathRound(stepCount)) > 0.000001)
   {
      Print("Trade rejected: lot does not match volume step.");
      return false;
   }

   return true;
}

//====================================================================
// OPEN POSITION
//====================================================================

bool OpenPosition(int direction)
{
   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
   {
      Print("Cannot obtain current bid/ask.");
      return false;
   }

   double entry = (direction > 0 ? tick.ask : tick.bid);

   double sl = 0.0;
   double tp = 0.0;

   if(!CalculateStops(direction, entry, sl, tp))
   {
      Print("Trade rejected: invalid stop or target.");
      return false;
   }

   if(!CheckRiskForFixedLot(direction, entry, sl))
      return false;

   double margin = 0.0;

   ENUM_ORDER_TYPE orderType =
      (direction > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);

   if(!OrderCalcMargin(orderType, _Symbol,
                       InpFixedLot, entry, margin))
   {
      Print("Trade rejected: margin calculation failed.");
      return false;
   }

   if(AccountInfoDouble(ACCOUNT_MARGIN_FREE) < margin)
   {
      Print("Trade rejected: insufficient free margin.");
      return false;
   }

   bool sent = false;

   if(direction > 0)
   {
      sent = trade.Buy(InpFixedLot, _Symbol, 0.0,
                       sl, tp, "SMC BUY");
   }
   else
   {
      sent = trade.Sell(InpFixedLot, _Symbol, 0.0,
                        sl, tp, "SMC SELL");
   }

   uint retcode = trade.ResultRetcode();

   if(!sent ||
      (retcode != TRADE_RETCODE_DONE &&
       retcode != TRADE_RETCODE_PLACED &&
       retcode != TRADE_RETCODE_DONE_PARTIAL))
   {
      Print("Order failed: ", trade.ResultRetcodeDescription(),
            " | Retcode: ", retcode);
      return false;
   }

   tradesToday++;

   Print("ORDER ACCEPTED. Direction: ",
         (direction > 0 ? "BUY" : "SELL"),
         " | Volume: ", InpFixedLot,
         " | SL: ", sl,
         " | TP: ", tp);

   return true;
}

//====================================================================
// OPEN POSITION MANAGEMENT
//====================================================================

void ManageOpenPositions()
{
   if(!InpCloseOnOppositeSignal)
      return;

   if(!IsNewBar(InpConfirmTF, lastConfirmBar))
      return;

   bool bearish = BearishStructureShift();
   bool bullish = BullishStructureShift();

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) !=
         InpMagicNumber)
         continue;

      ENUM_POSITION_TYPE type =
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if(type == POSITION_TYPE_BUY && bearish)
      {
         if(trade.PositionClose(ticket))
            Print("BUY closed due to opposite structure.");
         else
            Print("BUY close failed: ",
                  trade.ResultRetcodeDescription());
      }

      if(type == POSITION_TYPE_SELL && bullish)
      {
         if(trade.PositionClose(ticket))
            Print("SELL closed due to opposite structure.");
         else
            Print("SELL close failed: ",
                  trade.ResultRetcodeDescription());
      }
   }
}

//====================================================================
// TRANSACTION LOGGING
//====================================================================

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      Print("Trade deal recorded. Deal ticket: ", trans.deal);
   }
}

//====================================================================
// END OF EA
//====================================================================