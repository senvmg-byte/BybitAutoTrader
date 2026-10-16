import 'dotenv/config';
import { createServer as createHttpServer } from 'node:http';
import { createServer as createHttpsServer } from 'node:https';
import { timingSafeEqual } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { TradingBot } from './bot.mjs';

const host = process.env.HOST || '127.0.0.1';
const port = Number(process.env.PORT || 8787);
const appToken = process.env.APP_TOKEN || '';
const localHosts = new Set(['127.0.0.1', '::1', 'localhost']);
const certificatePath = process.env.HTTPS_CERT_FILE || '';
const keyPath = process.env.HTTPS_KEY_FILE || '';

if (appToken.length < 32) {
  throw new Error('APP_TOKEN must contain at least 32 characters. Set a unique random value in backend/.env.');
}
if (!Number.isInteger(port) || port < 1 || port > 65535) {
  throw new Error('PORT must be a valid TCP port.');
}

const bot = new TradingBot();
await bot.initialize();
await bot.loadMarkets();

if ((certificatePath && !keyPath) || (!certificatePath && keyPath)) {
  throw new Error('HTTPS_CERT_FILE and HTTPS_KEY_FILE must be configured together.');
}
if (!localHosts.has(host) && !certificatePath) {
  throw new Error('Remote backend bindings require HTTPS certificate and key files.');
}

function send(response, status, body) {
  const payload = JSON.stringify(body);
  response.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(payload),
    'cache-control': 'no-store',
    'x-content-type-options': 'nosniff',
  });
  response.end(payload);
}

function authorized(request) {
  const provided = request.headers.authorization || '';
  const expected = ['Bear', 'er ', appToken].join('');
  const providedBytes = Buffer.from(provided);
  const expectedBytes = Buffer.from(expected);
  return providedBytes.length === expectedBytes.length && timingSafeEqual(providedBytes, expectedBytes);
}

async function readBody(request) {
  let text = '';
  for await (const chunk of request) {
    text += chunk;
    if (text.length > 16_384) throw new Error('Request body is too large.');
  }
  return text ? JSON.parse(text) : {};
}

const handler = async (request, response) => {
  try {
    const url = new URL(request.url || '/', `http://${request.headers.host || 'localhost'}`);
    if (request.method === 'GET' && url.pathname === '/health') {
      send(response, 200, { ok: true });
      return;
    }
    if (!authorized(request)) {
      send(response, 401, { error: 'Unauthorized.' });
      return;
    }
    if (request.method === 'GET' && url.pathname === '/api/status') {
      send(response, 200, bot.status());
      return;
    }
    if (request.method === 'GET' && url.pathname === '/api/markets') {
      const category = url.searchParams.get('category');
      const query = url.searchParams.get('q') || '';
      send(response, 200, { markets: bot.markets(category, query) });
      return;
    }
    if (request.method === 'GET' && url.pathname === '/api/market') {
      const category = url.searchParams.get('category');
      const symbol = url.searchParams.get('symbol');
      const strategy = url.searchParams.get('strategy');
      const direction = url.searchParams.get('direction');
      const maxOrderUsdt = url.searchParams.get('maxOrderUsdt');
      if (category || symbol || strategy || direction || maxOrderUsdt) {
        bot.setConfig({
          category: category || undefined,
          symbol: symbol || undefined,
          strategy: strategy || undefined,
          direction: direction || undefined,
          maxOrderUsdt: maxOrderUsdt || undefined,
        });
      }
      send(response, 200, await bot.fetchSnapshot());
      return;
    }
    if (request.method === 'POST' && url.pathname === '/api/config') {
      bot.setConfig(await readBody(request));
      send(response, 200, { ok: true, ...bot.status() });
      return;
    }
    if (request.method === 'POST' && url.pathname === '/api/start') {
      const body = await readBody(request);
      await bot.start(body.mode, body.confirmLive === true);
      send(response, 200, bot.status());
      return;
    }
    if (request.method === 'POST' && url.pathname === '/api/stop') {
      await bot.stop();
      send(response, 200, bot.status());
      return;
    }
    send(response, 404, { error: 'Not found.' });
  } catch (error) {
    const status = error instanceof SyntaxError ? 400 : 422;
    send(response, status, { error: error instanceof Error ? error.message : 'Request failed.' });
  }
};

const server = certificatePath
  ? createHttpsServer({
      cert: await readFile(certificatePath),
      key: await readFile(keyPath),
    }, handler)
  : createHttpServer(handler);

server.listen(port, host, () => {
  const scheme = certificatePath ? 'https' : 'http';
  console.log(`Bybit bot backend listening on ${scheme}://${host}:${port}`);
});

function shutdown() {
  void bot.stop().finally(() => server.close(() => process.exit(0)));
}

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
