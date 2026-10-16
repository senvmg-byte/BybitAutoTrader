export function ema(values, period) {
  if (values.length < period || period < 1) return null;
  const alpha = 2 / (period + 1);
  return values.slice(1).reduce((current, value) => alpha * value + (1 - alpha) * current, values[0]);
}

export function rsi(closes, period = 14) {
  if (closes.length < period + 1) return null;
  const changes = closes.slice(1).slice(-period).map((value, index) => value - closes.slice(0, -1).slice(-period)[index]);
  const gains = changes.reduce((sum, change) => sum + Math.max(change, 0), 0) / period;
  const losses = changes.reduce((sum, change) => sum + Math.max(-change, 0), 0) / period;
  if (gains === 0 && losses === 0) return 50;
  if (losses === 0) return 100;
  return 100 - 100 / (1 + gains / losses);
}

export function atr(candles, period = 14) {
  if (candles.length < period + 1) return null;
  const ranges = candles.slice(1).map((candle, index) => {
    const previousClose = candles[index][4];
    return Math.max(
      candle[2] - candle[3],
      Math.abs(candle[2] - previousClose),
      Math.abs(candle[3] - previousClose),
    );
  }).slice(-period);
  return ranges.reduce((sum, range) => sum + range, 0) / period;
}

export const STRATEGY_PROFILES = {
  short_wave: { timeframe: '5m', fastPeriod: 9, slowPeriod: 21 },
  long_wave: { timeframe: '4h', fastPeriod: 20, slowPeriod: 50 },
};

export function analyze(candles, strategy = 'short_wave') {
  const profile = STRATEGY_PROFILES[strategy];
  if (!profile) throw new Error('Unknown trading strategy.');
  if (candles.length < profile.slowPeriod + 2) return null;
  const closes = candles.map((candle) => candle[4]);
  if (candles.some((candle) =>
    !Number.isFinite(candle[0]) ||
    !Number.isFinite(candle[2]) ||
    !Number.isFinite(candle[3]) ||
    !Number.isFinite(candle[4]) ||
    candle[2] < candle[3] ||
    candle[4] <= 0)) return null;

  const { fastPeriod, slowPeriod } = profile;
  const fast = ema(closes, fastPeriod);
  const slow = ema(closes, slowPeriod);
  const previousFast = ema(closes.slice(0, -1), fastPeriod);
  const previousSlow = ema(closes.slice(0, -1), slowPeriod);
  const relativeStrength = rsi(closes);
  const averageTrueRange = atr(candles);
  const crossedUp = previousFast <= previousSlow && fast > slow;
  const crossedDown = previousFast >= previousSlow && fast < slow;
  let signal = 'hold';
  if (crossedUp && relativeStrength >= 45 && relativeStrength <= 68) signal = 'long';
  else if (crossedDown && relativeStrength >= 32 && relativeStrength <= 55) signal = 'short';
  else if (crossedDown || relativeStrength >= 75) signal = 'exit_long';
  else if (crossedUp || relativeStrength <= 25) signal = 'exit_short';

  return {
    signal,
    price: closes.at(-1),
    fastEma: fast,
    slowEma: slow,
    fastPeriod,
    slowPeriod,
    rsi: relativeStrength,
    atr: averageTrueRange,
    candleTimestamp: candles.at(-1)[0],
    reason: signal === 'long'
      ? `EMA ${fastPeriod} crossed above EMA ${slowPeriod}; RSI confirms bullish momentum.`
      : signal === 'short'
        ? `EMA ${fastPeriod} crossed below EMA ${slowPeriod}; RSI confirms bearish momentum.`
        : signal === 'exit_long'
          ? crossedDown ? 'Bearish crossover; close long exposure.' : 'RSI is overbought; close long exposure.'
          : signal === 'exit_short'
            ? crossedUp ? 'Bullish crossover; close short exposure.' : 'RSI is oversold; close short exposure.'
            : 'No qualifying crossover.'
  };
}

export function sizePosition({ equity, cash, price, atr: averageTrueRange, maxOrder }) {
  if (![equity, cash, price, averageTrueRange, maxOrder].every(Number.isFinite) ||
      equity <= 0 || cash <= 0 || price <= 0 || maxOrder <= 0) return 0;
  const stopDistance = Math.max(2 * averageTrueRange, price * 0.01);
  const riskBudget = equity * 0.01;
  return Math.max(0, Math.min(maxOrder, equity * 0.2, riskBudget / (stopDistance / price), cash));
}
