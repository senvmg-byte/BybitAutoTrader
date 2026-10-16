import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

class BybitApiException implements Exception {
  const BybitApiException(this.code, this.message);

  final int code;
  final String message;

  @override
  String toString() => 'Bybit $code: $message';
}

class BybitCcxtAdapter {
  BybitCcxtAdapter({
    required this.apiKey,
    required this.apiSecret,
    this.isDemo = false,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final String apiKey;
  final String apiSecret;
  final bool isDemo;
  final http.Client _http;
  final Map<String, Map<String, Map<String, dynamic>>> _markets = {};
  static const _recvWindow = '5000';
  int? _serverTimeOffsetMs;

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, String> query = const {},
    Map<String, Object?>? body,
    bool signed = false,
  }) async {
    final sortedQuery = Map<String, String>.fromEntries(
      query.entries.toList()
        ..sort((left, right) => left.key.compareTo(right.key)),
    );
    final queryString = sortedQuery.entries
        .map(
          (entry) =>
              '${Uri.encodeQueryComponent(entry.key)}=${Uri.encodeQueryComponent(entry.value)}',
        )
        .join('&');
    final bodyString = body == null ? '' : jsonEncode(body);
    final uri = Uri.https(
      signed && isDemo ? 'api-demo.bybit.com' : 'api.bybit.com',
      path,
      sortedQuery.isEmpty ? null : sortedQuery,
    );
    if (signed && (apiKey.isEmpty || apiSecret.isEmpty)) {
      throw const FormatException('Nhập API Key và API Secret Bybit.');
    }

    Future<http.Response> sendRequest() async {
      final headers = <String, String>{'Content-Type': 'application/json'};
      if (signed) {
        final timestamp =
            (DateTime.now().millisecondsSinceEpoch +
                    (_serverTimeOffsetMs ?? 0))
                .toString();
        final payload = method == 'GET' ? queryString : bodyString;
        final signature = Hmac(
          sha256,
          utf8.encode(apiSecret),
        ).convert(utf8.encode('$timestamp$apiKey$_recvWindow$payload'));
        headers.addAll({
          'X-BAPI-API-KEY': apiKey,
          'X-BAPI-SIGN': signature.toString(),
          'X-BAPI-SIGN-TYPE': '2',
          'X-BAPI-TIMESTAMP': timestamp,
          'X-BAPI-RECV-WINDOW': _recvWindow,
        });
      }
      return method == 'GET'
          ? _http.get(uri, headers: headers).timeout(const Duration(seconds: 15))
          : _http
              .post(uri, headers: headers, body: bodyString)
              .timeout(const Duration(seconds: 15));
    }

    var response = await sendRequest();
    var decoded = _decodeResponse(response);
    if (signed && _responseCode(response, decoded) == 10002) {
      await _syncServerTime();
      response = await sendRequest();
      decoded = _decodeResponse(response);
    }
    final retCode = decoded['retCode'];
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        retCode != 0) {
      throw BybitApiException(
        retCode is int ? retCode : response.statusCode,
        '${decoded['retMsg'] ?? response.reasonPhrase ?? 'Request failed.'}',
      );
    }
    return decoded;
  }

  Map<String, dynamic> _decodeResponse(http.Response response) {
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Bybit trả về dữ liệu không hợp lệ.');
    }
    return decoded;
  }

  int? _responseCode(http.Response response, Map<String, dynamic> decoded) {
    final code = decoded['retCode'];
    return code is int ? code : int.tryParse('$code') ?? response.statusCode;
  }

  Future<void> _syncServerTime() async {
    final startedAt = DateTime.now().millisecondsSinceEpoch;
    final response = await _http
        .get(Uri.https('api.bybit.com', '/v5/market/time'))
        .timeout(const Duration(seconds: 15));
    final completedAt = DateTime.now().millisecondsSinceEpoch;
    final decoded = _decodeResponse(response);
    final retCode = _responseCode(response, decoded);
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        retCode != 0) {
      throw BybitApiException(
        retCode ?? response.statusCode,
        '${decoded['retMsg'] ?? response.reasonPhrase ?? 'Server time request failed.'}',
      );
    }
    final result = decoded['result'];
    final resultMap =
        result is Map<String, dynamic> ? result : const <String, dynamic>{};
    final timeNano = BigInt.tryParse('${resultMap['timeNano'] ?? ''}');
    final serverTimeMs =
        timeNano == null
            ? int.tryParse('${decoded['time'] ?? ''}')
            : (timeNano ~/ BigInt.from(1000000)).toInt();
    if (serverTimeMs == null || serverTimeMs <= 0) {
      throw const FormatException(
        'Không đọc được server time từ Bybit để đồng bộ timestamp.',
      );
    }
    final requestMidpoint = startedAt + (completedAt - startedAt) ~/ 2;
    _serverTimeOffsetMs = serverTimeMs - requestMidpoint;
  }

  Future<Map<String, Map<String, dynamic>>> loadMarkets({
    required String category,
    bool reload = false,
  }) async {
    if (!reload && _markets.containsKey(category)) {
      return Map.unmodifiable({
        for (final market in _markets[category]!.values)
          if (market['symbol'] != null) market['symbol'] as String: market,
      });
    }
    final markets = await fetchMarkets(category: category);
    final indexed = <String, Map<String, dynamic>>{
      for (final market in markets) market['symbol'] as String: market,
    };
    _markets[category] = {
      ...indexed,
      for (final market in markets) market['id'] as String: market,
    };
    return Map.unmodifiable(indexed);
  }

  Future<List<Map<String, dynamic>>> fetchMarkets({
    required String category,
  }) async {
    _validateCategory(category);
    final rawMarkets = <Map<String, dynamic>>[];
    String? cursor;
    do {
      final query = <String, String>{'category': category, 'limit': '1000'};
      if (cursor != null && cursor.isNotEmpty) query['cursor'] = cursor;
      final response = await _request(
        'GET',
        '/v5/market/instruments-info',
        query: query,
      );
      final result = response['result'] as Map<String, dynamic>;
      rawMarkets.addAll(
        (result['list'] as List<dynamic>).whereType<Map<String, dynamic>>(),
      );
      cursor = result['nextPageCursor'] as String?;
    } while (cursor != null && cursor.isNotEmpty && rawMarkets.length < 3000);
    if (cursor != null && cursor.isNotEmpty) {
      throw StateError('Bybit market list exceeded the adapter page limit.');
    }
    final markets =
        rawMarkets.map((market) => _normalizeMarket(category, market)).toList();
    _markets[category] = {
      for (final market in markets) market['symbol'] as String: market,
      for (final market in markets) market['id'] as String: market,
    };
    return markets;
  }

  Future<Map<String, dynamic>> fetchMarket({
    required String category,
    required String symbol,
  }) async {
    _validateCategory(category);
    final cached = _markets[category]?[symbol];
    if (cached != null) return cached;
    final raw = await _fetchRawMarket(category: category, symbol: symbol);
    final market = _normalizeMarket(category, raw);
    _markets.putIfAbsent(category, () => {})[market['symbol'] as String] =
        market;
    _markets[category]![symbol] = market;
    return market;
  }

  Future<Map<String, dynamic>> _fetchRawMarket({
    required String category,
    required String symbol,
  }) async {
    final response = await _request(
      'GET',
      '/v5/market/instruments-info',
      query: {'category': category, 'symbol': symbol},
    );
    final result = response['result'] as Map<String, dynamic>;
    final list = result['list'] as List<dynamic>;
    if (list.isEmpty || list.first is! Map<String, dynamic>) {
      throw StateError('Không tìm thấy market $symbol trên Bybit.');
    }
    return list.first as Map<String, dynamic>;
  }

  Map<String, dynamic> _normalizeMarket(
    String category,
    Map<String, dynamic> raw,
  ) {
    final base = '${raw['baseCoin'] ?? ''}';
    final quote = '${raw['quoteCoin'] ?? raw['settleCoin'] ?? ''}';
    final settle = '${raw['settleCoin'] ?? ''}';
    final id = '${raw['symbol'] ?? ''}';
    final expiry = int.tryParse('${raw['deliveryTime'] ?? ''}');
    final strike = raw['strike']?.toString();
    final optionType = '${raw['optionsType'] ?? ''}'.toLowerCase();
    final unifiedSymbol = switch (category) {
      'spot' => '$base/$quote',
      'option' =>
        '$base/$quote:$settle-${_expiryCode(expiry)}-${strike ?? ''}-${optionType == 'call' ? 'C' : 'P'}',
      _ => '$base/$quote:$settle',
    };
    final lot = raw['lotSizeFilter'] as Map<String, dynamic>? ?? const {};
    final price = raw['priceFilter'] as Map<String, dynamic>? ?? const {};
    final isContract = category != 'spot';
    return {
      ...raw,
      'id': id,
      'symbol': unifiedSymbol,
      'base': base,
      'quote': quote,
      'settle': settle,
      'type': switch (category) {
        'spot' => 'spot',
        'option' => 'option',
        _ =>
          raw['contractType'] == 'InversePerpetual' ||
                  raw['contractType'] == 'LinearPerpetual'
              ? 'swap'
              : 'future',
      },
      'category': category,
      'active': raw['status'] == 'Trading',
      'contract': isContract,
      'linear': category == 'linear',
      'inverse': category == 'inverse',
      'expiry': expiry == null || expiry == 0 ? null : expiry,
      'strike': strike == null ? null : double.tryParse(strike),
      'optionType': category == 'option' ? optionType : null,
      'precision': {
        'amount': _decimalPlaces('${lot['qtyStep'] ?? ''}'),
        'price': _decimalPlaces('${price['tickSize'] ?? ''}'),
      },
      'limits': {
        'amount': {
          'min': double.tryParse('${lot['minOrderQty'] ?? ''}'),
          'max': double.tryParse(
            '${lot['maxMktOrderQty'] ?? lot['maxOrderQty'] ?? ''}',
          ),
        },
        'cost': {
          'min': double.tryParse('${lot['minNotionalValue'] ?? ''}'),
          'max': null,
        },
      },
      'info': raw,
    };
  }

  String _expiryCode(int? milliseconds) {
    if (milliseconds == null || milliseconds <= 0) return '';
    final date = DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);
    final year = (date.year % 100).toString().padLeft(2, '0');
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '$year$month$day';
  }

  int? _decimalPlaces(String value) {
    if (value.isEmpty) return null;
    final exponent = value.toLowerCase().indexOf('e-');
    if (exponent >= 0) return int.tryParse(value.substring(exponent + 2));
    return value.contains('.') ? value.split('.').last.length : 0;
  }

  Future<Map<String, dynamic>> fetchTicker({
    required String category,
    required String symbol,
  }) async {
    _validateCategory(category);
    final response = await _request(
      'GET',
      '/v5/market/tickers',
      query: {'category': category, 'symbol': symbol},
    );
    final result = response['result'] as Map<String, dynamic>;
    final list = result['list'] as List<dynamic>;
    if (list.isEmpty || list.first is! Map<String, dynamic>) {
      throw StateError('Không có ticker Bybit cho $symbol.');
    }
    final raw = list.first as Map<String, dynamic>;
    return _normalizeTicker(category, raw);
  }

  Future<List<Map<String, dynamic>>> fetchTickers({
    required String category,
  }) async {
    _validateCategory(category);
    final response = await _request(
      'GET',
      '/v5/market/tickers',
      query: {'category': category},
    );
    final result = response['result'] as Map<String, dynamic>;
    final list = result['list'] as List<dynamic>;
    return list
        .whereType<Map<String, dynamic>>()
        .map((raw) => _normalizeTicker(category, raw))
        .toList();
  }

  Map<String, dynamic> _normalizeTicker(
    String category,
    Map<String, dynamic> raw,
  ) {
    final id = '${raw['symbol'] ?? ''}';
    final last = _number(raw['lastPrice']);
    final previous = _number(raw['prevPrice24h']);
    final change = last == null || previous == null ? null : last - previous;
    return {
      'id': id,
      'symbol': _markets[category]?[id]?['symbol'] ?? id,
      'timestamp': int.tryParse('${raw['ts'] ?? ''}'),
      'datetime': null,
      'high': _number(raw['highPrice24h']),
      'low': _number(raw['lowPrice24h']),
      'bid': _number(raw['bid1Price']),
      'bidVolume': _number(raw['bid1Size']),
      'ask': _number(raw['ask1Price']),
      'askVolume': _number(raw['ask1Size']),
      'open': previous,
      'close': last,
      'last': last,
      'previousClose': previous,
      'change': change,
      'percentage':
          change == null || previous == null || previous == 0
              ? null
              : change / previous * 100,
      'baseVolume': _number(raw['volume24h']),
      'quoteVolume': _number(raw['turnover24h']),
      'info': raw,
    };
  }

  Future<List<List<double>>> fetchOHLCV({
    required String category,
    required String symbol,
    required String timeframe,
    int limit = 200,
  }) async {
    _validateCategory(category);
    final interval = _bybitInterval(timeframe);
    final response = await _request(
      'GET',
      '/v5/market/kline',
      query: {
        'category': category,
        'symbol': symbol,
        'interval': interval,
        'limit': '$limit',
      },
    );
    final result = response['result'] as Map<String, dynamic>;
    final candles =
        (result['list'] as List<dynamic>)
            .whereType<List<dynamic>>()
            .map(
              (row) =>
                  row
                      .take(6)
                      .map((value) => double.tryParse('$value'))
                      .toList(),
            )
            .where(
              (row) =>
                  row.length == 6 &&
                  row.every((value) => value != null && value.isFinite),
            )
            .map((row) => row.cast<double>())
            .toList()
          ..sort((left, right) => left[0].compareTo(right[0]));
    return candles;
  }

  String _bybitInterval(String timeframe) => switch (timeframe) {
    '1m' => '1',
    '3m' => '3',
    '5m' => '5',
    '15m' => '15',
    '30m' => '30',
    '1h' => '60',
    '2h' => '120',
    '4h' => '240',
    '6h' => '360',
    '12h' => '720',
    '1d' => 'D',
    '1w' => 'W',
    '1M' => 'M',
    _ => throw FormatException('Khung nến Bybit không hỗ trợ: $timeframe'),
  };

  Future<Map<String, dynamic>> fetchBalance() async {
    final response = await _request(
      'GET',
      '/v5/account/wallet-balance',
      query: const {'accountType': 'UNIFIED'},
      signed: true,
    );
    final result = response['result'] as Map<String, dynamic>;
    final accounts = result['list'] as List<dynamic>;
    final accountEntries = accounts.whereType<Map<String, dynamic>>().toList();
    if (accountEntries.isEmpty) {
      throw StateError(
        'Bybit returned no Unified Account wallet data. Check API permissions '
        'and account type, then retry.',
      );
    }
    final rawAccount = accountEntries.first;
    final free = <String, double>{};
    final used = <String, double>{};
    final total = <String, double>{};
    final assetDetails = <Map<String, Object?>>[];
    for (final raw
        in (rawAccount['coin'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()) {
      final coin = '${raw['coin'] ?? ''}';
      final balance = _number(raw['walletBalance']) ?? 0;
      final locked = _number(raw['locked']) ?? 0;
      final withdrawable = _number(raw['availableToWithdraw']);
      total[coin] = balance;
      used[coin] = locked;
      free[coin] =
          (withdrawable ?? balance - locked)
              .clamp(0, double.infinity)
              .toDouble();
      assetDetails.add({
        'coin': coin,
        'walletBalance': balance,
        'locked': locked,
        'equity': _number(raw['equity']),
        'usdValue': _number(raw['usdValue']),
        'availableToBorrow': _number(raw['availableToBorrow']),
        'borrowAmount': _number(raw['borrowAmount']),
        'accruedInterest': _number(raw['accruedInterest']),
        'spotHedgingQty': _number(raw['spotHedgingQty']),
        'totalOrderIM': _number(raw['totalOrderIM']),
        'totalPositionIM': _number(raw['totalPositionIM']),
      });
    }
    final summaryKeys = [
      'accountType',
      'totalEquity',
      'totalWalletBalance',
      'totalMarginBalance',
      'totalAvailableBalance',
      'totalPerpUPL',
      'accountIMRate',
      'accountMMRate',
      'totalInitialMargin',
      'totalMaintenanceMargin',
    ];
    final summary = <String, Object?>{};
    for (final key in summaryKeys) {
      final value = rawAccount[key];
      summary[key] = key == 'accountType' ? value : _number(value);
    }
    return {
      'timestamp': int.tryParse('${response['time'] ?? ''}'),
      'datetime': null,
      'summary': summary,
      'assets': assetDetails,
      'free': free,
      'used': used,
      'total': total,
      for (final coin in total.keys)
        coin: {'free': free[coin], 'used': used[coin], 'total': total[coin]},
      'info': response,
    };
  }

  Future<List<Map<String, dynamic>>> fetchOpenOrders({
    required String category,
    String? settleCoin,
    String? baseCoin,
    String? symbol,
  }) async {
    _validateCategory(category);
    final orders = <Map<String, dynamic>>[];
    String? cursor;
    do {
      final query = <String, String>{'category': category, 'limit': '50'};
      if (settleCoin != null) query['settleCoin'] = settleCoin;
      if (baseCoin != null) query['baseCoin'] = baseCoin;
      if (symbol != null) query['symbol'] = symbol;
      if (cursor != null && cursor.isNotEmpty) query['cursor'] = cursor;
      final response = await _request(
        'GET',
        '/v5/order/realtime',
        query: query,
        signed: true,
      );
      final result = response['result'] as Map<String, dynamic>;
      orders.addAll(
        (result['list'] as List<dynamic>).whereType<Map<String, dynamic>>().map(
          (raw) => _normalizeOrder(
            raw,
            category: category,
            symbol: '${raw['symbol'] ?? ''}',
          ),
        ),
      );
      cursor = result['nextPageCursor'] as String?;
    } while (cursor != null && cursor.isNotEmpty && orders.length < 1000);
    if (cursor != null && cursor.isNotEmpty) {
      throw StateError('Bybit open orders exceeded the adapter page limit.');
    }
    return orders;
  }

  Future<List<Map<String, dynamic>>> fetchPositions({
    required String category,
    String? settleCoin,
    String? baseCoin,
  }) async {
    _validateCategory(category);
    if (settleCoin == null && baseCoin == null) {
      throw ArgumentError('Specify settleCoin or baseCoin.');
    }
    final positions = <Map<String, dynamic>>[];
    String? cursor;
    do {
      final query = <String, String>{'category': category, 'limit': '200'};
      if (settleCoin != null) query['settleCoin'] = settleCoin;
      if (baseCoin != null) query['baseCoin'] = baseCoin;
      if (cursor != null && cursor.isNotEmpty) query['cursor'] = cursor;
      final response = await _request(
        'GET',
        '/v5/position/list',
        query: query,
        signed: true,
      );
      final result = response['result'] as Map<String, dynamic>;
      positions.addAll(
        (result['list'] as List<dynamic>)
            .whereType<Map<String, dynamic>>()
            .where((raw) => (_number(raw['size']) ?? 0) > 0)
            .map(
              (raw) => {
                'symbol': '${raw['symbol'] ?? ''}',
                'side': '${raw['side'] ?? ''}'.toLowerCase(),
                'quantity': _number(raw['size']) ?? 0,
                'entryPrice': _number(raw['avgPrice']),
                'markPrice': _number(raw['markPrice']),
                'unrealisedPnl': _number(raw['unrealisedPnl']),
                'positionIdx': int.tryParse('${raw['positionIdx'] ?? 0}') ?? 0,
                'category': category,
                'info': raw,
              },
            ),
      );
      cursor = result['nextPageCursor'] as String?;
    } while (cursor != null && cursor.isNotEmpty && positions.length < 1000);
    if (cursor != null && cursor.isNotEmpty) {
      throw StateError('Bybit positions exceeded the adapter page limit.');
    }
    return positions;
  }

  Future<Map<String, dynamic>> liquidateAccount() async {
    final openOrders = <String, List<Map<String, dynamic>>>{};
    final linearMarkets = await fetchMarkets(category: 'linear');
    final inverseMarkets = await fetchMarkets(category: 'inverse');
    final optionMarkets = await fetchMarkets(category: 'option');
    final spotMarkets = await fetchMarkets(category: 'spot');
    final linearSettleCoins =
        linearMarkets
            .map((market) => '${market['settle'] ?? ''}')
            .where((coin) => coin.isNotEmpty)
            .toSet();
    final inverseSettleCoins =
        inverseMarkets
            .map((market) => '${market['settle'] ?? ''}')
            .where((coin) => coin.isNotEmpty)
            .toSet();
    final optionBases =
        optionMarkets
            .map((market) => '${market['base'] ?? ''}')
            .where((base) => base.isNotEmpty)
            .toSet();
    openOrders['spot'] = await fetchOpenOrders(category: 'spot');
    for (final settleCoin in linearSettleCoins) {
      openOrders
          .putIfAbsent('linear', () => [])
          .addAll(
            await fetchOpenOrders(category: 'linear', settleCoin: settleCoin),
          );
    }
    for (final settleCoin in inverseSettleCoins) {
      openOrders
          .putIfAbsent('inverse', () => [])
          .addAll(
            await fetchOpenOrders(category: 'inverse', settleCoin: settleCoin),
          );
    }
    for (final baseCoin in optionBases) {
      openOrders
          .putIfAbsent('option', () => [])
          .addAll(
            await fetchOpenOrders(category: 'option', baseCoin: baseCoin),
          );
    }
    final initialPositions = <Map<String, dynamic>>[];
    for (final settleCoin in linearSettleCoins) {
      initialPositions.addAll(
        await fetchPositions(category: 'linear', settleCoin: settleCoin),
      );
    }
    for (final settleCoin in inverseSettleCoins) {
      initialPositions.addAll(
        await fetchPositions(category: 'inverse', settleCoin: settleCoin),
      );
    }
    for (final base in optionBases) {
      initialPositions.addAll(
        await fetchPositions(category: 'option', baseCoin: base),
      );
    }
    final detectedPositionCount = initialPositions.length;

    final completed = <String>[];
    final skipped = <String>[];
    final failed = <String>[];
    final closedPositions = <Map<String, dynamic>>[];

    for (final entry in openOrders.entries) {
      for (final order in entry.value) {
        final raw = order['info'] as Map<String, dynamic>? ?? const {};
        try {
          final symbol = '${raw['symbol'] ?? ''}';
          final orderId = '${order['id'] ?? ''}';
          await cancelOrder(
            category: entry.key,
            symbol: symbol,
            id: orderId,
            params: {
              if (raw['orderFilter'] != null) 'orderFilter': raw['orderFilter'],
            },
          );
          Map<String, dynamic>? confirmation;
          Object? lastError;
          for (var attempt = 0; attempt < 8; attempt++) {
            await Future<void>.delayed(const Duration(milliseconds: 400));
            try {
              confirmation = await fetchOrder(
                category: entry.key,
                symbol: symbol,
                id: orderId,
              );
              if (const {
                'canceled',
                'closed',
                'rejected',
                'expired',
              }.contains(confirmation['status'])) {
                break;
              }
            } catch (error) {
              lastError = error;
            }
          }
          if (!const {
            'canceled',
            'closed',
            'rejected',
            'expired',
          }.contains(confirmation?['status'])) {
            throw StateError(
              'Chưa xác nhận lệnh đã hủy/kết thúc'
              '${lastError == null ? '.' : ': $lastError'}',
            );
          }
          completed.add('Hủy lệnh chờ ${entry.key} $symbol $orderId');
        } catch (error) {
          failed.add('Hủy lệnh ${entry.key} ${raw['symbol'] ?? ''}: $error');
        }
      }
    }
    if (failed.isNotEmpty) {
      skipped.add(
        'Không đóng vị thế hoặc bán tài sản vì chưa thể hủy mọi lệnh chờ.',
      );
      return {
        'completed': completed,
        'skipped': skipped,
        'failed': failed,
        'positionsDetected': detectedPositionCount,
        'closedPositions': closedPositions,
        'complete': false,
      };
    }

    final positions = <Map<String, dynamic>>[];
    try {
      for (final settleCoin in linearSettleCoins) {
        positions.addAll(
          await fetchPositions(category: 'linear', settleCoin: settleCoin),
        );
      }
      for (final settleCoin in inverseSettleCoins) {
        positions.addAll(
          await fetchPositions(category: 'inverse', settleCoin: settleCoin),
        );
      }
      for (final base in optionBases) {
        positions.addAll(
          await fetchPositions(category: 'option', baseCoin: base),
        );
      }
    } catch (error) {
      failed.add('Không tải lại được vị thế sau khi hủy lệnh: $error');
      skipped.add(
        'Bỏ qua đóng vị thế và bán Spot vì không thể đối soát vị thế.',
      );
      return {
        'completed': completed,
        'skipped': skipped,
        'failed': failed,
        'positionsDetected': detectedPositionCount,
        'closedPositions': closedPositions,
        'complete': false,
      };
    }

    for (final position in positions) {
      final category = '${position['category']}';
      final symbol = '${position['symbol']}';
      final side = '${position['side']}';
      final quantity = (position['quantity'] as num).toDouble();
      try {
        final closeOrder = await createOrder(
          category: category,
          symbol: symbol,
          type: 'market',
          side: side == 'buy' ? 'sell' : 'buy',
          amount: quantity,
          params: {
            'positionIdx': position['positionIdx'],
            if (category == 'linear' || category == 'inverse')
              'reduceOnly': true,
          },
        );
        final orderId = closeOrder['id']?.toString();
        if (orderId == null || orderId.isEmpty) {
          throw StateError('Bybit không trả orderId cho lệnh đóng.');
        }
        Map<String, dynamic>? confirmation;
        for (var attempt = 0; attempt < 8; attempt++) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          confirmation = await fetchOrder(
            category: category,
            symbol: symbol,
            id: orderId,
          );
          if (confirmation['status'] == 'closed') break;
        }
        if (confirmation?['status'] != 'closed') {
          throw StateError('Bybit chưa xác nhận lệnh đóng đã khớp.');
        }
        final filledQuantity = confirmation?['filled'] as double? ?? 0;
        if (quantity - filledQuantity > quantity * 0.000001) {
          throw StateError(
            'Lệnh đóng chỉ khớp $filledQuantity/$quantity; cần đối soát.',
          );
        }
        completed.add('Đóng $category $symbol $side $quantity');
        closedPositions.add({
          'category': category,
          'symbol': symbol,
          'side': side,
          'quantity': quantity,
          'orderId': orderId,
        });
      } catch (error) {
        failed.add('Đóng vị thế $category $symbol: $error');
      }
    }

    final remainingPositions = <Map<String, dynamic>>[];
    try {
      for (final settleCoin in linearSettleCoins) {
        remainingPositions.addAll(
          await fetchPositions(category: 'linear', settleCoin: settleCoin),
        );
      }
      for (final settleCoin in inverseSettleCoins) {
        remainingPositions.addAll(
          await fetchPositions(category: 'inverse', settleCoin: settleCoin),
        );
      }
      for (final base in optionBases) {
        remainingPositions.addAll(
          await fetchPositions(category: 'option', baseCoin: base),
        );
      }
      for (final position in remainingPositions) {
        failed.add(
          'Còn vị thế ${position['category']} ${position['symbol']} '
          '${position['side']} ${position['quantity']}.',
        );
        closedPositions.removeWhere(
          (closed) =>
              closed['category'] == position['category'] &&
              closed['symbol'] == position['symbol'] &&
              closed['side'] == position['side'],
        );
      }
    } catch (error) {
      closedPositions.clear();
      failed.add('Không xác minh được các vị thế đã đóng: $error');
    }

    Map<String, dynamic> balance;
    try {
      balance = await fetchBalance();
    } catch (error) {
      failed.add('Không tải được số dư Spot để bán tài sản: $error');
      return {
        'completed': completed,
        'skipped': skipped,
        'failed': failed,
        'positionsDetected': detectedPositionCount,
        'closedPositions': closedPositions,
        'complete': false,
      };
    }
    final free = balance['free'] as Map<String, double>;
    final sellMarkets =
        spotMarkets.where((market) => market['active'] == true).toList();
    for (final entry in free.entries) {
      final coin = entry.key;
      final available = entry.value;
      if (coin == 'USDT' || available <= 0) continue;
      final candidates =
          sellMarkets
              .where(
                (market) =>
                    market['base'] == coin &&
                    const {'USDT', 'USDC'}.contains(market['quote']),
              )
              .toList();
      if (candidates.isEmpty) {
        skipped.add('$coin: không tìm thấy cặp Spot USDT/USDC đang giao dịch.');
        continue;
      }
      final market =
          candidates
              .where((candidate) => candidate['quote'] == 'USDT')
              .firstOrNull ??
          candidates.first;
      final marketId = '${market['id']}';
      try {
        final ticker = await fetchTicker(category: 'spot', symbol: marketId);
        final price = ticker['bid'] as double? ?? ticker['last'] as double?;
        final minimumNotional =
            double.tryParse(
              '${(market['lotSizeFilter'] as Map?)?['minNotionalValue'] ?? 0}',
            ) ??
            0;
        if (price == null || available * price < minimumNotional) {
          skipped.add('$coin: số dư nhỏ hơn giá trị lệnh tối thiểu.');
          continue;
        }
        final order = await createOrder(
          category: 'spot',
          symbol: marketId,
          type: 'market',
          side: 'sell',
          amount: available,
          params: const {'marketUnit': 'baseCoin'},
        );
        final orderId = order['id']?.toString();
        if (orderId == null || orderId.isEmpty) {
          throw StateError('Bybit không trả orderId cho lệnh bán.');
        }
        final requestedQuantity = order['amount'] as double? ?? available;
        Map<String, dynamic>? confirmation;
        for (var attempt = 0; attempt < 8; attempt++) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          confirmation = await fetchOrder(
            category: 'spot',
            symbol: marketId,
            id: orderId,
          );
          if (confirmation['status'] == 'closed') break;
        }
        final filled = confirmation;
        if (filled == null || filled['status'] != 'closed') {
          throw StateError('Bybit chưa xác nhận lệnh bán đã khớp.');
        }
        final filledQuantity = filled['filled'] as double? ?? 0;
        if (requestedQuantity - filledQuantity > requestedQuantity * 0.000001) {
          throw StateError(
            'Lệnh bán chỉ khớp $filledQuantity/$requestedQuantity; cần đối soát.',
          );
        }
        if (available - requestedQuantity > available * 0.000001) {
          skipped.add(
            '$coin: còn ${available - requestedQuantity} dưới bước khối lượng của market.',
          );
        }
        completed.add(
          'Bán $coin $available qua $marketId '
          '(${filled['filled'] ?? 0} đã khớp)',
        );
      } catch (error) {
        failed.add('Bán $coin qua $marketId: $error');
      }
    }

    return {
      'completed': completed,
      'skipped': skipped,
      'failed': failed,
      'positionsDetected': detectedPositionCount,
      'closedPositions': closedPositions,
      'complete': skipped.isEmpty && failed.isEmpty,
    };
  }

  Future<Map<String, dynamic>> createOrder({
    required String category,
    required String symbol,
    required String type,
    required String side,
    required double amount,
    double? price,
    Map<String, Object?> params = const {},
  }) async {
    _validateCategory(category);
    final normalizedType = type.toLowerCase();
    final normalizedSide = side.toLowerCase();
    if (!const {'market', 'limit'}.contains(normalizedType) ||
        !const {'buy', 'sell'}.contains(normalizedSide) ||
        !amount.isFinite ||
        amount <= 0) {
      throw const FormatException('Thông tin lệnh không hợp lệ.');
    }
    if (normalizedType == 'limit' && (price == null || price <= 0)) {
      throw const FormatException('Lệnh Limit cần giá hợp lệ.');
    }
    final triggerPrice = _number(params['triggerPrice']);
    final body = <String, Object?>{
      'category': category,
      'symbol': symbol,
      'side': normalizedSide == 'buy' ? 'Buy' : 'Sell',
      'orderType':
          triggerPrice != null
              ? (params['triggerOrderType'] ?? 'Market')
              : normalizedType == 'market'
              ? 'Market'
              : 'Limit',
      'qty': _formatOrderAmount(category, symbol, amount),
      'timeInForce':
          params['timeInForce'] ?? (normalizedType == 'market' ? 'IOC' : 'GTC'),
      'positionIdx': params['positionIdx'] ?? 0,
      'reduceOnly': params['reduceOnly'] ?? false,
      if (normalizedType == 'limit')
        'price': _formatOrderPrice(category, symbol, price!),
      if (params['marketUnit'] != null) 'marketUnit': params['marketUnit'],
      if (triggerPrice != null) ...{
        'triggerPrice': _formatOrderPrice(category, symbol, triggerPrice),
        'triggerDirection': params['triggerDirection'],
        'triggerBy': params['triggerBy'] ?? 'LastPrice',
        'orderFilter': params['orderFilter'] ?? 'StopOrder',
      },
    };
    final response = await _request(
      'POST',
      '/v5/order/create',
      body: body,
      signed: true,
    );
    final result = response['result'] as Map<String, dynamic>;
    return _normalizeOrder(
      {
        ...result,
        'symbol': symbol,
        'side': normalizedSide,
        'orderType': body['orderType'],
        'qty': body['qty'],
        'price': body['price'] ?? '0',
        'reduceOnly': body['reduceOnly'],
        'triggerPrice': body['triggerPrice'],
        'createdTime': response['time'],
      },
      category: category,
      symbol: symbol,
    );
  }

  Future<Map<String, dynamic>> fetchOrder({
    required String category,
    required String symbol,
    required String id,
  }) async {
    _validateCategory(category);
    final query = {'category': category, 'symbol': symbol, 'orderId': id};
    var response = await _request(
      'GET',
      '/v5/order/realtime',
      query: query,
      signed: true,
    );
    var result = response['result'] as Map<String, dynamic>;
    var list = result['list'] as List<dynamic>;
    if (list.isEmpty) {
      response = await _request(
        'GET',
        '/v5/order/history',
        query: query,
        signed: true,
      );
      result = response['result'] as Map<String, dynamic>;
      list = result['list'] as List<dynamic>;
    }
    if (list.isEmpty || list.first is! Map<String, dynamic>) {
      throw StateError('Bybit chưa tìm thấy trạng thái lệnh $id.');
    }
    return _normalizeOrder(
      list.first as Map<String, dynamic>,
      category: category,
      symbol: symbol,
    );
  }

  Map<String, dynamic> _normalizeOrder(
    Map<String, dynamic> raw, {
    required String category,
    required String symbol,
  }) {
    final amount = _number(raw['qty']);
    final filled = _number(raw['cumExecQty']) ?? 0;
    final remaining =
        _number(raw['leavesQty']) ??
        (amount == null
            ? null
            : (amount - filled).clamp(0, double.infinity).toDouble());
    final rawStatus = '${raw['orderStatus'] ?? 'New'}';
    final status = switch (rawStatus.toLowerCase()) {
      'filled' => 'closed',
      'cancelled' || 'canceled' => 'canceled',
      'rejected' => 'rejected',
      'deactivated' => 'expired',
      _ => 'open',
    };
    final timestamp = int.tryParse(
      '${raw['updatedTime'] ?? raw['createdTime'] ?? ''}',
    );
    return {
      'id': raw['orderId'],
      'clientOrderId': raw['orderLinkId'],
      'timestamp': timestamp,
      'datetime':
          timestamp == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(
                timestamp,
                isUtc: true,
              ).toIso8601String(),
      'symbol': _markets[category]?[symbol]?['symbol'] ?? symbol,
      'type': '${raw['orderType'] ?? 'Market'}'.toLowerCase(),
      'timeInForce': raw['timeInForce'],
      'side': '${raw['side'] ?? ''}'.toLowerCase(),
      'amount': amount,
      'price': _number(raw['price']),
      'average': _number(raw['avgPrice']),
      'filled': filled,
      'remaining': remaining,
      'cost': _number(raw['cumExecValue']),
      'status': status,
      'reduceOnly': raw['reduceOnly'] == true || raw['reduceOnly'] == 'true',
      'stopPrice': _number(raw['triggerPrice']),
      'fee': {
        'cost': _number(raw['cumExecFee']),
        'currency': raw['feeCurrency'],
      },
      'info': raw,
    };
  }

  Future<Map<String, dynamic>> cancelOrder({
    required String category,
    required String symbol,
    required String id,
    Map<String, Object?> params = const {},
  }) async {
    _validateCategory(category);
    final response = await _request(
      'POST',
      '/v5/order/cancel',
      body: {
        'category': category,
        'symbol': symbol,
        'orderId': id,
        if (params['orderFilter'] != null) 'orderFilter': params['orderFilter'],
      },
      signed: true,
    );
    return {
      'id': id,
      'symbol': _markets[category]?[symbol]?['symbol'] ?? symbol,
      'status': 'canceled',
      'info': response['result'],
    };
  }

  Future<void> setLeverage({
    required String category,
    required String symbol,
    required String leverage,
    bool isolated = true,
  }) async {
    if (category != 'linear' && category != 'inverse') {
      throw ArgumentError.value(category, 'category', 'Must be a derivative.');
    }
    if (isolated) {
      try {
        await _request(
          'POST',
          '/v5/position/switch-isolated',
          body: {
            'category': category,
            'symbol': symbol,
            'tradeMode': 1,
            'buyLeverage': leverage,
            'sellLeverage': leverage,
            'positionIdx': 0,
          },
          signed: true,
        );
      } on BybitApiException catch (error) {
        if (error.code != 110026) rethrow;
      }
    }
    try {
      await _request(
        'POST',
        '/v5/position/set-leverage',
        body: {
          'category': category,
          'symbol': symbol,
          'buyLeverage': leverage,
          'sellLeverage': leverage,
        },
        signed: true,
      );
    } on BybitApiException catch (error) {
      if (error.code != 110043) rethrow;
    }
  }

  Future<void> setTradingStop({
    required String category,
    required String symbol,
    required String stopLoss,
  }) async {
    await _request(
      'POST',
      '/v5/position/trading-stop',
      body: {
        'category': category,
        'symbol': symbol,
        'tpslMode': 'Full',
        'positionIdx': 0,
        'stopLoss': stopLoss,
        'slTriggerBy': 'MarkPrice',
        'slOrderType': 'Market',
      },
      signed: true,
    );
  }

  String _formatAmount(double amount) =>
      amount.toStringAsFixed(12).replaceFirst(RegExp(r'\.?0+$'), '');

  String _formatOrderAmount(String category, String symbol, double amount) {
    final market =
        _markets[category]?[symbol] ??
        _markets[category]?.values
            .where((candidate) => candidate['id'] == symbol)
            .firstOrNull;
    final lot = market?['lotSizeFilter'] as Map<String, dynamic>? ?? const {};
    final stepText = '${lot['qtyStep'] ?? ''}';
    final step = _number(stepText);
    if (step == null || step <= 0) return _formatAmount(amount);
    final normalized = (amount / step).floorToDouble() * step;
    final decimals = _decimalPlaces(stepText) ?? 12;
    if (normalized <= 0) {
      throw const FormatException(
        'Khối lượng nhỏ hơn độ chính xác của market.',
      );
    }
    return normalized.toStringAsFixed(decimals);
  }

  String _formatOrderPrice(String category, String symbol, double price) {
    final market =
        _markets[category]?[symbol] ??
        _markets[category]?.values
            .where((candidate) => candidate['id'] == symbol)
            .firstOrNull;
    final filter = market?['priceFilter'] as Map<String, dynamic>? ?? const {};
    final tickText = '${filter['tickSize'] ?? ''}';
    final tick = _number(tickText);
    if (tick == null || tick <= 0) return _formatAmount(price);
    final normalized = (price / tick).roundToDouble() * tick;
    return normalized.toStringAsFixed(_decimalPlaces(tickText) ?? 12);
  }

  double? _number(Object? value) {
    if (value == null || value == '') return null;
    if (value is num) return value.toDouble();
    return double.tryParse('$value');
  }

  void _validateCategory(String category) {
    if (!const {'spot', 'linear', 'inverse', 'option'}.contains(category)) {
      throw FormatException('Loại market Bybit không hỗ trợ: $category');
    }
  }

  void close() => _http.close();
}
