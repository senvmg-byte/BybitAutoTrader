import 'dart:convert';

import 'package:bybit_auto_trader/bybit_ccxt_adapter.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'fetchBalance signs and normalizes a private Bybit V5 request',
    () async {
      late http.Request captured;
      final exchange = BybitCcxtAdapter(
        apiKey: 'test-key',
        apiSecret: 'test-secret',
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'retCode': 0,
              'time': 123,
              'result': {
                'list': [
                  {
                    'accountType': 'UNIFIED',
                    'totalEquity': '125',
                    'totalWalletBalance': '120',
                    'totalAvailableBalance': '95',
                    'coin': [
                      {
                        'coin': 'USDT',
                        'walletBalance': '100',
                        'locked': '2',
                        'usdValue': '100',
                        'borrowAmount': '3',
                        'accruedInterest': '0.1',
                      },
                    ],
                  },
                ],
              },
            }),
            200,
          );
        }),
      );

      final balance = await exchange.fetchBalance();
      final timestamp = captured.headers['X-BAPI-TIMESTAMP']!;
      final payload =
          '$timestamp'
          'test-key'
          '5000'
          '${captured.url.query}';
      final expected =
          Hmac(
            sha256,
            utf8.encode('test-secret'),
          ).convert(utf8.encode(payload)).toString();

      expect(captured.url.path, '/v5/account/wallet-balance');
      expect(captured.url.query, 'accountType=UNIFIED');
      expect(captured.headers['X-BAPI-SIGN'], expected);
      expect(balance['total']['USDT'], 100);
      expect(balance['used']['USDT'], 2);
      expect(balance['free']['USDT'], 98);
      expect(balance['summary']['totalEquity'], 125);
      expect(balance['summary']['totalAvailableBalance'], 95);
      expect(balance['assets'].single['usdValue'], 100);
      expect(balance['assets'].single['borrowAmount'], 3);
      exchange.close();
    },
  );

  test('signed request syncs Bybit time and retries timestamp error once', () async {
    final timestamps = <int>[];
    final hosts = <String>[];
    final serverTime = DateTime.now().millisecondsSinceEpoch + 12000;
    var signedRequests = 0;
    final exchange = BybitCcxtAdapter(
      apiKey: 'test-key',
      apiSecret: 'test-secret',
      httpClient: MockClient((request) async {
        hosts.add(request.url.host);
        if (request.url.path == '/v5/market/time') {
          return http.Response(
            jsonEncode({
              'retCode': 0,
              'result': {
                'timeSecond': '${serverTime ~/ 1000}',
                'timeNano': '${serverTime * 1000000}',
              },
            }),
            200,
          );
        }
        signedRequests++;
        final timestamp = int.parse(request.headers['X-BAPI-TIMESTAMP']!);
        timestamps.add(timestamp);
        if (signedRequests == 1) {
          return http.Response(
            jsonEncode({
              'retCode': 10002,
              'retMsg': 'The request time exceeds the time window range.',
            }),
            200,
          );
        }
        final payload =
            '$timestamp'
            'test-key'
            '5000'
            '${request.url.query}';
        final expectedSignature =
            Hmac(
              sha256,
              utf8.encode('test-secret'),
            ).convert(utf8.encode(payload)).toString();
        expect(request.headers['X-BAPI-SIGN'], expectedSignature);
        return http.Response(
          jsonEncode({
            'retCode': 0,
            'result': {
              'list': [
                {
                  'accountType': 'UNIFIED',
                  'coin': [
                    {
                      'coin': 'USDT',
                      'walletBalance': '10',
                      'locked': '0',
                    },
                  ],
                },
              ],
            },
          }),
          200,
        );
      }),
    );

    final balance = await exchange.fetchBalance();

    expect(signedRequests, 2);
    expect(hosts, [
      'api.bybit.com',
      'api.bybit.com',
      'api.bybit.com',
    ]);
    expect(timestamps.last, closeTo(serverTime, 1000));
    expect(balance['total']['USDT'], 10);
    exchange.close();
  });

  test(
    'demo signed requests use Bybit demo while market data stays public',
    () async {
      final hosts = <String>[];
      final exchange = BybitCcxtAdapter(
        apiKey: 'demo-key',
        apiSecret: 'demo-secret',
        isDemo: true,
        httpClient: MockClient((request) async {
          hosts.add(request.url.host);
          if (request.url.path == '/v5/market/tickers') {
            return http.Response(
              jsonEncode({
                'retCode': 0,
                'result': {
                  'list': [
                    {'symbol': 'BTCUSDT', 'lastPrice': '50000'},
                  ],
                },
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'retCode': 0,
              'result': {
                'list': [
                  {
                    'accountType': 'UNIFIED',
                    'coin': [
                      {
                        'coin': 'USDT',
                        'walletBalance': '1000',
                        'availableToWithdraw': '850',
                        'locked': '10',
                      },
                    ],
                  },
                ],
              },
            }),
            200,
          );
        }),
      );

      final balance = await exchange.fetchBalance();
      await exchange.fetchTicker(category: 'spot', symbol: 'BTCUSDT');

      expect(hosts, ['api-demo.bybit.com', 'api.bybit.com']);
      expect(balance['free']['USDT'], 850);
      expect(balance['used']['USDT'], 10);
      exchange.close();
    },
  );

  test(
    'fetchBalance reports missing account data instead of zero balances',
    () async {
      final exchange = BybitCcxtAdapter(
        apiKey: 'test-key',
        apiSecret: 'test-secret',
        httpClient: MockClient((request) async {
          return http.Response(
            jsonEncode({
              'retCode': 0,
              'result': {'list': []},
            }),
            200,
          );
        }),
      );

      await expectLater(
        exchange.fetchBalance(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('no Unified Account wallet data'),
          ),
        ),
      );
      exchange.close();
    },
  );

  test(
    'fetchOHLCV maps CCXT timeframes and returns chronological six-field rows',
    () async {
      final exchange = BybitCcxtAdapter(
        apiKey: '',
        apiSecret: '',
        httpClient: MockClient((request) async {
          expect(request.url.queryParameters['interval'], '240');
          return http.Response(
            jsonEncode({
              'retCode': 0,
              'result': {
                'list': [
                  ['2000', '2', '3', '1', '2.5', '20', '50'],
                  ['1000', '1', '2', '0.5', '1.5', '10', '15'],
                ],
              },
            }),
            200,
          );
        }),
      );

      final candles = await exchange.fetchOHLCV(
        category: 'spot',
        symbol: 'BTCUSDT',
        timeframe: '4h',
      );

      expect(candles, [
        [1000, 1, 2, 0.5, 1.5, 10],
        [2000, 2, 3, 1, 2.5, 20],
      ]);
      exchange.close();
    },
  );

  test(
    'fetchMarkets paginates and creates CCXT-style market metadata',
    () async {
      var requestCount = 0;
      final exchange = BybitCcxtAdapter(
        apiKey: '',
        apiSecret: '',
        httpClient: MockClient((request) async {
          requestCount++;
          expect(request.url.queryParameters['category'], 'linear');
          expect(request.url.queryParameters['limit'], '1000');
          final firstPage = requestCount == 1;
          expect(
            request.url.queryParameters['cursor'],
            firstPage ? isNull : 'next-page',
          );
          return http.Response(
            jsonEncode({
              'retCode': 0,
              'result': {
                'list': [
                  {
                    'symbol': firstPage ? 'BTCUSDT' : 'ETHUSDT',
                    'status': 'Trading',
                    'contractType': 'LinearPerpetual',
                    'baseCoin': firstPage ? 'BTC' : 'ETH',
                    'quoteCoin': 'USDT',
                    'settleCoin': 'USDT',
                    'lotSizeFilter': {
                      'qtyStep': '0.001',
                      'minOrderQty': '0.001',
                    },
                    'priceFilter': {'tickSize': '0.10'},
                  },
                ],
                'nextPageCursor': firstPage ? 'next-page' : '',
              },
            }),
            200,
          );
        }),
      );

      final markets = await exchange.fetchMarkets(category: 'linear');
      final loadedMarkets = await exchange.loadMarkets(category: 'linear');

      expect(requestCount, 2);
      expect(markets.first['symbol'], 'BTC/USDT:USDT');
      expect(markets.first['id'], 'BTCUSDT');
      expect(markets.first['active'], isTrue);
      expect(markets.first['type'], 'swap');
      expect(loadedMarkets['ETH/USDT:USDT']?['id'], 'ETHUSDT');
      exchange.close();
    },
  );

  test('fetchTicker normalizes prices and 24-hour volume', () async {
    final exchange = BybitCcxtAdapter(
      apiKey: '',
      apiSecret: '',
      httpClient: MockClient((request) async {
        expect(request.url.queryParameters['category'], 'linear');
        return http.Response(
          jsonEncode({
            'retCode': 0,
            'result': {
              'list': [
                {
                  'symbol': 'BTCUSDT',
                  'lastPrice': '102',
                  'prevPrice24h': '100',
                  'highPrice24h': '105',
                  'lowPrice24h': '95',
                  'bid1Price': '101.9',
                  'bid1Size': '2',
                  'ask1Price': '102.1',
                  'ask1Size': '3',
                  'volume24h': '10',
                  'turnover24h': '1000',
                },
              ],
            },
          }),
          200,
        );
      }),
    );

    final ticker = await exchange.fetchTicker(
      category: 'linear',
      symbol: 'BTCUSDT',
    );

    expect(ticker['last'], 102);
    expect(ticker['bid'], 101.9);
    expect(ticker['ask'], 102.1);
    expect(ticker['percentage'], 2);
    expect(ticker['baseVolume'], 10);
    expect(ticker['quoteVolume'], 1000);
    exchange.close();
  });

  test('fetchTickers returns normalized market-wide ticker data', () async {
    final exchange = BybitCcxtAdapter(
      apiKey: '',
      apiSecret: '',
      httpClient: MockClient((request) async {
        expect(request.url.path, '/v5/market/tickers');
        expect(request.url.queryParameters, {'category': 'spot'});
        return http.Response(
          jsonEncode({
            'retCode': 0,
            'result': {
              'list': [
                {
                  'symbol': 'BTCUSDT',
                  'lastPrice': '102',
                  'prevPrice24h': '100',
                  'volume24h': '10',
                  'turnover24h': '1000',
                },
                {
                  'symbol': 'ETHUSDT',
                  'lastPrice': '52',
                  'prevPrice24h': '50',
                  'volume24h': '20',
                  'turnover24h': '900',
                },
              ],
            },
          }),
          200,
        );
      }),
    );

    final tickers = await exchange.fetchTickers(category: 'spot');

    expect(tickers, hasLength(2));
    expect(tickers.first['id'], 'BTCUSDT');
    expect(tickers.first['last'], 102);
    expect(tickers.first['percentage'], 2);
    expect(tickers.first['quoteVolume'], 1000);
    exchange.close();
  });

  test('fetchMarket normalizes option expiry and contract fields', () async {
    final exchange = BybitCcxtAdapter(
      apiKey: '',
      apiSecret: '',
      httpClient: MockClient((request) async {
        return http.Response(
          jsonEncode({
            'retCode': 0,
            'result': {
              'list': [
                {
                  'symbol': 'BTC-25DEC26-100000-C',
                  'status': 'Trading',
                  'baseCoin': 'BTC',
                  'quoteCoin': 'USDC',
                  'settleCoin': 'USDC',
                  'deliveryTime':
                      DateTime.utc(
                        2026,
                        12,
                        25,
                      ).millisecondsSinceEpoch.toString(),
                  'strike': '100000',
                  'optionsType': 'Call',
                  'lotSizeFilter': {'qtyStep': '0.01', 'minOrderQty': '0.01'},
                  'priceFilter': {'tickSize': '0.01'},
                },
              ],
            },
          }),
          200,
        );
      }),
    );

    final market = await exchange.fetchMarket(
      category: 'option',
      symbol: 'BTC-25DEC26-100000-C',
    );

    expect(market['symbol'], 'BTC/USDC:USDC-261225-100000-C');
    expect(market['id'], 'BTC-25DEC26-100000-C');
    expect(market['type'], 'option');
    expect(market['contract'], isTrue);
    expect(market['optionType'], 'call');
    expect(market['strike'], 100000);
    expect(market['active'], isTrue);
    exchange.close();
  });

  test(
    'createOrder uses amount precision and fetchOrder normalizes fills',
    () async {
      final calls = <http.Request>[];
      var statusPoll = 0;
      final exchange = BybitCcxtAdapter(
        apiKey: 'test-key',
        apiSecret: 'test-secret',
        httpClient: MockClient((request) async {
          calls.add(request);
          if (request.url.path == '/v5/market/instruments-info') {
            return http.Response(
              jsonEncode({
                'retCode': 0,
                'result': {
                  'list': [
                    {
                      'symbol': 'BTCUSDT',
                      'status': 'Trading',
                      'baseCoin': 'BTC',
                      'quoteCoin': 'USDT',
                      'settleCoin': 'USDT',
                      'lotSizeFilter': {
                        'qtyStep': '0.0001',
                        'minOrderQty': '0.0001',
                      },
                      'priceFilter': {'tickSize': '0.1'},
                    },
                  ],
                },
              }),
              200,
            );
          }
          if (request.url.path == '/v5/order/create') {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            expect(body['qty'], '0.0012');
            expect(body['side'], 'Buy');
            expect(body['marketUnit'], 'baseCoin');
            return http.Response(
              jsonEncode({
                'retCode': 0,
                'time': 2000,
                'result': {'orderId': 'order-1'},
              }),
              200,
            );
          }
          if (request.url.path == '/v5/order/realtime') {
            statusPoll++;
            return http.Response(
              jsonEncode({
                'retCode': 0,
                'result': {'list': []},
              }),
              200,
            );
          }
          expect(request.url.path, '/v5/order/history');
          return http.Response(
            jsonEncode({
              'retCode': 0,
              'result': {
                'list': [
                  {
                    'orderId': 'order-1',
                    'symbol': 'BTCUSDT',
                    'orderStatus': 'Filled',
                    'orderType': 'Market',
                    'side': 'Buy',
                    'qty': '0.0012',
                    'cumExecQty': '0.0012',
                    'leavesQty': '0',
                    'avgPrice': '50000',
                    'cumExecValue': '60',
                    'createdTime': '1000',
                    'updatedTime': '2000',
                  },
                ],
              },
            }),
            200,
          );
        }),
      );

      await exchange.fetchMarket(category: 'spot', symbol: 'BTCUSDT');
      final created = await exchange.createOrder(
        category: 'spot',
        symbol: 'BTCUSDT',
        type: 'market',
        side: 'buy',
        amount: 0.001239,
        params: const {'marketUnit': 'baseCoin'},
      );
      final filled = await exchange.fetchOrder(
        category: 'spot',
        symbol: 'BTCUSDT',
        id: created['id'] as String,
      );

      expect(created['id'], 'order-1');
      expect(created['status'], 'open');
      expect(filled['status'], 'closed');
      expect(filled['filled'], 0.0012);
      expect(filled['average'], 50000);
      expect(statusPoll, 1);
      expect(
        calls.where((request) => request.headers['X-BAPI-SIGN'] != null),
        isNotEmpty,
      );
      exchange.close();
    },
  );

  test(
    'setLeverage tolerates Bybit already-configured responses only',
    () async {
      final paths = <String>[];
      final exchange = BybitCcxtAdapter(
        apiKey: 'test-key',
        apiSecret: 'test-secret',
        httpClient: MockClient((request) async {
          paths.add(request.url.path);
          return http.Response(
            jsonEncode({
              'retCode':
                  request.url.path.endsWith('switch-isolated')
                      ? 110026
                      : 110043,
              'retMsg': 'already configured',
              'result': <String, dynamic>{},
            }),
            200,
          );
        }),
      );

      await exchange.setLeverage(
        category: 'linear',
        symbol: 'BTCUSDT',
        leverage: '1',
      );

      expect(paths, [
        '/v5/position/switch-isolated',
        '/v5/position/set-leverage',
      ]);
      exchange.close();
    },
  );

  test(
    'fetchOpenOrders returns normalized orders and retains filters',
    () async {
      late http.Request captured;
      final exchange = BybitCcxtAdapter(
        apiKey: 'test-key',
        apiSecret: 'test-secret',
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'retCode': 0,
              'result': {
                'list': [
                  {
                    'orderId': 'stop-1',
                    'symbol': 'BTCUSDT',
                    'orderStatus': 'New',
                    'orderType': 'Market',
                    'side': 'Sell',
                    'qty': '0.1',
                    'cumExecQty': '0',
                    'orderFilter': 'StopOrder',
                    'triggerPrice': '45000',
                  },
                ],
              },
            }),
            200,
          );
        }),
      );

      final orders = await exchange.fetchOpenOrders(category: 'spot');

      expect(captured.url.path, '/v5/order/realtime');
      expect(captured.url.queryParameters['category'], 'spot');
      expect(captured.headers['X-BAPI-SIGN'], isNotEmpty);
      expect(orders, hasLength(1));
      expect(orders.single['id'], 'stop-1');
      expect(orders.single['side'], 'sell');
      expect(orders.single['status'], 'open');
      expect(
        (orders.single['info'] as Map<String, dynamic>)['orderFilter'],
        'StopOrder',
      );
      exchange.close();
    },
  );

  test(
    'fetchOpenOrders scopes derivatives orders by settlement coin',
    () async {
      late http.Request captured;
      final exchange = BybitCcxtAdapter(
        apiKey: 'test-key',
        apiSecret: 'test-secret',
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'retCode': 0,
              'result': {'list': []},
            }),
            200,
          );
        }),
      );

      await exchange.fetchOpenOrders(category: 'linear', settleCoin: 'USDT');

      expect(captured.url.queryParameters['category'], 'linear');
      expect(captured.url.queryParameters['settleCoin'], 'USDT');
      expect(captured.url.queryParameters.containsKey('baseCoin'), isFalse);
      exchange.close();
    },
  );

  test('fetchPositions normalizes active positions only', () async {
    late http.Request captured;
    final exchange = BybitCcxtAdapter(
      apiKey: 'test-key',
      apiSecret: 'test-secret',
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'retCode': 0,
            'result': {
              'list': [
                {
                  'symbol': 'BTCUSDT',
                  'side': 'Buy',
                  'size': '0.2',
                  'avgPrice': '50000',
                  'markPrice': '51000',
                  'unrealisedPnl': '200',
                  'positionIdx': 1,
                },
                {'symbol': 'ETHUSDT', 'side': '', 'size': '0'},
              ],
            },
          }),
          200,
        );
      }),
    );

    final positions = await exchange.fetchPositions(
      category: 'linear',
      settleCoin: 'USDT',
    );

    expect(captured.url.path, '/v5/position/list');
    expect(captured.url.queryParameters['settleCoin'], 'USDT');
    expect(positions, hasLength(1));
    expect(positions.single['symbol'], 'BTCUSDT');
    expect(positions.single['side'], 'buy');
    expect(positions.single['quantity'], 0.2);
    expect(positions.single['positionIdx'], 1);
    expect(positions.single['unrealisedPnl'], 200);
    exchange.close();
  });
}
