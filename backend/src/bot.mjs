import ccxt from 'ccxt';
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { analyze, sizePosition, STRATEGY_PROFILES } from './strategy.mjs';

const STATE_PATH = fileURLToPath(new URL('../data/bot-state.json', import.meta.url));
const FEE_RATE = 0.001;
const SLIPPAGE_RATE = 0.0005;
const MAX_DRAWDOWN = 0.1;
const INTERVAL_MS = 60_000;
const CATEGORIES = ['spot', 'linear', 'inverse', 'option'];

function categoryForMarket(market) {
  if (market.spot) return 'spot';
  if (market.option || market.type === 'option') return 'option';
  if (market.contract && market.inverse) return 'inverse';
  if (market.contract && (market.linear || market.swap || market.future)) return 'linear';
  return null;
}

function supportedQuote(market, category) {
  if (category === 'inverse') return market.quote === 'USD';
  return market.quote === 'USDT' || market.quote === 'USDC';
}

function unitNotional(market, price) {
  const contractSize = Number(market.contractSize) || 1;
  if (market.inverse) return contractSize;
  return market.contract ? contractSize * price : price;
}

function positionPnl(position, market, markPrice) {
  const size = position.quantity * (Number(market.contractSize) || 1);
  if (market.inverse) {
    const direction = position.side === 'long' ? 1 : -1;
    return direction * size * (markPrice / position.entryPrice - 1);
  }
  const direction = position.side === 'long' ? 1 : -1;
  return direction * size * (markPrice - position.entryPrice);
}

export function selectEntrySide(signal, category, direction) {
  const supportsShort = category === 'linear' || category === 'inverse';
  if (signal === 'long' && direction !== 'short') return 'long';
  if (signal === 'short' && supportsShort && direction !== 'long') return 'short';
  return null;
}

export class TradingBot {
  constructor(env = process.env) {
    this.env = env;
    this.exchange = new ccxt.bybit({
      apiKey: env.BYBIT_API_KEY || undefined,
      secret: env.BYBIT_API_SECRET || undefined,
      enableRateLimit: true,
      options: { defaultType: 'spot' },
    });
    this.config = {
      category: 'spot',
      symbol: env.SYMBOL || 'BTC/USDT',
      maxOrderUsdt: Number(env.MAX_ORDER_USDT || 25),
      strategy: 'short_wave',
      direction: 'long',
    };
    this.mode = 'paper';
    this.running = false;
    this.timer = null;
    this.inFlight = false;
    this.tickPromise = null;
    this.lastError = null;
    this.snapshot = null;
    this.state = null;
  }

  async initialize() {
    try {
      this.state = JSON.parse(await readFile(STATE_PATH, 'utf8'));
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
      const startingCash = Number(this.env.PAPER_STARTING_USDT || 1000);
      if (!Number.isFinite(startingCash) || startingCash <= 0) {
        throw new Error('PAPER_STARTING_USDT must be a positive number.');
      }
      this.state = {
        paperCash: startingCash,
        position: null,
        peakEquity: startingCash,
        lastProcessedCandle: 0,
        trades: [],
      };
      await this.persist();
    }
    this.state.position ??= null;
    this.state.lastProcessedCandle ??= 0;
    this.state.trades ??= [];
    if (this.state.position) {
      this.config.category = this.state.position.category;
      this.config.symbol = this.state.position.symbol;
      this.config.strategy = this.state.position.strategy || this.config.strategy;
      this.config.direction = this.state.position.direction || this.config.direction;
      this.mode = this.state.position.mode;
    }
  }

  async persist() {
    await mkdir(dirname(STATE_PATH), { recursive: true });
    const temporaryPath = `${STATE_PATH}.tmp`;
    await writeFile(temporaryPath, JSON.stringify(this.state, null, 2), { mode: 0o600 });
    await rename(temporaryPath, STATE_PATH);
  }

  async loadMarkets() {
    await this.exchange.loadMarkets();
    return this.exchange.markets;
  }

