import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class BybitLivePriceStream extends StatefulWidget {
  const BybitLivePriceStream({
    required this.category,
    required this.symbol,
    required this.onPrice,
    required this.onConnectionChanged,
    super.key,
  });

  final String category;
  final String symbol;
  final ValueChanged<double> onPrice;
  final ValueChanged<bool> onConnectionChanged;

  @override
  State<BybitLivePriceStream> createState() => _BybitLivePriceStreamState();
}

class _BybitLivePriceStreamState extends State<BybitLivePriceStream>
    with WidgetsBindingObserver {
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  Timer? _priceTimer;
  double? _pendingPrice;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      _connect();
    }
  }

  @override
  void didUpdateWidget(covariant BybitLivePriceStream oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.category != widget.category ||
        oldWidget.symbol != widget.symbol) {
      _disconnect();
      _connect();
    }
  }

  void _connect() {
    if (!mounted || _channel != null) return;
    final channel = WebSocketChannel.connect(
      Uri.parse('wss://stream.bybit.com/v5/public/${widget.category}'),
    );
    _channel = channel;
    _subscription = channel.stream.listen(
      _handleMessage,
      onError: (Object error) => _handleDisconnect(channel),
      onDone: () => _handleDisconnect(channel),
      cancelOnError: true,
    );
    unawaited(_activate(channel));
  }

  Future<void> _activate(WebSocketChannel channel) async {
    try {
      await channel.ready;
      if (!mounted || !identical(channel, _channel)) return;
      channel.sink.add(
        jsonEncode({
          'op': 'subscribe',
          'args': ['tickers.${widget.symbol}'],
        }),
      );
      _pingTimer = Timer.periodic(const Duration(seconds: 20), (_) {
        if (!identical(channel, _channel)) return;
        try {
          channel.sink.add(jsonEncode({'op': 'ping'}));
        } catch (_) {
          _handleDisconnect(channel);
        }
      });
    } catch (_) {
      _handleDisconnect(channel);
    }
  }

  void _handleMessage(dynamic message) {
    Map<String, dynamic> decoded;
    try {
      final value = jsonDecode('$message');
      if (value is! Map<String, dynamic>) return;
      decoded = value;
    } on FormatException {
      return;
    }
    if (decoded['op'] == 'subscribe') {
      if (decoded['success'] == true) {
        widget.onConnectionChanged(true);
      } else if (decoded['success'] == false) {
        final channel = _channel;
        if (channel != null) _handleDisconnect(channel);
      }
      return;
    }
    if (decoded['topic'] != 'tickers.${widget.symbol}') return;
    final data = decoded['data'];
    final tickers =
        data is Map<String, dynamic>
            ? [data]
            : data is List
            ? data.whereType<Map<String, dynamic>>()
            : const <Map<String, dynamic>>[];
    for (final ticker in tickers) {
      final rawPrice = ticker['lastPrice'];
      final price =
          rawPrice is num ? rawPrice.toDouble() : double.tryParse('$rawPrice');
      if (price == null || !price.isFinite || price <= 0) continue;
      widget.onConnectionChanged(true);
      _pendingPrice = price;
      _priceTimer ??= Timer(const Duration(milliseconds: 50), () {
        _priceTimer = null;
        final latestPrice = _pendingPrice;
        _pendingPrice = null;
        if (mounted && latestPrice != null) widget.onPrice(latestPrice);
      });
    }
  }

  void _handleDisconnect(WebSocketChannel channel) {
    if (!mounted || !identical(channel, _channel)) return;
    _pingTimer?.cancel();
    _pingTimer = null;
    _priceTimer?.cancel();
    _priceTimer = null;
    _pendingPrice = null;
    _channel = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
    unawaited(channel.sink.close());
    widget.onConnectionChanged(false);
    _reconnectTimer ??= Timer(const Duration(seconds: 3), () {
      _reconnectTimer = null;
      _connect();
    });
  }

  void _disconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _pingTimer?.cancel();
    _pingTimer = null;
    _priceTimer?.cancel();
    _priceTimer = null;
    _pendingPrice = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
    final channel = _channel;
    _channel = null;
    unawaited(channel?.sink.close());
    widget.onConnectionChanged(false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _connect();
    } else {
      _disconnect();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
