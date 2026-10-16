import test from 'node:test';
import assert from 'node:assert/strict';
import { analyze, atr, ema, rsi, sizePosition, STRATEGY_PROFILES } from '../src/strategy.mjs';
import { categoryForMarket, selectEntrySide, supportedQuote, TradingBot } from '../src/bot.mjs';

const candles = (values) => values.map((close, index) => [
  index * 900_000,
  close,
  close + 1,
  close - 1,
  close,
  1,
]);

test('EMA uses a finite smoothed value', () => {
  assert.ok(Number.isFinite(ema([1, 2, 3, 4, 5], 3)));
});

test('RSI and ATR remain within expected numeric domains', () => {
  const series = candles(Array.from({ length: 40 }, (_, index) => 100 + index));
  assert.ok(rsi(series.map((candle) => candle[4])) <= 100);
  assert.ok(atr(series) > 0);
});

test('flat price series has neutral RSI', () => {
  assert.equal(rsi(Array.from({ length: 15 }, () => 100)), 50);
});

test('strategy waits for enough completed candles', () => {
  assert.equal(analyze(candles(Array.from({ length: 20 }, (_, index) => 100 + index))), null);
});

test('short-wave and long-wave use their selected Bybit candle intervals', () => {
  assert.equal(STRATEGY_PROFILES.short_wave.timeframe, '5m');
  assert.equal(STRATEGY_PROFILES.long_wave.timeframe, '4h');
  assert.equal(analyze(candles(Array.from({ length: 40 }, (_, index) => 100 + index)), 'long_wave'), null);
  const result = analyze(candles(Array.from({ length: 80 }, (_, index) => 100 + index)), 'long_wave');
  assert.equal(result?.fastPeriod, 20);
  assert.equal(result?.slowPeriod, 50);
});

test('entry direction respects long-only, short-only, and long-short mode', () => {
  assert.equal(selectEntrySide('long', 'linear', 'short'), null);
  assert.equal(selectEntrySide('short', 'linear', 'long'), null);
  assert.equal(selectEntrySide('short', 'linear', 'both'), 'short');
  assert.equal(selectEntrySide('short', 'spot', 'both'), null);
  assert.equal(selectEntrySide('long', 'spot', 'long'), 'long');
});

test('snapshot requests the selected long-wave timeframe and exposes stream metadata', async () => {
  const bot = new TradingBot({});
  const market = {
    symbol: 'BTC/USDT:USDT',
    id: 'BTCUSDT',
    base: 'BTC',
    quote: 'USDT',
    contract: true,
    linear: true,
    active: true,
  };
  bot.state = { position: null };
  bot.setConfig({
    category: 'linear',
    symbol: market.symbol,
    strategy: 'long_wave',
    direction: 'short',
  });
  bot.exchange = {
    markets: { [market.symbol]: market },
    loadMarkets: async function loadMarkets() { return this.markets; },
    market: () => market,
    fetchTicker: async () => ({ last: 100, percentage: 1 }),
    fetchOHLCV: async (symbol, timeframe, since, limit) => {
      assert.equal(symbol, market.symbol);
      assert.equal(timeframe, '4h');
      assert.equal(limit, 200);
      return candles(Array.from({ length: 80 }, (_, index) => 100 + index));
    },
  };

  const snapshot = await bot.fetchSnapshot();
  assert.equal(snapshot.timeframe, '4h');
  assert.equal(snapshot.streamCategory, 'linear');
  assert.equal(snapshot.streamSymbol, 'BTCUSDT');
  assert.equal(snapshot.candles.length, 80);
});

test('position sizing caps risk exposure', () => {
  const order = sizePosition({
    equity: 1_000,
    cash: 1_000,
    price: 100,
    atr: 1,
    maxOrder: 500,
  });
  assert.ok(order > 0 && order <= 200);
  assert.ok(order * (2 / 100) <= 10);
});

test('a bearish crossover produces a short signal when RSI confirms it', () => {
  let price = 100;
  const values = [price];
  for (let index = 0; index < 14; index++) {
    price += index % 2 === 0 ? 0.6 : -0.4;
    values.push(price);
  }
  for (let index = 0; index < 12; index++) {
    price += 0.2;
    values.push(price);
  }
  for (let index = 0; index < 8; index++) {
    price -= 0.3;
    values.push(price);
  }
  const result = analyze(candles(values));
  assert.equal(result?.signal, 'short');
});

test('invalid sizing inputs produce no order', () => {
  assert.equal(sizePosition({ equity: 0, cash: 1, price: 100, atr: 1, maxOrder: 5 }), 0);
});

test('Bybit market metadata maps all supported product categories', () => {
  assert.equal(categoryForMarket({ spot: true }), 'spot');
  assert.equal(categoryForMarket({ option: true, contract: true }), 'option');
  assert.equal(categoryForMarket({ contract: true, inverse: true }), 'inverse');
  assert.equal(categoryForMarket({ contract: true, linear: true }), 'linear');
});

test('market sizing is restricted to stable quotes or inverse USD contracts', () => {
  assert.equal(supportedQuote({ quote: 'USDT' }, 'spot'), true);
  assert.equal(supportedQuote({ quote: 'BTC' }, 'spot'), false);
  assert.equal(supportedQuote({ quote: 'USD' }, 'inverse'), true);
  assert.equal(supportedQuote({ quote: 'USDT' }, 'inverse'), false);
});

test('configuration updates are atomic when validation fails', () => {
  const bot = new TradingBot({});
  assert.throws(
    () => bot.setConfig({ category: 'linear', symbol: 'BTC/USDT:USDT', maxOrderUsdt: 0 }),
    /between 5 and 1000/,
  );
  assert.throws(
    () => bot.setConfig({ category: 'spot', direction: 'short' }),
    /only for Linear and Inverse/,
  );
  assert.throws(
    () => bot.setConfig({ category: 'linear', strategy: 'unknown' }),
    /short_wave or long_wave/,
  );
  assert.equal(bot.config.category, 'spot');
  assert.equal(bot.config.symbol, 'BTC/USDT');
});

test('paper trading stops when equity reaches the 10% peak drawdown limit', async () => {
  const bot = new TradingBot({});
  bot.exchange = {
    market: () => ({ symbol: 'BTC/USDT', spot: true, quote: 'USDT' }),
  };
  bot.state = { paperCash: 899, peakEquity: 1_000, position: null };
  bot.stop = async () => { bot.running = false; };

  await assert.rejects(
    bot.managePosition({ analysis: {}, price: 100 }),
    /10% peak-to-equity drawdown limit/,
  );
  assert.equal(bot.running, false);
});