  markets(category, query = '') {
    if (!CATEGORIES.includes(category)) throw new Error('Unknown Bybit product category.');
    return Object.values(this.exchange.markets)
      .filter((market) =>
        categoryForMarket(market) === category &&
        supportedQuote(market, category) &&
        market.active !== false &&
        (!market.expiry || market.expiry > Date.now() + 24 * 60 * 60 * 1000))
      .filter((market) => market.symbol.toLowerCase().includes(query.toLowerCase()))
      .sort((left, right) => left.symbol.localeCompare(right.symbol))
      .slice(0, 100)
      .map((market) => ({
        symbol: market.symbol,
        base: market.base,
        quote: market.quote,
        settle: market.settle || null,
        expiry: market.expiry || null,
        contractSize: market.contractSize || null,
      }));
  }

  setConfig({ category, symbol, maxOrderUsdt, strategy, direction }) {
    const nextCategory = category ?? this.config.category;
    const nextSymbol = symbol ?? this.config.symbol;
    const nextOrderSize = maxOrderUsdt === undefined ? this.config.maxOrderUsdt : Number(maxOrderUsdt);
    const nextStrategy = strategy ?? this.config.strategy;
    const nextDirection = direction ?? this.config.direction;
    if (!CATEGORIES.includes(nextCategory)) {
      throw new Error('Category must be spot, linear, inverse, or option.');
    }
    if (typeof nextSymbol !== 'string' || nextSymbol.length < 3 || nextSymbol.length > 80) {
      throw new Error('Enter a valid CCXT unified symbol.');
    }
    if (!Number.isFinite(nextOrderSize) || nextOrderSize < 5 || nextOrderSize > 1000) {
      throw new Error('Order size must be between 5 and 1000 USDT.');
    }
    if (!Object.hasOwn(STRATEGY_PROFILES, nextStrategy)) {
      throw new Error('Strategy must be short_wave or long_wave.');
    }
    if (!['long', 'short', 'both'].includes(nextDirection)) {
      throw new Error('Direction must be long, short, or both.');
    }
    if (nextDirection === 'short' && !['linear', 'inverse'].includes(nextCategory)) {
      throw new Error('Short-only mode is available only for Linear and Inverse markets.');
    }
    if (nextDirection === 'both' && !['linear', 'inverse'].includes(nextCategory)) {
      throw new Error('Long + Short mode is available only for Linear and Inverse markets.');
    }
    if (this.running &&
        (nextCategory !== this.config.category ||
          nextSymbol !== this.config.symbol ||
          nextOrderSize !== this.config.maxOrderUsdt ||
          nextStrategy !== this.config.strategy ||
          nextDirection !== this.config.direction)) {
      throw new Error('Stop the bot before changing its configuration.');
    }
    if (this.state?.position &&
        (nextCategory !== this.state.position.category || nextSymbol !== this.state.position.symbol)) {
      throw new Error('Close the existing bot position before changing its market or category.');
    }
    if (this.state?.position &&
        (nextStrategy !== this.config.strategy || nextDirection !== this.config.direction)) {
      throw new Error('Close the existing bot position before changing strategy or direction.');
    }
    if (nextCategory !== this.config.category ||
        nextSymbol !== this.config.symbol ||
        nextStrategy !== this.config.strategy) {
      this.snapshot = null;
    }
    this.config = {
      category: nextCategory,
      symbol: nextSymbol,
      maxOrderUsdt: nextOrderSize,
      strategy: nextStrategy,
      direction: nextDirection,
    };
  }

  validateConfiguredMarket() {
    const market = this.exchange.market(this.config.symbol);
    if (!market ||
        categoryForMarket(market) !== this.config.category ||
        !supportedQuote(market, this.config.category) ||
        market.active === false ||
        (market.expiry && market.expiry <= Date.now() + 24 * 60 * 60 * 1000)) {
      throw new Error(`The selected symbol is not a Bybit ${this.config.category} market.`);
    }
    if (this.state.position && (
      this.state.position.symbol !== market.symbol ||
      this.state.position.category !== this.config.category
    )) {
      throw new Error('Close the existing bot position before changing its market or category.');
    }
    return market;
  }

