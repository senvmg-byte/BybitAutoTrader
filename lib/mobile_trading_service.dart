import 'dart:async';
import 'dart:convert';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'bybit_ccxt_adapter.dart';
import 'trading_strategy.dart';

const _configKey = 'mobile_bot_config';
const _liveStateKey = 'mobile_bot_state';
const _demoStateKey = 'mobile_bot_demo_state';
const _statusKey = 'mobile_bot_status';
const _apiKeyStorageKey = 'bybit_api_key';
const _apiSecretStorageKey = 'bybit_api_secret';
const _demoApiKeyStorageKey = 'bybit_demo_api_key';
const _demoApiSecretStorageKey = 'bybit_demo_api_secret';
const _secureStorage = FlutterSecureStorage();

@pragma('vm:entry-point')
void startMobileTradingService() {
  FlutterForegroundTask.setTaskHandler(MobileTradingTaskHandler());
}

class MobileTradingTaskHandler extends TaskHandler {
  bool _busy = false;
  BybitCcxtAdapter? _client;
  String _activeStateKey = _liveStateKey;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await _tick();
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    unawaited(_tick());
  }

  @override
  void onReceiveData(Object data) {
    if (data == 'stop') unawaited(FlutterForegroundTask.stopService());
    if (data == 'tick') unawaited(_tick());
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _client?.close();
    _client = null;
  }

  Future<void> _tick() async {
    if (_busy) return;
    _busy = true;
    try {
      final configJson = await FlutterForegroundTask.getData<String>(
        key: _configKey,
      );
      if (configJson == null) throw StateError('Thiếu cấu hình giao dịch.');
      final config = jsonDecode(configJson) as Map<String, dynamic>;
      final category = config['category'] as String;
      final symbol = config['symbol'] as String;
      final strategy = config['strategy'] as String;
      final direction = config['direction'] as String;
      final mode = config['mode'] as String;
      final maxOrder = (config['maxOrderUsdt'] as num).toDouble();
      if (!['spot', 'linear', 'inverse', 'option'].contains(category) ||
          !strategyProfiles.containsKey(strategy) ||
          !['long', 'short', 'both'].contains(direction) ||
          !['paper', 'live'].contains(mode) ||
          !maxOrder.isFinite ||
          maxOrder < 5 ||
          (category == 'spot' || category == 'option') && direction != 'long') {
        throw const FormatException('Cấu hình bot không hợp lệ.');
      }
      _activeStateKey = mode == 'paper' ? _demoStateKey : _liveStateKey;
      final apiKey =
          await _secureStorage.read(
            key: mode == 'paper' ? _demoApiKeyStorageKey : _apiKeyStorageKey,
          ) ??
          '';
      final apiSecret =
          await _secureStorage.read(
            key:
                mode == 'paper'
                    ? _demoApiSecretStorageKey
                    : _apiSecretStorageKey,
          ) ??
          '';
      _client?.close();
      final client = BybitCcxtAdapter(
        apiKey: apiKey,
        apiSecret: apiSecret,
        isDemo: mode == 'paper',
      );
      _client = client;
      final accountBalance = await client.fetchBalance();

      var state = await _loadState();
      final previousPosition = state['position'] as Map<String, dynamic>?;
      if (previousPosition != null &&
          (previousPosition['category'] != category ||
              previousPosition['symbol'] != symbol ||
              previousPosition['mode'] != mode)) {
        throw StateError(
          'Đang có vị thế bot ở market/chế độ khác. Đóng hoặc đối soát vị thế đó trước.',
        );
      }
      final market = await client.fetchMarket(
        category: category,
        symbol: symbol,
      );
      if (market['active'] != true) {
        throw StateError('Market $symbol không ở trạng thái giao dịch.');
      }
      final sourceCategory = category == 'option' ? 'spot' : category;
      final sourceSymbol =
          category == 'option' ? '${_optionUnderlying(symbol)}USDT' : symbol;
      final interval = strategyProfiles[strategy]!['timeframe']! as String;
      final candleData = await client.fetchOHLCV(
        category: sourceCategory,
        symbol: sourceSymbol,
        timeframe: interval == '5' ? '5m' : '4h',
      );
      if (candleData.length < 60) {
        throw StateError('Bybit chưa trả đủ nến để tính tín hiệu.');
      }
      final completedCandles =
          candleData.length > 1
              ? candleData.sublist(0, candleData.length - 1)
              : candleData;
      final analysis = analyzeCandles(completedCandles, strategy);
      if (analysis == null) throw StateError('Dữ liệu nến chưa hợp lệ.');

      final ticker = await client.fetchTicker(
        category: category,
        symbol: symbol,
      );
      final livePrice = _marketPrice(category, ticker, state['position']);
      if (!livePrice.isFinite || livePrice <= 0) {
        throw StateError('Bybit không trả giá hợp lệ cho $symbol.');
      }
      state = await _managePosition(
        client: client,
        category: category,
        symbol: symbol,
        market: market,
        mode: mode,
        direction: direction,
        maxOrder: maxOrder,
        price: livePrice,
        analysis: analysis,
        state: state,
      );
      final status = <String, Object?>{
        'running': true,
        'mode': mode,
        'category': category,
        'symbol': symbol,
        'strategy': strategy,
        'direction': direction,
        'timeframe': strategy == 'short_wave' ? '5m' : '4h',
        'price': livePrice,
        'streamCategory': sourceCategory,
        'streamSymbol': sourceSymbol,
        'analysisSourceSymbol': sourceSymbol,
        'analysis': analysis,
        'position': state['position'],
        'trades': state['trades'],
        'exchangeBalance': accountBalance,
        'executionEnvironment': mode == 'paper' ? 'DEMO' : 'LIVE',
        'lastError': null,
        'updatedAt': DateTime.now().toIso8601String(),
      };
      await _publish(status);
    } catch (error) {
      final status = await _readStatus();
      status['running'] = true;
      status['lastError'] = error.toString();
      status['updatedAt'] = DateTime.now().toIso8601String();
      await _publish(status);
    } finally {
      _busy = false;
      _client?.close();
      _client = null;
    }
  }

  Future<Map<String, dynamic>> _loadState() async {
    final stored = await FlutterForegroundTask.getData<String>(
      key: _activeStateKey,
    );
    if (stored != null) {
      return Map<String, dynamic>.from(jsonDecode(stored) as Map);
    }
    return {
      'lastProcessedCandle': 0,
      'position': null,
      'trades': <Map<String, Object?>>[],
    };
  }

  Future<Map<String, dynamic>> _managePosition({
    required BybitCcxtAdapter client,
    required String category,
    required String symbol,
    required Map<String, dynamic> market,
    required String mode,
    required String direction,
    required double maxOrder,
    required double price,
    required Map<String, Object?> analysis,
    required Map<String, dynamic> state,
  }) async {
    final position = state['position'] as Map<String, dynamic>?;
    if (position?['pending'] == true) {
      throw StateError(
        'Lệnh đang chờ xác nhận. Kiểm tra Orders/Positions trên Bybit.',
      );
    }
    if (position != null) {
      final isLong = position['side'] == 'long';
      final stopPrice = (position['stopPrice'] as num).toDouble();
      final signal = analysis['signal'];
      final previousFavorable =
          (position['favorablePrice'] as num?)?.toDouble() ??
          (position['entryPrice'] as num).toDouble();
      position['favorablePrice'] =
          isLong
              ? mathMax(previousFavorable, price)
              : mathMin(previousFavorable, price);
      final shouldExit =
          isLong
              ? signal == 'exit_long' || signal == 'short' || price <= stopPrice
              : signal == 'exit_short' ||
                  signal == 'long' ||
                  price >= stopPrice;
      if (shouldExit) {
        await _closePosition(
          client: client,
          category: category,
          symbol: symbol,
          position: position,
          price: price,
          reason: '${analysis['reason']}',
          state: state,
        );
        await _saveState(state);
        return state;
      }

      final currentStage = (position['takeProfitStage'] as num?)?.toInt() ?? 0;
      final advancedRiskEnabled =
          (category == 'spot' || category == 'linear') &&
          position['riskManagementVersion'] == 1;
      if (advancedRiskEnabled && currentStage < 2) {
        final nextStage = currentStage + 1;
        final entryPrice = (position['entryPrice'] as num).toDouble();
        final initialStop =
            (position['initialStopPrice'] as num?)?.toDouble() ?? stopPrice;
        final target = takeProfitPrice(
          side: isLong ? 'long' : 'short',
          entryPrice: entryPrice,
          initialStopPrice: initialStop,
          stage: nextStage,
        );
        final reached = isLong ? price >= target : price <= target;
        if (reached) {
          final originalQuantity =
              (position['originalQuantity'] as num?)?.toDouble() ??
              (position['quantity'] as num).toDouble();
          final partialQuantity = _partialQuantity(
            category: category,
            originalQuantity: originalQuantity,
            price: price,
            market: market,
            fraction: nextStage == 1 ? 0.5 : 0.25,
          );
          position['takeProfitStage'] = nextStage;
          if (partialQuantity > 0) {
            await _closePartialPosition(
              client: client,
              category: category,
              symbol: symbol,
              market: market,
              position: position,
              quantity: partialQuantity,
              price: price,
              stage: nextStage,
              state: state,
            );
          } else {
            position['takeProfitStage'] = nextStage;
            position['takeProfitSkippedStage'] = nextStage;
            await _saveState(state);
          }
        }
      }

      if (state['position'] != null && position['takeProfitFilled'] == true) {
        final currentStop = (position['stopPrice'] as num).toDouble();
        final favorable = (position['favorablePrice'] as num).toDouble();
        final trailing = trailingStopPrice(
          side: isLong ? 'long' : 'short',
          entryPrice: (position['entryPrice'] as num).toDouble(),
          currentStopPrice: currentStop,
          favorablePrice: favorable,
          atrValue: (analysis['atr'] as num).toDouble(),
        );
        final tickFilter =
            market['priceFilter'] as Map<String, dynamic>? ?? const {};
        final tickSize =
            double.tryParse('${tickFilter['tickSize'] ?? 0.00000001}') ??
            0.00000001;
        final safeTrailing =
            isLong
                ? mathMin(trailing, price - tickSize)
                : mathMax(trailing, price + tickSize);
        final tightens =
            isLong ? safeTrailing > currentStop : safeTrailing < currentStop;
        if (tightens) {
          await _updatePositionStop(
            client: client,
            category: category,
            symbol: symbol,
            market: market,
            position: position,
            stopPrice: safeTrailing,
            state: state,
          );
        }
      }
      await _saveState(state);
      return state;
    }

    final candleTime = (analysis['candleTimestamp'] as num).toInt();
    if (candleTime <= (state['lastProcessedCandle'] as num).toInt()) {
      await _saveState(state);
      return state;
    }
    state['lastProcessedCandle'] = candleTime;
    final signal = analysis['signal'];
    final supportsShort = category == 'linear' || category == 'inverse';
    final side =
        signal == 'long' && direction != 'short'
            ? 'long'
            : signal == 'short' &&
                supportsShort &&
                (direction == 'short' || direction == 'both')
            ? 'short'
            : null;
    if (side == null) {
      await _saveState(state);
      return state;
    }

    final summary = accountBalance['summary'] as Map?;
    final equityValue = summary?['totalEquity'] as num?;
    final availableValue = summary?['totalAvailableBalance'] as num?;
    if (equityValue == null ||
        !equityValue.isFinite ||
        equityValue <= 0 ||
        availableValue == null ||
        !availableValue.isFinite ||
        availableValue <= 0) {
      throw StateError(
        'Bybit không trả về equity và số dư khả dụng hợp lệ; bot bỏ qua lệnh để tránh tính sai rủi ro.',
      );
    }
    final equity = equityValue.toDouble();
    final freeBalances = accountBalance['free'] as Map?;
    final quoteCoin = '${market['quote'] ?? ''}';
    final spotCash = freeBalances?[quoteCoin] as num?;
    final cash =
        category == 'spot'
            ? spotCash?.toDouble() ?? 0
            : availableValue.toDouble();
    if (!cash.isFinite || cash <= 0) {
      throw StateError(
        category == 'spot'
            ? 'Không có số dư khả dụng bằng $quoteCoin để mở lệnh Spot.'
            : 'Bybit không trả về số dư khả dụng để mở lệnh.',
      );
    }
    final atrValue = (analysis['atr'] as num).toDouble();
    final entry = price * (side == 'long' ? 1.0005 : 0.9995);
    final stop =
        category == 'spot' || category == 'linear'
            ? structureStopPrice(
              side: side,
              referencePrice: price,
              atrValue: atrValue,
              swingLow: (analysis['swingLow'] as num?)?.toDouble(),
              swingHigh: (analysis['swingHigh'] as num?)?.toDouble(),
              atrBuffer: 0.4,
            )
            : side == 'long'
            ? entry -
                (category == 'option'
                    ? price * 0.5
                    : mathMax(2 * atrValue, price * 0.01))
            : entry +
                (category == 'option'
                    ? price * 0.5
                    : mathMax(2 * atrValue, price * 0.01));
    final stopDistance = (entry - stop).abs();
    final quoteAmount = sizePosition(
      equity: equity,
      cash: cash,
      price: price,
      stopDistance: stopDistance,
      maxOrder: maxOrder,
      riskFraction: 0.005,
    );
    if (quoteAmount < 5) {
      await _saveState(state);
      throw StateError(
        'Lệnh bị bỏ qua: sizing theo equity/số dư thật và rủi ro 0,5% '
        'cho khối lượng dưới mức tối thiểu 5 USDT.',
      );
    }
    final quantity = _quantity(category, quoteAmount, price, market);
    if (quantity <= 0) throw StateError('Khối lượng lệnh không hợp lệ.');
    final newPosition = <String, Object?>{
      'mode': mode,
      'side': side,
      'symbol': symbol,
      'category': category,
      'quantity': quantity,
      'originalQuantity': quantity,
      'entryPrice': entry,
      'stopPrice': stop,
      'initialStopPrice': stop,
      'favorablePrice': entry,
      'takeProfitStage': 0,
      'riskManagementVersion': 1,
      'costQuote': quoteAmount,
      'equityAtEntry': equity,
      'riskBudget': equity * 0.005,
      'contractSize': market['contractSize'] ?? 1,
      'pending': true,
    };
    state['position'] = newPosition;
    await _saveState(state);
    if (category == 'linear' || category == 'inverse') {
      await client.setLeverage(
        category: category,
        symbol: symbol,
        leverage: '1',
      );
    }
    final order = await client.createOrder(
      category: category,
      symbol: symbol,
      type: 'market',
      side: side == 'long' ? 'buy' : 'sell',
      amount: quantity,
      params: {if (category == 'spot') 'marketUnit': 'baseCoin'},
    );
    final orderId = order['id'];
    if (orderId == null || orderId.toString().isEmpty) {
      throw StateError('Bybit không xác nhận orderId; hãy kiểm tra sàn.');
    }
    newPosition['orderId'] = orderId;
    await _saveState(state);
    Map<String, dynamic>? confirmedOrder;
    for (var attempt = 0; attempt < 5; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      confirmedOrder = await client.fetchOrder(
        category: category,
        symbol: symbol,
        id: orderId.toString(),
      );
      if (confirmedOrder['status'] == 'closed') break;
    }
    final filledOrder = confirmedOrder;
    if (filledOrder == null || filledOrder['status'] != 'closed') {
      throw StateError(
        'Bybit chưa xác nhận lệnh đã khớp. Kiểm tra Orders trên sàn trước khi chạy lại.',
      );
    }
    final filledQuantity = filledOrder['filled'] as double?;
    if (filledQuantity == null || filledQuantity <= 0) {
      throw StateError('Bybit chưa xác nhận khối lượng khớp.');
    }
    newPosition['quantity'] = filledQuantity;
    newPosition['entryPrice'] = filledOrder['average'] as double? ?? entry;
    newPosition['costQuote'] =
        category == 'inverse'
            ? quoteAmount
            : filledQuantity *
                (double.tryParse('${market['contractSize'] ?? 1}') ?? 1) *
                (newPosition['entryPrice'] as double);
    final filledEntry = newPosition['entryPrice'] as double;
    newPosition['stopPrice'] =
        side == 'long'
            ? filledEntry - stopDistance
            : filledEntry + stopDistance;
    newPosition['initialStopPrice'] = newPosition['stopPrice'];
    newPosition['favorablePrice'] = filledEntry;
    newPosition['pending'] = false;
    _recordTrade(state, {
      'symbol': symbol,
      'category': category,
      'side': side == 'long' ? 'buy' : 'sell',
      'type': 'market',
      'status': filledOrder['status'],
      'orderId': orderId,
      'price': filledEntry,
      'quantity': filledQuantity,
      'cost': filledOrder['cost'],
      'fee': filledOrder['fee'],
      'timestamp': DateTime.now().toIso8601String(),
    });
    if (category == 'linear' || category == 'inverse') {
      try {
        await client.setTradingStop(
          category: category,
          symbol: symbol,
          stopLoss: _formatPrice(
            newPosition['stopPrice'] as double,
            market,
            roundUp: side == 'long',
          ),
        );
      } catch (error) {
        newPosition['pending'] = true;
        await _saveState(state);
        throw StateError(
          'Đặt stop-loss thất bại sau khi đã gửi lệnh. Kiểm tra Bybit ngay: $error',
        );
      }
    } else if (category == 'spot') {
      try {
        final stopOrder = await client.createOrder(
          category: category,
          symbol: symbol,
          type: 'market',
          side: 'sell',
          amount: filledQuantity,
          params: {
            'triggerPrice': _formatPrice(
              newPosition['stopPrice'] as double,
              market,
              roundUp: true,
            ),
            'triggerDirection': 2,
            'triggerBy': 'LastPrice',
            'marketUnit': 'baseCoin',
          },
        );
        newPosition['stopOrderId'] = stopOrder['id'];
      } catch (error) {
        newPosition['pending'] = true;
        await _saveState(state);
        throw StateError(
          'Đặt stop-loss Spot thất bại sau khi đã gửi lệnh. Kiểm tra Bybit ngay: $error',
        );
      }
    }
    await _saveState(state);
    return state;
  }

  Future<void> _closePosition({
    required BybitCcxtAdapter client,
    required String category,
    required String symbol,
    required Map<String, dynamic> position,
    required double price,
    required String reason,
    required Map<String, dynamic> state,
  }) async {
    Map<String, dynamic>? confirmedClose;
    position['pending'] = true;
    await _saveState(state);
    final stopOrderId = position['stopOrderId']?.toString();
    if (stopOrderId != null && stopOrderId.isNotEmpty) {
      await client.cancelOrder(
        category: category,
        symbol: symbol,
        id: stopOrderId,
        params: const {'orderFilter': 'StopOrder'},
      );
    }
    if (category == 'linear' || category == 'inverse') {
      await client.setTradingStop(
        category: category,
        symbol: symbol,
        stopLoss: '0',
      );
    }
    final order = await client.createOrder(
      category: category,
      symbol: symbol,
      type: 'market',
      side: position['side'] == 'long' ? 'sell' : 'buy',
      amount: (position['quantity'] as num).toDouble(),
      params: {
        'reduceOnly': category == 'linear' || category == 'inverse',
        if (category == 'spot') 'marketUnit': 'baseCoin',
      },
    );
    final orderId = order['id']?.toString();
    if (orderId == null || orderId.isEmpty) {
      throw StateError('Bybit không xác nhận orderId đóng vị thế.');
    }
    for (var attempt = 0; attempt < 5; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      confirmedClose = await client.fetchOrder(
        category: category,
        symbol: symbol,
        id: orderId,
      );
      if (confirmedClose['status'] == 'closed') break;
    }
    if (confirmedClose?['status'] != 'closed') {
      throw StateError(
        'Bybit chưa xác nhận khớp lệnh đóng. Kiểm tra vị thế ngay.',
      );
    }
    state['position'] = null;
    _recordTrade(state, {
      'symbol': symbol,
      'category': category,
      'side': position['side'] == 'long' ? 'sell' : 'cover',
      'type': 'market',
      'status': confirmedClose?['status'],
      'orderId': confirmedClose?['id'],
      'price': confirmedClose?['average'] ?? price,
      'quantity': position['quantity'],
      'entryPrice': position['entryPrice'],
      'cost': confirmedClose?['cost'],
      'fee': confirmedClose?['fee'],
      'reason': reason,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  Future<void> _closePartialPosition({
    required BybitCcxtAdapter client,
    required String category,
    required String symbol,
    required Map<String, dynamic> market,
    required Map<String, dynamic> position,
    required double quantity,
    required double price,
    required int stage,
    required Map<String, dynamic> state,
  }) async {
    position['pending'] = true;
    await _saveState(state);
    final order = await client.createOrder(
      category: category,
      symbol: symbol,
      type: 'market',
      side: position['side'] == 'long' ? 'sell' : 'buy',
      amount: quantity,
      params: {
        if (category == 'linear' || category == 'inverse') 'reduceOnly': true,
        if (category == 'spot') 'marketUnit': 'baseCoin',
      },
    );
    final orderId = order['id']?.toString();
    if (orderId == null || orderId.isEmpty) {
      throw StateError('Bybit không xác nhận orderId chốt lời từng phần.');
    }
    Map<String, dynamic>? confirmed;
    for (var attempt = 0; attempt < 5; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      confirmed = await client.fetchOrder(
        category: category,
        symbol: symbol,
        id: orderId,
      );
      if (confirmed['status'] == 'closed') break;
    }
    final filledOrder = confirmed;
    final filled = filledOrder?['filled'] as double? ?? 0;
    if (filledOrder == null ||
        filledOrder['status'] != 'closed' ||
        filled <= 0 ||
        quantity - filled > quantity * 0.000001) {
      throw StateError(
        'Bybit chưa xác nhận chốt lời đủ khối lượng. Kiểm tra lệnh trên sàn.',
      );
    }
    final remaining =
        ((position['quantity'] as num).toDouble() - filled)
            .clamp(0, double.infinity)
            .toDouble();
    _recordTrade(state, {
      'symbol': symbol,
      'category': category,
      'side': position['side'] == 'long' ? 'sell' : 'buy',
      'type': 'market',
      'status': filledOrder['status'],
      'orderId': orderId,
      'price': filledOrder['average'] ?? price,
      'quantity': filled,
      'entryPrice': position['entryPrice'],
      'cost': filledOrder['cost'],
      'fee': filledOrder['fee'],
      'reason': 'Chốt lời từng phần TP$stage',
      'timestamp': DateTime.now().toIso8601String(),
    });
    if (remaining <= 0) {
      state['position'] = null;
      await _saveState(state);
      return;
    }
    position['quantity'] = remaining;
    position['takeProfitFilled'] = true;
    position['pending'] = false;
    if (category == 'spot') {
      await _updatePositionStop(
        client: client,
        category: category,
        symbol: symbol,
        market: market,
        position: position,
        stopPrice: (position['stopPrice'] as num).toDouble(),
        state: state,
      );
    }
    await _saveState(state);
  }

  Future<void> _updatePositionStop({
    required BybitCcxtAdapter client,
    required String category,
    required String symbol,
    required Map<String, dynamic> market,
    required Map<String, dynamic> position,
    required double stopPrice,
    required Map<String, dynamic> state,
  }) async {
    try {
      if (category == 'linear' || category == 'inverse') {
        await client.setTradingStop(
          category: category,
          symbol: symbol,
          stopLoss: _formatPrice(
            stopPrice,
            market,
            roundUp: position['side'] == 'long',
          ),
        );
      } else if (category == 'spot') {
        final oldStopId = position['stopOrderId']?.toString();
        if (oldStopId != null && oldStopId.isNotEmpty) {
          await client.cancelOrder(
            category: category,
            symbol: symbol,
            id: oldStopId,
            params: const {'orderFilter': 'StopOrder'},
          );
        }
        final stopOrder = await client.createOrder(
          category: category,
          symbol: symbol,
          type: 'market',
          side: 'sell',
          amount: (position['quantity'] as num).toDouble(),
          params: {
            'triggerPrice': _formatPrice(stopPrice, market, roundUp: true),
            'triggerDirection': 2,
            'triggerBy': 'LastPrice',
            'marketUnit': 'baseCoin',
          },
        );
        final stopOrderId = stopOrder['id']?.toString();
        if (stopOrderId == null || stopOrderId.isEmpty) {
          throw StateError('Bybit không trả orderId cho stop-loss Spot.');
        }
        position['stopOrderId'] = stopOrderId;
      }
      position['stopPrice'] = stopPrice;
      position['pending'] = false;
      await _saveState(state);
    } catch (error) {
      position['pending'] = true;
      await _saveState(state);
      throw StateError(
        'Không thể cập nhật stop-loss trên Bybit. Kiểm tra vị thế và lệnh bảo vệ ngay: $error',
      );
    }
  }

  void _recordTrade(Map<String, dynamic> state, Map<String, dynamic> trade) {
    final trades = List<Map<String, dynamic>>.from(
      (state['trades'] as List? ?? const []).whereType<Map>(),
    )..add(trade);
    state['trades'] =
        trades.length > 50 ? trades.sublist(trades.length - 50) : trades;
  }

  double _quantity(
    String category,
    double quoteAmount,
    double price,
    Map<String, dynamic> market,
  ) {
    final lot = market['lotSizeFilter'] as Map<String, dynamic>? ?? const {};
    final step = double.tryParse('${lot['qtyStep'] ?? 0.000001}') ?? 0.000001;
    final contractValue =
        double.tryParse('${market['contractSize'] ?? 1}') ?? 1;
    final raw = switch (category) {
      'spot' => quoteAmount / price,
      'inverse' => quoteAmount / contractValue,
      'option' => quoteAmount / price / contractValue,
      _ => quoteAmount / price / contractValue,
    };
    final normalized = (raw / step).floorToDouble() * step;
    final minimum = double.tryParse('${lot['minOrderQty'] ?? 0}') ?? 0;
    if (normalized < minimum) {
      throw StateError('Khối lượng nhỏ hơn mức tối thiểu của sàn.');
    }
    final maximum =
        double.tryParse(
          '${lot['maxMktOrderQty'] ?? lot['maxOrderQty'] ?? 0}',
        ) ??
        0;
    if (maximum > 0 && normalized > maximum) {
      throw StateError('Khối lượng vượt giới hạn market order của sàn.');
    }
    final minimumNotional =
        double.tryParse('${lot['minNotionalValue'] ?? 0}') ?? 0;
    final notional =
        category == 'inverse'
            ? normalized * contractValue
            : normalized * contractValue * price;
    if (notional < minimumNotional) {
      throw StateError('Giá trị lệnh nhỏ hơn minNotionalValue của sàn.');
    }
    return normalized;
  }

  double _partialQuantity({
    required String category,
    required double originalQuantity,
    required double price,
    required Map<String, dynamic> market,
    required double fraction,
  }) {
    final lot = market['lotSizeFilter'] as Map<String, dynamic>? ?? const {};
    final stepText = '${lot['qtyStep'] ?? 0.000001}';
    final step = double.tryParse(stepText) ?? 0.000001;
    if (!step.isFinite || step <= 0) return 0;
    final quantity =
        (originalQuantity * fraction / step).floorToDouble() * step;
    final minimum = double.tryParse('${lot['minOrderQty'] ?? 0}') ?? 0;
    final contractSize = double.tryParse('${market['contractSize'] ?? 1}') ?? 1;
    final notional =
        category == 'inverse'
            ? quantity * contractSize
            : quantity * contractSize * price;
    final minimumNotional =
        double.tryParse('${lot['minNotionalValue'] ?? 0}') ?? 0;
    if (quantity < minimum || quantity <= 0 || notional < minimumNotional) {
      return 0;
    }
    return quantity;
  }

  String _formatPrice(
    double price,
    Map<String, dynamic> market, {
    required bool roundUp,
  }) {
    final filter = market['priceFilter'] as Map<String, dynamic>? ?? const {};
    final tickText = '${filter['tickSize'] ?? '0.00000001'}';
    final tick = double.tryParse(tickText) ?? 0.00000001;
    if (tick <= 0 || !tick.isFinite) {
      throw StateError('Tick size của market không hợp lệ.');
    }
    final ticks = price / tick;
    final roundedTicks = roundUp ? ticks.ceilToDouble() : ticks.floorToDouble();
    final normalized = roundedTicks * tick;
    final exponentIndex = tickText.toLowerCase().indexOf('e-');
    final decimals =
        exponentIndex >= 0
            ? int.tryParse(tickText.substring(exponentIndex + 2)) ?? 8
            : tickText.contains('.')
            ? tickText.split('.').last.length
            : 0;
    return normalized.toStringAsFixed(decimals);
  }

  double _marketPrice(
    String category,
    Map<String, dynamic> ticker,
    Map<String, dynamic>? position,
  ) {
    if (category == 'option') {
      final bid = ticker['bid'] as double?;
      final ask = ticker['ask'] as double?;
      if (bid == null ||
          ask == null ||
          bid <= 0 ||
          ask < bid ||
          (ask - bid) / ((ask + bid) / 2) > 0.2) {
        return double.nan;
      }
      return position == null ? ask : bid;
    }
    return ticker['last'] as double? ?? double.nan;
  }

  String _optionUnderlying(String symbol) => symbol.split('-').first;

  Future<void> _saveState(Map<String, dynamic> state) async {
    await FlutterForegroundTask.saveData(
      key: _activeStateKey,
      value: jsonEncode(state),
    );
  }

  Future<Map<String, dynamic>> _readStatus() async {
    final json = await FlutterForegroundTask.getData<String>(key: _statusKey);
    if (json == null) return <String, dynamic>{};
    return Map<String, dynamic>.from(jsonDecode(json) as Map);
  }

  Future<void> _publish(Map<String, dynamic> status) async {
    final encoded = jsonEncode(status);
    await FlutterForegroundTask.saveData(key: _statusKey, value: encoded);
    FlutterForegroundTask.sendDataToMain(encoded);
    if (status['running'] == true) {
      await FlutterForegroundTask.updateService(
        notificationTitle: 'Bybit Auto Trader · ${status['mode'] ?? 'BOT'}',
        notificationText:
            status['lastError']?.toString() ??
            '${status['symbol'] ?? ''} · bot đang chạy',
        notificationIcon: const NotificationIcon(
          metaDataName: 'com.example.bybitautotrader.service.BOT_ICON',
        ),
      );
    }
  }
}

double mathMax(double left, double right) => left > right ? left : right;

double mathMin(double left, double right) => left < right ? left : right;
