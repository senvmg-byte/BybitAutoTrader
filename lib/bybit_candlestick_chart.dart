import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class BybitCandlestickChart extends StatefulWidget {
  const BybitCandlestickChart({
    required this.candles,
    required this.category,
    required this.symbol,
    required this.timeframe,
    super.key,
  });

  final List<List<double>> candles;
  final String category;
  final String symbol;
  final String timeframe;

  @override
  State<BybitCandlestickChart> createState() => _BybitCandlestickChartState();
}

class _BybitCandlestickChartState extends State<BybitCandlestickChart>
    with WidgetsBindingObserver {
  static const _green = Color(0xFF66E3C4);
  static const _red = Color(0xFFFF7B78);
  static const _maxCandles = 90;
  static const _maxTickPrices = 60;
  final _candles = <List<double>>[];
  final _tickPrices = <double>[];
  final _renderRevision = ValueNotifier<int>(0);
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  Timer? _renderTimer;
  double? _livePrice;
  bool _connected = false;
  bool _hasPendingCandleUpdate = false;
  int _liveUpdateCount = 0;
  String? _streamError;

  String get _interval => switch (widget.timeframe) {
    '5m' => '5',
    '4h' => '240',
    _ =>
      throw FormatException(
        'Unsupported Bybit candle interval: ${widget.timeframe}',
      ),
  };

  int get _intervalMilliseconds => switch (widget.timeframe) {
    '5m' => 5 * 60 * 1000,
    '4h' => 4 * 60 * 60 * 1000,
    _ =>
      throw FormatException(
        'Unsupported Bybit candle interval: ${widget.timeframe}',
      ),
  };

  String get _socketCategory => switch (widget.category) {
    'spot' => 'spot',
    'linear' => 'linear',
    'inverse' => 'inverse',
    _ =>
      throw FormatException(
        'Unsupported Bybit WebSocket category: ${widget.category}',
      ),
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _replaceCandles(widget.candles);
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      _connect();
    }
  }

  @override
  void didUpdateWidget(covariant BybitCandlestickChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.candles != widget.candles) {
      _replaceCandles(widget.candles);
    }
    if (oldWidget.category != widget.category ||
        oldWidget.symbol != widget.symbol ||
        oldWidget.timeframe != widget.timeframe) {
      _disconnect();
      _connect();
    }
  }

  void _replaceCandles(List<List<double>> candles) {
    final start =
        candles.length > _maxCandles ? candles.length - _maxCandles : 0;
    _candles
      ..clear()
      ..addAll(candles.skip(start).map((candle) => List<double>.of(candle)));
    _tickPrices.clear();
    if (_candles.isNotEmpty) {
      _livePrice = _candles.last[4];
      _tickPrices.add(_livePrice!);
    }
    _liveUpdateCount = 0;
    _renderRevision.value++;
  }

  void _connect() {
    if (!mounted || _channel != null) return;
    final uri = Uri.parse('wss://stream.bybit.com/v5/public/$_socketCategory');
    final channel = WebSocketChannel.connect(uri);
    _channel = channel;
    _subscription = channel.stream.listen(
      _handleMessage,
      onError: (Object error) => _handleDisconnect(error.toString()),
      onDone: () => _handleDisconnect('Kết nối WebSocket đã đóng.'),
      cancelOnError: true,
    );
    _pingTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (!identical(channel, _channel)) return;
      try {
        channel.sink.add(jsonEncode({'op': 'ping'}));
      } catch (error) {
        _handleDisconnect('Không gửi được heartbeat WebSocket: $error');
      }
    });
    unawaited(_activate(channel));
  }

  Future<void> _activate(WebSocketChannel channel) async {
    try {
      await channel.ready;
      if (!mounted || !identical(channel, _channel)) return;
      channel.sink.add(
        jsonEncode({
          'op': 'subscribe',
          'args': [
            'kline.$_interval.${widget.symbol}',
            'tickers.${widget.symbol}',
          ],
        }),
      );
      setState(() {
        _connected = true;
        _streamError = null;
      });
    } catch (error) {
      if (identical(channel, _channel)) {
        _handleDisconnect('Kết nối Bybit WebSocket thất bại: $error');
      }
    }
  }

  void _handleMessage(dynamic event) {
    if (event is! String) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(event);
    } on FormatException catch (error) {
      if (mounted) {
        setState(
          () => _streamError = 'Dữ liệu WebSocket sai định dạng: $error',
        );
      }
      return;
    }
    if (decoded is! Map<String, dynamic>) return;
    if (decoded['op'] == 'subscribe' && decoded['success'] == false) {
      final retMessage = decoded['ret_msg'] ?? 'lỗi đăng ký';
      if (mounted) {
        setState(() {
          _streamError = 'Bybit từ chối đăng ký luồng giá: $retMessage';
        });
      }
      return;
    }
    final topic = decoded['topic'];
    final values = decoded['data'];
    if (topic == 'tickers.${widget.symbol}') {
      _handleTicker(values, timestamp: _timestamp(decoded['ts']));
      return;
    }
    if (topic != 'kline.$_interval.${widget.symbol}' || values is! List) {
      return;
    }
    var changed = false;
    for (final value in values) {
      if (value is! Map<String, dynamic>) continue;
      final candle = _parseCandle(value);
      if (candle == null) continue;
      final candleTimestamp = candle[0].toInt();
      if (_candles.isEmpty || candleTimestamp > _candles.last[0].toInt()) {
        _candles.add(candle);
        changed = true;
      } else if (candleTimestamp == _candles.last[0].toInt()) {
        if (!_sameCandle(_candles.last, candle)) {
          _candles[_candles.length - 1] = candle;
          changed = true;
        }
      } else {
        continue;
      }
      changed |= _recordLivePrice(
        candle[4],
        timestamp: candleTimestamp,
        updateCandle: false,
      );
    }
    if (!changed || !mounted) return;
    if (_candles.length > _maxCandles) {
      _candles.removeRange(0, _candles.length - _maxCandles);
    }
    _queueRender();
  }

  void _handleTicker(Object? data, {int? timestamp}) {
    final tickers =
        data is Map<String, dynamic>
            ? [data]
            : data is List
            ? data.whereType<Map<String, dynamic>>().toList()
            : const <Map<String, dynamic>>[];
    var receivedPrice = false;
    for (final ticker in tickers) {
      final value = ticker['lastPrice'];
      final price = value is num ? value.toDouble() : double.tryParse('$value');
      if (price == null || !price.isFinite || price <= 0) continue;
      receivedPrice |= _recordLivePrice(
        price,
        timestamp: _timestamp(ticker['ts']) ?? timestamp,
      );
    }
    if (receivedPrice) _queueRender();
  }

  bool _recordLivePrice(
    double price, {
    int? timestamp,
    bool updateCandle = true,
  }) {
    if (!price.isFinite || price <= 0 || _livePrice == price) return false;
    if (_candles.isNotEmpty && timestamp != null) {
      final updateCandleStart =
          timestamp ~/ _intervalMilliseconds * _intervalMilliseconds;
      if (updateCandleStart < _candles.last[0].toInt()) return false;
    }
    if (updateCandle) _updateActiveCandle(price, timestamp: timestamp);
    _livePrice = price;
    _tickPrices.add(price);
    _liveUpdateCount++;
    if (_tickPrices.length > _maxTickPrices) {
      _tickPrices.removeRange(0, _tickPrices.length - _maxTickPrices);
    }
    return true;
  }

  void _updateActiveCandle(double price, {int? timestamp}) {
    if (_candles.isEmpty) return;
    final candleStart =
        (timestamp ?? DateTime.now().millisecondsSinceEpoch) ~/
        _intervalMilliseconds *
        _intervalMilliseconds;
    final last = _candles.last;
    if (candleStart < last[0].toInt()) return;
    if (last[0].toInt() < candleStart) {
      _candles.add([candleStart.toDouble(), last[4], price, price, price, 0]);
    } else {
      _candles[_candles.length - 1] = [
        last[0],
        last[1],
        math.max(last[2], price),
        math.min(last[3], price),
        price,
        last.length > 5 ? last[5] : 0,
      ];
    }
    if (_candles.length > _maxCandles) {
      _candles.removeRange(0, _candles.length - _maxCandles);
    }
  }

  int? _timestamp(Object? value) {
    final parsed = value is num ? value.toInt() : int.tryParse('$value');
    if (parsed == null || parsed <= 0) return null;
    return parsed < 1000000000000 ? parsed * 1000 : parsed;
  }

  bool _sameCandle(List<double> left, List<double> right) {
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }

  void _queueRender() {
    _hasPendingCandleUpdate = true;
    _renderTimer ??= Timer(const Duration(milliseconds: 250), () {
      _renderTimer = null;
      if (!mounted || !_hasPendingCandleUpdate) return;
      _hasPendingCandleUpdate = false;
      _renderRevision.value++;
    });
  }

  List<double>? _parseCandle(Map<String, dynamic> value) {
    final fields = [
      value['start'],
      value['open'],
      value['high'],
      value['low'],
      value['close'],
      value['volume'] ?? 0,
    ];
    final candle =
        fields
            .map(
              (field) =>
                  field is num ? field.toDouble() : double.tryParse('$field'),
            )
            .toList();
    if (candle.any((number) => number == null || !number.isFinite)) return null;
    final values = candle.cast<double>();
    if (values[0] <= 0 ||
        values[1] <= 0 ||
        values[2] < values[3] ||
        values[4] <= 0) {
      return null;
    }
    return values;
  }

  void _handleDisconnect(String message) {
    if (!mounted) return;
    _pingTimer?.cancel();
    _pingTimer = null;
    final channel = _channel;
    _channel = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
    unawaited(channel?.sink.close());
    setState(() {
      _connected = false;
      _streamError = message;
    });
    _reconnectTimer ??= Timer(const Duration(seconds: 3), () {
      _reconnectTimer = null;
      if (mounted) _connect();
    });
  }

  void _disconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _renderTimer?.cancel();
    _renderTimer = null;
    _pingTimer?.cancel();
    _pingTimer = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
    final channel = _channel;
    _channel = null;
    unawaited(channel?.sink.close());
    _connected = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _connect();
    } else {
      final wasConnected = _connected;
      _disconnect();
      if (wasConnected && mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _disconnect();
    _renderRevision.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      ValueListenableBuilder<int>(
        valueListenable: _renderRevision,
        builder:
            (context, _, child) => Row(
              children: [
                Icon(
                  Icons.circle,
                  color:
                      _streamError != null
                          ? _red
                          : _connected
                          ? _green
                          : Colors.white38,
                  size: 8,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _streamError != null
                        ? 'Lỗi đăng ký WebSocket'
                        : !_connected
                        ? 'Đang kết nối Bybit...'
                        : _liveUpdateCount == 0
                        ? 'Bybit WS · đang chờ biến động giá'
                        : 'Bybit WS · $_liveUpdateCount cập nhật giá',
                    style: const TextStyle(color: Colors.white60, fontSize: 11),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_livePrice != null)
                  Text(
                    _formatPrice(_livePrice!),
                    style: TextStyle(
                      color:
                          _candles.isEmpty || _livePrice! >= _candles.last[1]
                              ? _green
                              : _red,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
              ],
            ),
      ),
      ValueListenableBuilder<int>(
        valueListenable: _renderRevision,
        builder:
            (context, _, child) =>
                _tickPrices.length > 1
                    ? Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Container(
                        height: 49,
                        padding: const EdgeInsets.fromLTRB(8, 5, 8, 5),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0B1218),
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Row(
                          children: [
                            const Text(
                              'GIÁ LIVE',
                              style: TextStyle(
                                color: Color(0xFF82909B),
                                fontSize: 9,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.5,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: RepaintBoundary(
                                child: CustomPaint(
                                  painter: _LivePriceTracePainter(
                                    _tickPrices,
                                    repaint: _renderRevision,
                                  ),
                                  size: Size.infinite,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                    : const SizedBox.shrink(),
      ),
      if (_streamError != null) ...[
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            _streamError!,
            style: const TextStyle(color: Colors.white38, fontSize: 10),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
      const SizedBox(height: 8),
      Expanded(
        child: RepaintBoundary(
          child: LayoutBuilder(
            builder:
                (context, constraints) => CustomPaint(
                  size: Size(constraints.maxWidth, constraints.maxHeight),
                  painter: _CandlestickPainter(
                    _candles,
                    repaint: _renderRevision,
                  ),
                ),
          ),
        ),
      ),
    ],
  );

  String _formatPrice(double price) =>
      price >= 100 ? price.toStringAsFixed(2) : price.toStringAsPrecision(5);
}

class _CandlestickPainter extends CustomPainter {
  _CandlestickPainter(this.candles, {required Listenable repaint})
    : super(repaint: repaint);

  final List<List<double>> candles;

  @override
  void paint(Canvas canvas, Size size) {
    if (candles.isEmpty || size.width <= 0 || size.height <= 0) return;
    const left = 4.0;
    const right = 62.0;
    const top = 8.0;
    const bottom = 22.0;
    final plot = Rect.fromLTRB(
      left,
      top,
      math.max(left + 1, size.width - right),
      math.max(top + 1, size.height - bottom),
    );
    var minimum = double.infinity;
    var maximum = double.negativeInfinity;
    for (final candle in candles) {
      minimum = math.min(minimum, candle[3]);
      maximum = math.max(maximum, candle[2]);
    }
    final padding = (maximum - minimum) * 0.08;
    final low = minimum - (padding == 0 ? minimum * 0.001 : padding);
    final high = maximum + (padding == 0 ? maximum * 0.001 : padding);
    final range = high - low;
    double yFor(double value) =>
        plot.bottom - (value - low) / range * plot.height;

    final gridPaint =
        Paint()
          ..color = const Color(0xFF29343D)
          ..strokeWidth = 1;
    final axisStyle = const TextStyle(color: Color(0xFF82909B), fontSize: 9);
    for (var index = 0; index <= 4; index++) {
      final y = plot.top + plot.height * index / 4;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), gridPaint);
      final value = high - range * index / 4;
      _drawText(
        canvas,
        value >= 100 ? value.toStringAsFixed(1) : value.toStringAsPrecision(4),
        Offset(plot.right + 5, y - 6),
        axisStyle,
      );
    }

    final step = plot.width / candles.length;
    final bodyWidth = math.max(1.0, math.min(9.0, step * 0.66)).toDouble();
    final upPaint =
        Paint()
          ..color = const Color(0xFF66E3C4)
          ..strokeWidth = 1;
    final downPaint =
        Paint()
          ..color = const Color(0xFFFF7B78)
          ..strokeWidth = 1;
    for (var index = 0; index < candles.length; index++) {
      final candle = candles[index];
      final x = plot.left + step * (index + 0.5);
      final color =
          candle[4] >= candle[1]
              ? const Color(0xFF66E3C4)
              : const Color(0xFFFF7B78);
      final paint = color == const Color(0xFF66E3C4) ? upPaint : downPaint;
      canvas.drawLine(
        Offset(x, yFor(candle[2])),
        Offset(x, yFor(candle[3])),
        paint,
      );
      final bodyTop = yFor(math.max(candle[1], candle[4]));
      final bodyBottom = yFor(math.min(candle[1], candle[4]));
      canvas.drawRect(
        Rect.fromLTRB(
          x - bodyWidth / 2,
          bodyTop,
          x + bodyWidth / 2,
          math.max(bodyTop + 1.2, bodyBottom),
        ),
        paint,
      );
    }

    _drawText(
      canvas,
      _timeLabel(candles.first[0]),
      Offset(plot.left, plot.bottom + 5),
      axisStyle,
    );
    final lastLabel = _timeLabel(candles.last[0]);
    _drawText(
      canvas,
      lastLabel,
      Offset(plot.right - 36, plot.bottom + 5),
      axisStyle,
    );

    final latestY = yFor(candles.last[4]);
    final livePaint =
        Paint()
          ..color = const Color(0xFF66E3C4).withValues(alpha: 0.5)
          ..strokeWidth = 1;
    for (var x = plot.left; x < plot.right; x += 7) {
      canvas.drawLine(
        Offset(x, latestY),
        Offset(math.min(x + 3, plot.right), latestY),
        livePaint,
      );
    }
  }

  void _drawText(Canvas canvas, String text, Offset offset, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    painter.paint(canvas, offset);
  }

  String _timeLabel(double timestamp) {
    final date =
        DateTime.fromMillisecondsSinceEpoch(timestamp.toInt()).toLocal();
    return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  @override
  bool shouldRepaint(covariant _CandlestickPainter oldDelegate) =>
      !identical(candles, oldDelegate.candles);
}

class _LivePriceTracePainter extends CustomPainter {
  _LivePriceTracePainter(this.prices, {required Listenable repaint})
    : super(repaint: repaint);

  final List<double> prices;

  @override
  void paint(Canvas canvas, Size size) {
    if (prices.length < 2 || size.width <= 0 || size.height <= 0) return;
    var minimum = double.infinity;
    var maximum = double.negativeInfinity;
    for (final price in prices) {
      minimum = math.min(minimum, price);
      maximum = math.max(maximum, price);
    }
    final rawRange = maximum - minimum;
    final padding = rawRange == 0 ? minimum.abs() * 0.001 : rawRange * 0.12;
    final low = minimum - padding;
    final range = rawRange + padding * 2;
    final middle = size.height / 2;
    final grid =
        Paint()
          ..color = const Color(0xFF29343D)
          ..strokeWidth = 1;
    canvas.drawLine(Offset(0, middle), Offset(size.width, middle), grid);

    final path = Path();
    for (var index = 0; index < prices.length; index++) {
      final x = size.width * index / (prices.length - 1);
      final y = size.height - (prices[index] - low) / range * size.height;
      if (index == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    final trace =
        Paint()
          ..color = const Color(0xFF66E3C4)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.7
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, trace);

    final lastY = size.height - (prices.last - low) / range * size.height;
    canvas.drawCircle(
      Offset(size.width - 2, lastY),
      2.2,
      Paint()..color = const Color(0xFF66E3C4),
    );
  }

  @override
  bool shouldRepaint(covariant _LivePriceTracePainter oldDelegate) =>
      !identical(prices, oldDelegate.prices);
}