  async fetchSnapshot() {
    await this.loadMarkets();
    const market = this.validateConfiguredMarket();
    const candleMarket = this.config.category === 'option'
      ? this.exchange.markets[`${market.base}/${market.quote}`] ||
        this.exchange.markets[`${market.base}/USDT`]
      : market;
    if (!candleMarket) {
      throw new Error(`No spot market is available for the ${market.base} option underlying.`);
    }
    const [ticker, candles] = await Promise.all([
      this.exchange.fetchTicker(market.symbol),
      this.exchange.fetchOHLCV(
        candleMarket.symbol,
        STRATEGY_PROFILES[this.config.strategy].timeframe,
        undefined,
        200,
      ),
    ]);
    const completedCandles = candles.slice(0, -1);
    const analysis = analyze(completedCandles, this.config.strategy);
    let price = ticker.last;
    if (this.config.category === 'option') {
      const bid = Number(ticker.bid);
      const ask = Number(ticker.ask);
      const midpoint = (bid + ask) / 2;
      const markPrice = Number(ticker.info?.markPrice);
      if (!Number.isFinite(bid) || !Number.isFinite(ask) || bid <= 0 || ask < bid ||
          (ask - bid) / midpoint > 0.2) {
        throw new Error('Option market has no usable two-sided quote or its spread exceeds 20%.');
      }
      price = this.state.position?.symbol === market.symbol ? bid : ask;
      if (!Number.isFinite(price) || price <= 0) price = markPrice || midpoint;
    }
    if (!analysis || !Number.isFinite(price) || price <= 0) {
      throw new Error('Not enough valid market data for the strategy.');
    }
    this.snapshot = {
      category: this.config.category,
      symbol: market.symbol,
      strategy: this.config.strategy,
      direction: this.config.direction,
      timeframe: STRATEGY_PROFILES[this.config.strategy].timeframe,
      streamCategory: categoryForMarket(candleMarket),
      streamSymbol: candleMarket.id,
      candles,
      price,
      analysisSourceSymbol: candleMarket.symbol,
      changePercent: ticker.percentage,
      analysis,
      updatedAt: new Date().toISOString(),
    };
    return this.snapshot;
  }

  status() {
    const position = this.state?.position || null;
    const paperPosition = this.mode === 'paper' ? position : null;
    const market = paperPosition ? this.exchange.markets[paperPosition.symbol] : null;
    const currentValue = paperPosition && market && this.snapshot
      ? paperPosition.costQuote + positionPnl(paperPosition, market, this.snapshot.price)
      : paperPosition?.costQuote || 0;
    return {
      mode: this.mode,
      running: this.running,
      category: this.config.category,
      symbol: this.config.symbol,
      maxOrderUsdt: this.config.maxOrderUsdt,
      strategy: this.config.strategy,
      direction: this.config.direction,
      timeframe: STRATEGY_PROFILES[this.config.strategy].timeframe,
      price: this.snapshot?.price || null,
      changePercent: this.snapshot?.changePercent ?? null,
      analysisSourceSymbol: this.snapshot?.analysisSourceSymbol || null,
      analysis: this.snapshot?.analysis || null,
      position: position && position.category === this.config.category
        ? {
            side: position.side,
            category: position.category,
            symbol: position.symbol,
            quantity: position.quantity,
            entryPrice: position.entryPrice,
            stopPrice: position.stopPrice,
            pending: position.pending === true,
          }
        : null,
      paper: this.mode === 'paper'
        ? {
            cash: this.state.paperCash,
            equity: this.state.paperCash + currentValue,
            quantity: paperPosition?.quantity || 0,
          }
        : null,
      lastError: this.lastError,
      updatedAt: this.snapshot?.updatedAt || null,
      trades: (this.state?.trades || []).slice(-10).reverse(),
    };
  }

  async start(mode, confirmLive = false) {
    if (this.running) throw new Error('The bot is already running.');
    if (!['paper', 'live'].includes(mode)) throw new Error('Mode must be paper or live.');
    await this.loadMarkets();
    const market = this.validateConfiguredMarket();
    if (this.state.position?.pending) {
      throw new Error('A live order has an unconfirmed result. Verify it on Bybit before restarting the bot.');
    }
    if (this.state.position && this.state.position.mode !== mode) {
      throw new Error('A position from the other mode is still open. Close it before switching modes.');
    }
    if (mode === 'live') {
      const liveFlag = `LIVE_${this.config.category.toUpperCase()}_ENABLED`;
      if (this.env[liveFlag] !== 'true') {
        throw new Error(`Live ${this.config.category} trading is locked. Set ${liveFlag}=true on the backend first.`);
      }
      if (!confirmLive) throw new Error('Explicit live-trading confirmation is required.');
      if (!this.env.BYBIT_API_KEY || !this.env.BYBIT_API_SECRET) {
        throw new Error('The backend is missing Bybit API credentials.');
      }
      if (this.config.category === 'linear' || this.config.category === 'inverse') {
        try {
          await this.exchange.setMarginMode('isolated', market.symbol);
        } catch (error) {
          const message = String(error.message).toLowerCase();
          if (!message.includes('margin mode is not modified') &&
              !message.includes('margin mode has not been modified')) throw error;
        }
        try {
          await this.exchange.setLeverage(1, market.symbol);
        } catch (error) {
          if (!String(error.message).toLowerCase().includes('leverage not modified')) throw error;
        }
      }
    }
    this.mode = mode;
    this.running = true;
    this.lastError = null;
    this.schedule(0);
  }

  async stop() {
    this.running = false;
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    if (this.tickPromise) await this.tickPromise;
  }

  schedule(delay = INTERVAL_MS) {
    if (!this.running) return;
    this.timer = setTimeout(async () => {
      const activeTick = this.tick();
      this.tickPromise = activeTick;
      await activeTick;
      if (this.tickPromise === activeTick) this.tickPromise = null;
      this.schedule();
    }, delay);
  }

  async tick() {
    if (this.inFlight || !this.running) return;
    this.inFlight = true;
    try {
      const snapshot = await this.fetchSnapshot();
      await this.managePosition(snapshot);
      this.lastError = null;
    } catch (error) {
      this.lastError = error instanceof Error ? error.message : 'Unknown trading error.';
    } finally {
      this.inFlight = false;
    }
  }

  async managePosition(snapshot) {
    const market = this.validateConfiguredMarket();
    const { analysis, price } = snapshot;
    let position = this.state.position;
    if (position?.pending) {
      throw new Error('A live order result is unconfirmed. Verify open orders and positions on Bybit.');
    }
    position = await this.reconcileProtectiveStop(position, market);
    if (this.mode === 'paper') {
      const equity = this.state.paperCash +
        (position
          ? position.costQuote + positionPnl(position, market, price)
          : 0);
      if (equity > this.state.peakEquity) {
        this.state.peakEquity = equity;
        await this.persist();
      }
      if (equity <= this.state.peakEquity * (1 - MAX_DRAWDOWN)) {
        if (position) {
          await this.closePosition(position, market, price, 'Paper account drawdown limit.');
        }
        void this.stop();
        throw new Error('Paper trading stopped at the 10% peak-to-equity drawdown limit.');
      }
    }
    if (!position) return;
    const isLong = position?.side === 'long';
    const isShort = position?.side === 'short';
    const shouldClose = (isLong && (analysis.signal === 'exit_long' || analysis.signal === 'short' || price <= position.stopPrice)) ||
      (isShort && (analysis.signal === 'exit_short' || analysis.signal === 'long' || price >= position.stopPrice));

    if (shouldClose) {
      await this.closePosition(position, market, price, analysis.reason);
      return;
    }
    if (position || analysis.candleTimestamp <= this.state.lastProcessedCandle) return;

    const side = selectEntrySide(
      analysis.signal,
      this.config.category,
      this.config.direction,
    );
    if (!side) return;

    this.state.lastProcessedCandle = analysis.candleTimestamp;
    await this.persist();
    const markEquity = this.state.paperCash + (position ? position.costQuote : 0);
    if (this.mode === 'paper' && markEquity <= this.state.peakEquity * (1 - MAX_DRAWDOWN)) {
      void this.stop();
      throw new Error('Paper trading stopped at the 10% drawdown limit.');
    }
    const equity = this.mode === 'paper'
      ? Math.max(markEquity, this.state.peakEquity * (1 - MAX_DRAWDOWN))
      : this.config.maxOrderUsdt * 5;
    const cash = this.mode === 'paper' ? this.state.paperCash : this.config.maxOrderUsdt;
    const quoteAmount = sizePosition({
      equity,
      cash,
      price,
      atr: this.config.category === 'option' ? 0 : analysis.atr,
      maxOrder: this.config.maxOrderUsdt,
    });
    if (quoteAmount < 5) throw new Error('Risk limits leave less than 5 USDT available for this order.');

    const unitCost = unitNotional(market, price);
    const rawAmount = quoteAmount / unitCost;
    const amount = Number(this.exchange.amountToPrecision(market.symbol, rawAmount));
    if (!Number.isFinite(amount) || amount <= 0) throw new Error('Calculated contract amount is invalid.');
    const notional = amount * unitCost;
    const minimumAmount = Number(market.limits?.amount?.min) || 0;
    const minimumCost = Number(market.limits?.cost?.min) || 0;
    if (amount < minimumAmount || notional < minimumCost) {
      throw new Error('Order is below the exchange minimum amount or cost.');
    }
    if (notional > this.config.maxOrderUsdt * 1.001) {
      throw new Error('Exchange quantity precision would exceed the configured order limit.');
    }

    const entryPrice = price * (side === 'long' ? 1 + SLIPPAGE_RATE : 1 - SLIPPAGE_RATE);
    const stopDistance = this.config.category === 'option'
      ? price * 0.5
      : Math.max(2 * analysis.atr, price * 0.01);
    const stopPrice = side === 'long' ? entryPrice - stopDistance : entryPrice + stopDistance;
    const positionCost = amount * unitNotional(market, entryPrice);
    const newPosition = {
      mode: this.mode,
      category: this.config.category,
      symbol: market.symbol,
      strategy: this.config.strategy,
      direction: this.config.direction,
      side,
      quantity: amount,
      entryPrice,
      stopPrice,
      costQuote: positionCost,
      openedAt: new Date().toISOString(),
      stopOrderId: null,
      pending: this.mode === 'live',
    };

    if (this.mode === 'paper') {
      this.state.paperCash -= positionCost * (1 + FEE_RATE);
      this.state.peakEquity = Math.max(this.state.peakEquity, this.state.paperCash + positionCost);
    }
    this.state.position = newPosition;
    await this.persist();
    if (this.mode === 'live') {
      const orderSide = side === 'long' ? 'buy' : 'sell';
      const orderLinkId = `ba-${this.config.category}-${analysis.candleTimestamp}`;
      try {
        const order = await this.submitMarketOrder(
          market,
          orderSide,
          amount,
          { ...this.orderParams(market, false), orderLinkId },
        );
        newPosition.quantity = order.filled;
        newPosition.entryPrice = order.average || price;
        newPosition.stopPrice = side === 'long'
          ? newPosition.entryPrice - stopDistance
          : newPosition.entryPrice + stopDistance;
        newPosition.costQuote = order.filled * unitNotional(market, newPosition.entryPrice);
        newPosition.pending = false;
        await this.persist();
        await this.installExchangeStop(newPosition, market);
      } catch (error) {
        if (error.message.includes('emergency close was submitted')) {
          this.state.position = null;
        } else if (!newPosition.pending) {
          newPosition.pending = true;
        }
        await this.persist();
        if (newPosition.pending) {
          throw new Error(
            `Live order or protective-stop status needs manual verification before resuming: ${error.message}`,
          );
        }
        throw error;
      }
    }
    this.recordTrade(side === 'long' ? 'buy' : 'short', newPosition.entryPrice, newPosition.quantity, analysis.reason);
    await this.persist();
  }

  async submitMarketOrder(market, side, amount, params) {
    const order = await this.exchange.createOrder(
      market.symbol,
      'market',
      side,
      amount,
      undefined,
      params,
    );
    let confirmed = order;
    if (!(Number(confirmed.filled) > 0) && confirmed.id) {
      await new Promise((resolveDelay) => setTimeout(resolveDelay, 250));
      confirmed = await this.exchange.fetchOrder(confirmed.id, market.symbol);
    }
    const filled = Number(confirmed.filled) ||
      (confirmed.status === 'closed' ? Number(confirmed.amount) : 0);
    if (!Number.isFinite(filled) || filled <= 0) {
      throw new Error('The exchange did not confirm a market-order fill.');
    }
    return { filled, average: Number(confirmed.average) || null };
  }

  orderParams(market, reduceOnly) {
    if (this.config.category === 'spot') return { marketUnit: 'baseCoin' };
    if (this.config.category === 'option') return {};
    const params = { positionIdx: 0 };
    if (reduceOnly) params.reduceOnly = true;
    return params;
  }

  async reconcileProtectiveStop(position, market) {
    if (this.mode !== 'live' || !position?.stopOrderId) return position;
    const order = await this.exchange.fetchOrder(position.stopOrderId, market.symbol);
    const filled = Number(order.filled) ||
      (order.status === 'closed' ? Number(order.amount) : 0);
    if (filled >= position.quantity && filled > 0) {
      this.recordTrade(
        position.side === 'long' ? 'stop' : 'cover',
        Number(order.average) || this.snapshot.price,
        position.quantity,
        'Exchange protective stop filled.',
      );
      this.state.position = null;
      await this.persist();
      return null;
    }
    if (filled > 0) {
      const remainingFraction = (position.quantity - filled) / position.quantity;
      position.quantity -= filled;
      position.costQuote *= remainingFraction;
    }
    if (order.status === 'closed' || order.status === 'canceled' || order.status === 'rejected') {
      position.stopOrderId = null;
      position.pending = true;
      await this.persist();
      try {
        await this.installExchangeStop(position, market);
        position.pending = false;
        await this.persist();
      } catch (error) {
        if (error.message.includes('emergency close was submitted')) {
          this.state.position = null;
        }
        await this.persist();
        throw error;
      }
    }
    return position;
  }

  async installExchangeStop(position, market) {
    if (this.config.category === 'option') return;
    const side = position.side === 'long' ? 'sell' : 'buy';
    const params = {
      triggerPrice: this.exchange.priceToPrecision(market.symbol, position.stopPrice),
      triggerDirection: position.side === 'long' ? 2 : 1,
      triggerBy: this.config.category === 'spot' ? 'LastPrice' : 'MarkPrice',
      ...this.orderParams(market, true),
    };
    try {
      const order = await this.exchange.createOrder(
        market.symbol,
        'market',
        side,
        position.quantity,
        undefined,
        params,
      );
      if (!order.id) throw new Error('The exchange did not confirm the protective stop order id.');
      position.stopOrderId = order.id || null;
    } catch (error) {
      const closeParams = this.orderParams(market, true);
      try {
        const emergencyClose = await this.submitMarketOrder(
          market,
          side,
          position.quantity,
          closeParams,
        );
        if (emergencyClose.filled < position.quantity) {
          throw new Error('Emergency close only partially filled.');
        }
      } catch (closeError) {
        throw new Error(
          `Exchange stop placement failed (${error.message}); emergency close also failed (${closeError.message}). Verify the position in Bybit immediately.`,
        );
      }
      throw new Error(`Exchange stop placement failed; emergency close was submitted. Verify the position in Bybit: ${error.message}`);
    }
  }

  async closePosition(position, market, price, reason) {
    let amount;
    if (this.mode === 'live') {
      if (position.stopOrderId) {
        position.pending = true;
        await this.persist();
        try {
          await this.exchange.cancelOrder(position.stopOrderId, market.symbol);
        } catch (error) {
          let stopOrder;
          try {
            stopOrder = await this.exchange.fetchOrder(position.stopOrderId, market.symbol);
          } catch (lookupError) {
            await this.persist();
            throw new Error(
              `Could not confirm protective-stop status (${error.message}; ${lookupError.message}). Verify Bybit before resuming.`,
            );
          }
          const stopFilled = Number(stopOrder.filled) ||
            (stopOrder.status === 'closed' ? Number(stopOrder.amount) : 0);
          if (stopOrder.status === 'closed' && stopFilled >= position.quantity) {
            this.recordTrade(
              position.side === 'long' ? 'stop' : 'cover',
              price,
              position.quantity,
              'Exchange protective stop filled.',
            );
            this.state.position = null;
            await this.persist();
            return;
          }
          if (stopFilled > 0) {
            const remainingFraction = (position.quantity - stopFilled) / position.quantity;
            position.quantity -= stopFilled;
            position.costQuote *= remainingFraction;
          }
          if (stopOrder.status !== 'canceled' && stopOrder.status !== 'rejected' &&
              stopOrder.status !== 'closed') {
            await this.persist();
            throw new Error(
              `Protective-stop cancellation is uncertain (${error.message}). Verify Bybit before resuming.`,
            );
          }
        }
        position.stopOrderId = null;
        await this.persist();
      }
      position.pending = true;
      await this.persist();
      amount = Number(this.exchange.amountToPrecision(market.symbol, position.quantity));
      const side = position.side === 'long' ? 'sell' : 'buy';
      let order;
      try {
        order = await this.submitMarketOrder(
          market,
          side,
          amount,
          this.orderParams(market, true),
        );
      } catch (error) {
        await this.persist();
        throw new Error(`Close-order outcome is unconfirmed. Verify Bybit before resuming: ${error.message}`);
      }
      position.pending = false;
      if (order.filled < position.quantity) {
        const remainingFraction = (position.quantity - order.filled) / position.quantity;
        position.quantity -= order.filled;
        position.costQuote *= remainingFraction;
        position.stopOrderId = null;
        try {
          await this.installExchangeStop(position, market);
        } catch (error) {
          position.pending = !error.message.includes('emergency close was submitted');
          if (!position.pending) this.state.position = null;
          await this.persist();
          throw error;
        }
        this.recordTrade(position.side === 'long' ? 'sell' : 'cover', price, order.filled, reason);
        await this.persist();
        return;
      }
    } else {
      amount = position.quantity;
      const exitPrice = price * (position.side === 'long' ? 1 - SLIPPAGE_RATE : 1 + SLIPPAGE_RATE);
      const pnl = positionPnl(position, market, exitPrice);
      const exitFee = position.quantity * unitNotional(market, exitPrice) * FEE_RATE;
      this.state.paperCash += position.costQuote + pnl - exitFee;
    }
    this.recordTrade(position.side === 'long' ? 'sell' : 'cover', price, amount, reason);
    this.state.position = null;
    await this.persist();
  }

  recordTrade(side, price, quantity, reason) {
    this.state.trades.push({
      side,
      category: this.config.category,
      symbol: this.config.symbol,
      price,
      quantity,
      reason,
      at: new Date().toISOString(),
      mode: this.mode,
    });
    this.state.trades = this.state.trades.slice(-100);
  }
}

export { CATEGORIES, categoryForMarket, supportedQuote };
