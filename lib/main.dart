import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'bybit_candlestick_chart.dart';
import 'bybit_ccxt_adapter.dart';
import 'bybit_live_price_stream.dart';
import 'market_selector_sheet.dart';
import 'mobile_trading_service.dart';
import 'trading_strategy.dart';

void main() {
  FlutterForegroundTask.initCommunicationPort();
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'bybit_trading',
      channelName: 'Bybit trading',
      channelDescription: 'Thông báo bot Bybit đang chạy nền.',
      onlyAlertOnce: true,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: false,
      playSound: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.repeat(60000),
      allowWakeLock: true,
      allowWifiLock: true,
      allowAutoRestart: false,
      stopWithTask: false,
    ),
  );
  runApp(const BybitTraderApp());
}

class BybitTraderApp extends StatelessWidget {
  const BybitTraderApp({super.key});

  @override
  Widget build(BuildContext context) {
    const colorScheme = ColorScheme(
      brightness: Brightness.dark,
      primary: Color(0xFF71E6C2),
      onPrimary: Color(0xFF06251D),
      secondary: Color(0xFFFFC66D),
      onSecondary: Color(0xFF30210A),
      error: Color(0xFFFF7B78),
      onError: Color(0xFF3A0808),
      surface: Color(0xFF111820),
      onSurface: Color(0xFFE8F0F4),
    );
    return MaterialApp(
      title: 'Bybit Auto Trader',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: colorScheme,
        scaffoldBackgroundColor: const Color(0xFF090E13),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF090E13),
          foregroundColor: Color(0xFFE8F0F4),
          surfaceTintColor: Colors.transparent,
          elevation: 0,
        ),
        cardTheme: CardThemeData(
          color: Color(0xFF111820),
          margin: EdgeInsets.zero,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: Color(0xFF202C35)),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF0B1218),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 15,
          ),
          labelStyle: const TextStyle(color: Color(0xFF91A2AE)),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFF26343E)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFF26343E)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: colorScheme.primary, width: 1.3),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(50),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(15),
            ),
            textStyle: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(50),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(15),
            ),
            side: const BorderSide(color: Color(0xFF35434C)),
          ),
        ),
      ),
      home: const DashboardPage(),
    );
  }
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  static const _storage = FlutterSecureStorage();
  static const _categories = ['spot', 'linear', 'inverse', 'option'];
  final _apiKeyController = TextEditingController();
  final _apiSecretController = TextEditingController();
  final _demoApiKeyController = TextEditingController();
  final _demoApiSecretController = TextEditingController();
  final _symbolController = TextEditingController(text: 'BTCUSDT');
  final _sizeController = TextEditingController(text: '25');
  Timer? _refreshTimer;
  Map<String, dynamic>? _status;
  Map<String, dynamic>? _accountBalance;
  String? _accountBalanceError;
  Map<String, dynamic>? _liquidationReport;
  String _category = 'spot';
  String _strategy = 'short_wave';
  String _direction = 'long';
  String _balanceEnvironment = 'demo';
  String? _error;
  bool _busy = false;
  bool _accountLoading = false;
  bool _showDemoApiSecret = false;
  bool _showLiveApiSecret = false;
  bool _chartLoading = false;
  int _chartRequestId = 0;
  Map<String, dynamic>? _chartSnapshot;
  List<List<double>> _chartCandles = const [];
  final ValueNotifier<double?> _livePrice = ValueNotifier(null);
  final ValueNotifier<bool> _marketStreamConnected = ValueNotifier(false);

  @override
  void initState() {
    super.initState();
    FlutterForegroundTask.addTaskDataCallback(_onTaskData);
    _loadSettings();
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _refresh(),
    );
  }

  void _onTaskData(Object data) {
    if (!mounted) return;
    if (data is String) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map<String, dynamic>) {
          _acceptStatus(decoded);
        }
      } on FormatException catch (error) {
        final message = 'Trạng thái bot sai định dạng: $error';
        if (_error != message) setState(() => _error = message);
      }
      return;
    }
    if (data is Map<String, dynamic>) {
      _acceptStatus(data);
    }
  }

  void _acceptStatus(Map<String, dynamic> status) {
    final changed =
        _status == null ||
        _statusFingerprint(_status!) != _statusFingerprint(status);
    final balance = status['exchangeBalance'];
    final balanceChanged =
        balance is Map<String, dynamic> &&
        jsonEncode(balance) != jsonEncode(_accountBalance);
    _status = status;
    if (!changed && !balanceChanged) return;
    setState(() {
      if (balance is Map<String, dynamic>) _accountBalance = balance;
      _error = status['lastError'] as String?;
    });
  }

  String _statusFingerprint(Map<String, dynamic> status) {
    final stableStatus = Map<String, dynamic>.from(status)..remove('updatedAt');
    return jsonEncode(stableStatus);
  }

  Future<void> _loadSettings() async {
    try {
      _apiKeyController.text = await _storage.read(key: 'bybit_api_key') ?? '';
      _apiSecretController.text =
          await _storage.read(key: 'bybit_api_secret') ?? '';
      _demoApiKeyController.text =
          await _storage.read(key: 'bybit_demo_api_key') ?? '';
      _demoApiSecretController.text =
          await _storage.read(key: 'bybit_demo_api_secret') ?? '';
      final configJson = await FlutterForegroundTask.getData<String>(
        key: 'mobile_bot_config',
      );
      if (configJson != null) {
        final config = Map<String, dynamic>.from(jsonDecode(configJson) as Map);
        _category = config['category'] as String? ?? _category;
        _strategy = config['strategy'] as String? ?? _strategy;
        _direction = config['direction'] as String? ?? _direction;
        _symbolController.text =
            config['symbol'] as String? ?? _symbolController.text;
        _sizeController.text =
            (config['maxOrderUsdt'] ?? _sizeController.text).toString();
      }
      if (!mounted) return;
      await _refresh();
      await _loadChart();
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Không đọc được thông tin bảo mật: $error');
      }
    }
  }

  Future<void> _refresh() async {
    if (_busy) return;
    try {
      final running = await FlutterForegroundTask.isRunningService;
      final statusJson = await FlutterForegroundTask.getData<String>(
        key: 'mobile_bot_status',
      );
      final status =
          statusJson == null
              ? <String, dynamic>{'running': running}
              : Map<String, dynamic>.from(jsonDecode(statusJson) as Map);
      status['running'] = running;
      if (!mounted) return;
      _acceptStatus(status);
    } catch (error) {
      if (mounted && _error != error.toString()) {
        setState(() => _error = error.toString());
      }
    }
  }

  Future<void> _loadChart() async {
    if (_symbolController.text.trim().length < 3) return;
    final requestId = ++_chartRequestId;
    if (mounted) {
      setState(() {
        _chartLoading = true;
        _chartSnapshot = null;
        _chartCandles = const [];
      });
    }
    _livePrice.value = null;
    _marketStreamConnected.value = false;
    final client = BybitCcxtAdapter(
      apiKey: _apiKeyController.text.trim(),
      apiSecret: _apiSecretController.text.trim(),
    );
    try {
      final sourceCategory = _category == 'option' ? 'spot' : _category;
      final sourceSymbol =
          _category == 'option'
              ? '${_symbolController.text.trim().split('-').first}USDT'
              : _symbolController.text.trim();
      final timeframe = _strategy == 'short_wave' ? '5m' : '4h';
      final results = await Future.wait([
        client.fetchMarket(category: sourceCategory, symbol: sourceSymbol),
        client.fetchOHLCV(
          category: sourceCategory,
          symbol: sourceSymbol,
          timeframe: timeframe,
          limit: 200,
        ),
        client.fetchTicker(
          category: _category,
          symbol: _symbolController.text.trim(),
        ),
      ]);
      final candles = results[1] as List<List<double>>;
      final analysisCandles =
          candles.length > 1 ? candles.sublist(0, candles.length - 1) : candles;
      final market = results[0] as Map<String, dynamic>;
      final ticker = results[2] as Map<String, dynamic>;
      final lastPrice = ticker['last'] as double?;
      final price =
          _category == 'option' ? ticker['ask'] as double? : lastPrice;
      final snapshot = <String, Object?>{
        'category': _category,
        'symbol': _symbolController.text.trim(),
        'strategy': _strategy,
        'direction': _direction,
        'timeframe': _strategy == 'short_wave' ? '5m' : '4h',
        'streamCategory': sourceCategory,
        'streamSymbol': sourceSymbol,
        'analysisSourceSymbol': sourceSymbol,
        'candles': candles,
        'price': price,
        'analysis': analyzeCandles(analysisCandles, _strategy),
        'market': market,
        'updatedAt': DateTime.now().toIso8601String(),
      };
      if (!mounted || requestId != _chartRequestId) return;
      setState(() {
        _chartSnapshot = snapshot;
        _chartCandles = candles;
        _chartLoading = false;
      });
      if (_category != 'option') _livePrice.value = lastPrice;
    } catch (error) {
      if (mounted && requestId == _chartRequestId) {
        setState(() {
          _chartLoading = false;
          _error = error.toString();
        });
      }
    } finally {
      client.close();
    }
  }

  Future<void> _saveCredentials() async {
    await _storage.write(
      key: 'bybit_api_key',
      value: _apiKeyController.text.trim(),
    );
    await _storage.write(
      key: 'bybit_api_secret',
      value: _apiSecretController.text.trim(),
    );
    await _storage.write(
      key: 'bybit_demo_api_key',
      value: _demoApiKeyController.text.trim(),
    );
    await _storage.write(
      key: 'bybit_demo_api_secret',
      value: _demoApiSecretController.text.trim(),
    );
    await _loadChart();
  }

  Future<void> _pasteApiCredential(TextEditingController controller) async {
    String? value;
    try {
      value = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Không đọc được clipboard: $error')),
        );
      }
      return;
    }
    if (value == null || value.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Clipboard không có nội dung để dán.')),
        );
      }
      return;
    }
    if (!mounted) return;
    controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  Widget _pasteCredentialButton(TextEditingController controller) => IconButton(
    tooltip: 'Dán từ clipboard',
    onPressed: () => _pasteApiCredential(controller),
    icon: const Icon(Icons.content_paste_rounded),
  );

  Future<void> _start(String mode) async {
    final isDemo = mode == 'paper';
    final apiKey =
        isDemo
            ? _demoApiKeyController.text.trim()
            : _apiKeyController.text.trim();
    final apiSecret =
        isDemo
            ? _demoApiSecretController.text.trim()
            : _apiSecretController.text.trim();
    var confirmed = false;
    if (apiKey.isEmpty || apiSecret.isEmpty) {
      setState(
        () =>
            _error =
                isDemo
                    ? 'Hãy nhập API Key và Secret riêng của Bybit Demo trong Cài đặt.'
                    : 'Hãy nhập API Key và API Secret của Bybit.',
      );
      return;
    }
    if (mode == 'live') {
      confirmed =
          await showDialog<bool>(
            context: context,
            builder:
                (context) => AlertDialog(
                  title: const Text('Xác nhận giao dịch thật'),
                  content: Text(
                    'Bot sẽ gửi lệnh thật cho ${_category.toUpperCase()}: '
                    '${_direction == 'both' ? 'tự động Long + Short' : 'chỉ ${_direction.toUpperCase()}'}, '
                    '${_strategy == 'short_wave' ? 'sóng ngắn · nến 5 phút' : 'sóng dài · nến 4 giờ'}. '
                    'Bot chạy trên điện thoại; giữ dịch vụ nền và thông báo hoạt động. '
                    'Options không có stop-loss đặt sẵn trên sàn. '
                    'Chỉ tiếp tục nếu bạn hiểu rủi ro mất vốn.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Hủy'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Tôi xác nhận'),
                    ),
                  ],
                ),
          ) ??
          false;
      if (!confirmed) return;
    }
    await _perform(() async {
      setState(() => _balanceEnvironment = isDemo ? 'demo' : 'live');
      final config = <String, Object?>{
        'category': _category,
        'symbol': _symbolController.text.trim(),
        'maxOrderUsdt': double.tryParse(_sizeController.text) ?? 0,
        'strategy': _strategy,
        'direction': _direction,
        'mode': mode,
      };
      await FlutterForegroundTask.saveData(
        key: 'mobile_bot_config',
        value: jsonEncode(config),
      );
      await _loadChart();
      if (isDemo) {
        await _storage.write(key: 'bybit_demo_api_key', value: apiKey);
        await _storage.write(key: 'bybit_demo_api_secret', value: apiSecret);
      } else {
        await _storage.write(key: 'bybit_api_key', value: apiKey);
        await _storage.write(key: 'bybit_api_secret', value: apiSecret);
      }
      final client = BybitCcxtAdapter(
        apiKey: apiKey,
        apiSecret: apiSecret,
        isDemo: isDemo,
      );
      try {
        final balance = await client.fetchBalance();
        if (mounted) setState(() => _accountBalance = balance);
      } finally {
        client.close();
      }
      final permission =
          await FlutterForegroundTask.checkNotificationPermission();
      if (permission != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
      final granted = await FlutterForegroundTask.checkNotificationPermission();
      if (granted != NotificationPermission.granted) {
        throw StateError(
          'Cần cho phép thông báo để Android duy trì bot chạy nền.',
        );
      }
      final result = await FlutterForegroundTask.startService(
        serviceId: 1642,
        serviceTypes: const [ForegroundServiceTypes.specialUse],
        notificationTitle: 'Bybit Auto Trader · ${isDemo ? 'DEMO' : 'LIVE'}',
        notificationText: '${_symbolController.text.trim()} · bot đang chạy',
        notificationIcon: const NotificationIcon(
          metaDataName: 'com.example.bybitautotrader.service.BOT_ICON',
          backgroundColor: Color(0xFF66E3C4),
        ),
        callback: startMobileTradingService,
      );
      if (result is ServiceRequestFailure) {
        throw Exception('Không khởi động được dịch vụ nền: ${result.error}');
      }
      if (mounted) {
        setState(() {
          _status = {
            ...?_status,
            ...config,
            'running': true,
            'lastError': null,
          };
        });
      }
    });
  }

  Future<void> _loadAccountBalance() async {
    if (_accountLoading) return;
    setState(() {
      _accountLoading = true;
      _accountBalance = null;
      _accountBalanceError = null;
      _error = null;
    });
    BybitCcxtAdapter? client;
    try {
      final running = _status?['running'] == true;
      var mode = running ? (_status?['mode'] as String?) : _balanceEnvironment;
      if (running && mode == null) {
        final configJson = await FlutterForegroundTask.getData<String>(
          key: 'mobile_bot_config',
        );
        if (configJson != null) {
          mode =
              (jsonDecode(configJson) as Map<String, dynamic>)['mode']
                  as String?;
        }
      }
      final isDemo = mode == 'paper' || mode == 'demo';
      client = BybitCcxtAdapter(
        apiKey:
            await _storage.read(
              key: isDemo ? 'bybit_demo_api_key' : 'bybit_api_key',
            ) ??
            '',
        apiSecret:
            await _storage.read(
              key: isDemo ? 'bybit_demo_api_secret' : 'bybit_api_secret',
            ) ??
            '',
        isDemo: isDemo,
      );
      final balance = await client.fetchBalance();
      if (mounted) {
        setState(() {
          _accountBalance = balance;
          _accountBalanceError = null;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _accountBalanceError = error.toString();
          _error = 'Không tải được tài sản Bybit: $error';
        });
      }
    } finally {
      client?.close();
      if (mounted) setState(() => _accountLoading = false);
    }
  }

  Future<void> _stop() async {
    var mode = _status?['mode'] as String?;
    if (mode == null) {
      final configJson = await FlutterForegroundTask.getData<String>(
        key: 'mobile_bot_config',
      );
      if (configJson != null) {
        mode =
            (jsonDecode(configJson) as Map<String, dynamic>)['mode'] as String?;
      }
    }
    if (mode != 'paper' && mode != 'live') {
      if (mounted) {
        setState(
          () =>
              _error =
                  'Không xác định được chế độ bot; không thể dừng an toàn.',
        );
      }
      return;
    }
    if (!mounted) return;
    var confirmationText = '';
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder:
              (context) => AlertDialog(
                scrollable: true,
                title: Text(
                  mode == 'paper'
                      ? 'Dừng Demo và thanh lý tài khoản Demo?'
                      : 'Dừng Live và thanh lý toàn tài khoản?',
                ),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Sẽ dừng bot trên ${mode == 'paper' ? 'Bybit Demo' : 'Bybit Live'}, '
                      'hủy toàn bộ lệnh chờ, đóng mọi vị thế (Linear/Inverse/Options) '
                      'và bán số dư Spot khả dụng có cặp USDT/USDC. USDT được giữ lại. '
                      'Tài sản không có cặp phù hợp hoặc dưới mức tối thiểu sẽ được báo. '
                      'Thao tác ảnh hưởng cả lệnh/vị thế không do bot tạo trong môi trường này.',
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      onChanged: (value) => confirmationText = value,
                      decoration: const InputDecoration(
                        labelText: 'Nhập THANH LY để xác nhận',
                      ),
                    ),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () {
                      FocusScope.of(context).unfocus();
                      Navigator.pop(context, false);
                    },
                    child: const Text('Hủy'),
                  ),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF8A3434),
                    ),
                    onPressed: () {
                      FocusScope.of(context).unfocus();
                      Navigator.pop(
                        context,
                        confirmationText.trim() == 'THANH LY',
                      );
                    },
                    child: const Text('Dừng & thanh lý'),
                  ),
                ],
              ),
        ) ??
        false;
    if (!confirmed) return;

    await _perform(() async {
      await FlutterForegroundTask.stopService();
      if (mounted) {
        setState(() {
          _status = {...?_status, 'running': false};
          _liquidationReport = null;
        });
      }
      final isDemo = mode == 'paper';
      final client = BybitCcxtAdapter(
        apiKey:
            await _storage.read(
              key: isDemo ? 'bybit_demo_api_key' : 'bybit_api_key',
            ) ??
            '',
        apiSecret:
            await _storage.read(
              key: isDemo ? 'bybit_demo_api_secret' : 'bybit_api_secret',
            ) ??
            '',
        isDemo: isDemo,
      );
      try {
        final report = await client.liquidateAccount();
        if (mounted) setState(() => _liquidationReport = report);
        final stateKey = isDemo ? 'mobile_bot_demo_state' : 'mobile_bot_state';
        final stateJson = await FlutterForegroundTask.getData<String>(
          key: stateKey,
        );
        var botPositionClosed = report['complete'] == true;
        if (stateJson != null) {
          final state = Map<String, dynamic>.from(jsonDecode(stateJson) as Map);
          final botPosition = state['position'] as Map<String, dynamic>?;
          final closedPositions =
              report['closedPositions'] as List<dynamic>? ?? const [];
          if (botPosition != null && !botPositionClosed) {
            final botSide = botPosition['side'] == 'long' ? 'buy' : 'sell';
            botPositionClosed = closedPositions.any(
              (closed) =>
                  closed is Map &&
                  closed['category'] == botPosition['category'] &&
                  closed['symbol'] == botPosition['symbol'] &&
                  closed['side'] == botSide,
            );
          }
          if (botPositionClosed) {
            state['position'] = null;
            await FlutterForegroundTask.saveData(
              key: stateKey,
              value: jsonEncode(state),
            );
          }
        }
        if (mounted && botPositionClosed) {
          setState(() {
            _status = {...?_status, 'running': false, 'position': null};
          });
        }
        await _loadAccountBalance();
      } finally {
        client.close();
      }
    });
  }

  Future<void> _chooseMarket() async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF111820),
      builder:
          (context) => MarketSelectorSheet(
            category: _category,
            direction: _direction,
            strategy: _strategy,
          ),
    );
    if (selected == null || !mounted) return;
    setState(() {
      _symbolController.text = selected;
      _error = null;
    });
    await _loadChart();
  }

  Future<void> _perform(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showSettings() async {
    await showDialog<void>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('API Bybit Demo và Live'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Demo gửi lệnh vào Bybit Demo bằng khóa Demo riêng; Live mới dùng khóa tiền thật. '
                    'Tạo khóa trong đúng môi trường, lưu an toàn trên điện thoại và không bật quyền rút tiền.',
                    style: TextStyle(color: Colors.white60),
                  ),
                  const SizedBox(height: 14),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'BYBIT DEMO · dùng cho nút Chạy Demo',
                      style: TextStyle(
                        color: Color(0xFF71E6C2),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  TextField(
                    controller: _demoApiKeyController,
                    autocorrect: false,
                    enableSuggestions: false,
                    enableInteractiveSelection: true,
                    decoration: InputDecoration(
                      labelText: 'Demo API Key',
                      suffixIcon: _pasteCredentialButton(_demoApiKeyController),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _demoApiSecretController,
                    autocorrect: false,
                    enableSuggestions: false,
                    enableInteractiveSelection: true,
                    keyboardType: TextInputType.visiblePassword,
                    obscureText: !_showDemoApiSecret,
                    decoration: InputDecoration(
                      labelText: 'Demo API Secret',
                      suffixIcon: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _pasteCredentialButton(_demoApiSecretController),
                          IconButton(
                            tooltip:
                                _showDemoApiSecret
                                    ? 'Ẩn Demo API Secret'
                                    : 'Hiện Demo API Secret',
                            onPressed:
                                () => setState(
                                  () =>
                                      _showDemoApiSecret = !_showDemoApiSecret,
                                ),
                            icon: Icon(
                              _showDemoApiSecret
                                  ? Icons.visibility_off
                                  : Icons.visibility,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  const Divider(),
                  const SizedBox(height: 12),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'BYBIT LIVE · dùng cho nút Chạy Live',
                      style: TextStyle(
                        color: Color(0xFFFFC66D),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  TextField(
                    controller: _apiKeyController,
                    autocorrect: false,
                    enableSuggestions: false,
                    enableInteractiveSelection: true,
                    decoration: InputDecoration(
                      labelText: 'Live API Key',
                      suffixIcon: _pasteCredentialButton(_apiKeyController),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _apiSecretController,
                    autocorrect: false,
                    enableSuggestions: false,
                    enableInteractiveSelection: true,
                    keyboardType: TextInputType.visiblePassword,
                    obscureText: !_showLiveApiSecret,
                    decoration: InputDecoration(
                      labelText: 'Live API Secret',
                      suffixIcon: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _pasteCredentialButton(_apiSecretController),
                          IconButton(
                            tooltip:
                                _showLiveApiSecret
                                    ? 'Ẩn Live API Secret'
                                    : 'Hiện Live API Secret',
                            onPressed:
                                () => setState(
                                  () =>
                                      _showLiveApiSecret = !_showLiveApiSecret,
                                ),
                            icon: Icon(
                              _showLiveApiSecret
                                  ? Icons.visibility_off
                                  : Icons.visibility,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Đóng'),
              ),
              FilledButton(
                onPressed: () async {
                  try {
                    await _saveCredentials();
                    if (context.mounted) Navigator.pop(context);
                  } catch (error) {
                    if (mounted) {
                      setState(() => _error = 'Không lưu được API key: $error');
                    }
                  }
                },
                child: const Text('Lưu trên điện thoại'),
              ),
            ],
          ),
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _livePrice.dispose();
    _marketStreamConnected.dispose();
    FlutterForegroundTask.removeTaskDataCallback(_onTaskData);
    _apiKeyController.dispose();
    _apiSecretController.dispose();
    _demoApiKeyController.dispose();
    _demoApiSecretController.dispose();
    _symbolController.dispose();
    _sizeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final running = _status?['running'] == true;
    final mode = _status?['mode'] as String? ?? 'paper';
    final analysisSnapshot = running ? _status : _chartSnapshot;
    final analysis =
        analysisSnapshot?['analysis'] as Map<String, dynamic>? ??
        _status?['analysis'] as Map<String, dynamic>?;
    final position = _status?['position'] as Map<String, dynamic>?;
    final trades = _status?['trades'] as List<dynamic>? ?? const [];
    final snapshot = _chartSnapshot ?? _status;
    final dashboardSnapshot = running ? _status : snapshot;
    final streamCategory = snapshot?['streamCategory'] as String?;
    final streamSymbol = snapshot?['streamSymbol'] as String?;
    final timeframe = snapshot?['timeframe'] as String? ?? '5m';

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: const Color(0xFF71E6C2).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(13),
              ),
              child: const Icon(
                Icons.candlestick_chart_rounded,
                color: Color(0xFF71E6C2),
                size: 22,
              ),
            ),
            const SizedBox(width: 11),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Bybit Trader',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                ),
                Text(
                  'GIAO DỊCH TỰ ĐỘNG · V5',
                  style: TextStyle(
                    fontSize: 9,
                    letterSpacing: 0.9,
                    color: Color(0xFF81919C),
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton.filledTonal(
            onPressed: _showSettings,
            icon: const Icon(Icons.key_rounded, size: 19),
            tooltip: 'Cài đặt API Bybit',
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            _heroCard(running, mode),
            if (_error != null) ...[
              const SizedBox(height: 12),
              _message(_error!, isError: true),
            ],
            const SizedBox(height: 16),
            _executionDashboard(
              analysis: analysis,
              position: position,
              latestTrade: trades.isEmpty ? null : trades.last,
              snapshot: dashboardSnapshot,
              running: running,
              mode: mode,
            ),
            const SizedBox(height: 20),
            _sectionTitle(
              'Tổng quan tài khoản',
              subtitle:
                  'Tài sản và số dư Unified Account · ${(_status?['running'] == true ? mode : _balanceEnvironment) == 'live' ? 'Bybit Live' : 'Bybit Demo'}',
            ),
            const SizedBox(height: 10),
            _accountAssetsCard(),
            if (_liquidationReport != null) ...[
              const SizedBox(height: 12),
              _liquidationReportCard(_liquidationReport!),
            ],
            if (position != null) ...[
              const SizedBox(height: 18),
              _sectionTitle(
                'Vị thế đang mở',
                subtitle: 'Giá vào, mức bảo vệ và các mốc quản lý lệnh.',
              ),
              const SizedBox(height: 10),
              _positionCard(position),
            ],
            Card(
              child: ExpansionTile(
                title: const Text(
                  'Thiết lập giao dịch',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                ),
                subtitle: const Text(
                  'Sản phẩm · chiến lược · cặp · quy mô lệnh',
                  style: TextStyle(color: Color(0xFF91A2AE), fontSize: 11),
                ),
                leading: const Icon(Icons.tune_rounded),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(17, 0, 17, 17),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'SẢN PHẨM BYBIT',
                          style: TextStyle(
                            color: Color(0xFF91A2AE),
                            fontSize: 10,
                            letterSpacing: 1.1,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children:
                              _categories
                                  .map(
                                    (category) => ChoiceChip(
                                      avatar: Icon(
                                        _categoryIcon(category),
                                        size: 17,
                                      ),
                                      label: Text(_categoryLabel(category)),
                                      selected: _category == category,
                                      onSelected:
                                          running || _busy
                                              ? null
                                              : (selected) {
                                                if (!selected) return;
                                                setState(() {
                                                  _category = category;
                                                  _direction =
                                                      category == 'linear' ||
                                                              category ==
                                                                  'inverse'
                                                          ? 'both'
                                                          : 'long';
                                                });
                                                unawaited(_loadChart());
                                              },
                                    ),
                                  )
                                  .toList(),
                        ),
                        const SizedBox(height: 18),
                        const Text(
                          'CHIẾN LƯỢC',
                          style: TextStyle(
                            color: Color(0xFF91A2AE),
                            fontSize: 10,
                            letterSpacing: 1.1,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 9),
                        SizedBox(
                          width: double.infinity,
                          child: SegmentedButton<String>(
                            showSelectedIcon: false,
                            segments: const [
                              ButtonSegment(
                                value: 'short_wave',
                                icon: Icon(Icons.bolt_rounded, size: 17),
                                label: Text('Sóng ngắn · 5m'),
                              ),
                              ButtonSegment(
                                value: 'long_wave',
                                icon: Icon(Icons.waves_rounded, size: 17),
                                label: Text('Sóng dài · 4h'),
                              ),
                            ],
                            selected: {_strategy},
                            onSelectionChanged:
                                running || _busy
                                    ? null
                                    : (selection) {
                                      setState(
                                        () => _strategy = selection.first,
                                      );
                                      unawaited(_loadChart());
                                    },
                          ),
                        ),
                        if (_category == 'linear' ||
                            _category == 'inverse') ...[
                          const SizedBox(height: 18),
                          const Text(
                            'HƯỚNG VỊ THẾ',
                            style: TextStyle(
                              color: Color(0xFF91A2AE),
                              fontSize: 10,
                              letterSpacing: 1.1,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 9),
                          SizedBox(
                            width: double.infinity,
                            child: SegmentedButton<String>(
                              showSelectedIcon: false,
                              segments: const [
                                ButtonSegment(
                                  value: 'both',
                                  icon: Icon(Icons.swap_vert_rounded, size: 17),
                                  label: Text('Tự động'),
                                ),
                                ButtonSegment(
                                  value: 'long',
                                  icon: Icon(
                                    Icons.trending_up_rounded,
                                    size: 17,
                                  ),
                                  label: Text('Chỉ Long'),
                                ),
                                ButtonSegment(
                                  value: 'short',
                                  icon: Icon(
                                    Icons.trending_down_rounded,
                                    size: 17,
                                  ),
                                  label: Text('Chỉ Short'),
                                ),
                              ],
                              selected: {_direction},
                              onSelectionChanged:
                                  running || _busy
                                      ? null
                                      : (selection) {
                                        setState(
                                          () => _direction = selection.first,
                                        );
                                      },
                            ),
                          ),
                        ] else ...[
                          const SizedBox(height: 9),
                          _helperText(
                            'Spot và Options chỉ hỗ trợ mở vị thế Long.',
                            icon: Icons.info_outline_rounded,
                          ),
                        ],
                        const SizedBox(height: 18),
                        const Text(
                          'CẶP GIAO DỊCH',
                          style: TextStyle(
                            color: Color(0xFF91A2AE),
                            fontSize: 10,
                            letterSpacing: 1.1,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 9),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _symbolController,
                                autocorrect: false,
                                enabled: !running && !_busy,
                                onEditingComplete: () => _loadChart(),
                                decoration: const InputDecoration(
                                  prefixIcon: Icon(
                                    Icons.currency_bitcoin_rounded,
                                  ),
                                  hintText: 'BTCUSDT',
                                  suffixText: 'BYBIT',
                                ),
                              ),
                            ),
                            const SizedBox(width: 9),
                            IconButton.filled(
                              onPressed:
                                  running || _busy ? null : _chooseMarket,
                              icon: const Icon(Icons.radar_rounded),
                              tooltip: 'Quét coin tiềm năng hoặc chọn thủ công',
                              style: IconButton.styleFrom(
                                minimumSize: const Size(52, 52),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: running || _busy ? null : _chooseMarket,
                            icon: const Icon(Icons.radar_rounded, size: 18),
                            label: const Text(
                              'Quét coin tiềm năng · Chọn thủ công',
                            ),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(42),
                              foregroundColor: const Color(0xFFB5C5CE),
                            ),
                          ),
                        ),
                        const SizedBox(height: 17),
                        TextField(
                          controller: _sizeController,
                          enabled: !running && !_busy,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: 'Giới hạn giá trị mỗi lệnh',
                            prefixIcon: Icon(
                              Icons.account_balance_wallet_outlined,
                            ),
                            suffixText: 'USDT',
                          ),
                        ),
                        const SizedBox(height: 10),
                        _helperText(
                          _category == 'option'
                              ? 'Tín hiệu Options dựa trên Spot underlying; phí quyền chọn giới hạn rủi ro premium.'
                              : 'Bot dùng đòn bẩy 1x với hợp đồng. Lệnh sẽ đóng khi có tín hiệu ngược.',
                          icon: Icons.shield_outlined,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 22),
            _sectionTitle(
              'Tín hiệu thị trường',
              subtitle: 'Phân tích theo nến đã đóng gần nhất.',
            ),
            const SizedBox(height: 12),
            _signalCard(analysis, snapshot?['analysisSourceSymbol'] as String?),
            const SizedBox(height: 22),
            _sectionTitle(
              'Biểu đồ trực tiếp',
              subtitle: 'Nến và biến động giá từ luồng dữ liệu Bybit.',
            ),
            const SizedBox(height: 12),
            Card(
              clipBehavior: Clip.antiAlias,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(15, 16, 15, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _symbolController.text,
                                style: const TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                '${_categoryLabel(_category)} · ${timeframe.toUpperCase()}',
                                style: const TextStyle(
                                  color: Color(0xFF82919B),
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                        _liveBadge(
                          streamCategory != null && streamSymbol != null,
                        ),
                      ],
                    ),
                    if (snapshot?['analysisSourceSymbol'] != null &&
                        snapshot?['analysisSourceSymbol'] !=
                            _symbolController.text) ...[
                      const SizedBox(height: 10),
                      _helperText(
                        'Dữ liệu nến lấy từ ${snapshot?['analysisSourceSymbol']}',
                        icon: Icons.link_rounded,
                      ),
                    ],
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 270,
                      child:
                          _chartLoading && _chartCandles.isEmpty
                              ? const Center(
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                              : _chartCandles.isEmpty ||
                                  streamCategory == null ||
                                  streamSymbol == null
                              ? _emptyChart()
                              : BybitCandlestickChart(
                                key: ValueKey(
                                  '$streamCategory-$streamSymbol-$timeframe',
                                ),
                                candles: _chartCandles,
                                category: streamCategory,
                                symbol: streamSymbol,
                                timeframe: timeframe,
                              ),
                    ),
                  ],
                ),
              ),
            ),
            if (trades.isNotEmpty) ...[
              const SizedBox(height: 18),
              _sectionTitle(
                'Lịch sử khớp lệnh',
                subtitle: 'Các lệnh bot đã được sàn xác nhận khớp.',
              ),
              const SizedBox(height: 10),
              _tradeHistoryCard(trades),
            ],
            const SizedBox(height: 18),
            _helperText(
              mode == 'live'
                  ? 'Thanh lý khi dừng chỉ gửi lệnh thị trường; kết quả phụ thuộc thanh khoản, giới hạn lệnh và quyền API. Hãy kiểm tra lại tài khoản Bybit.'
                  : 'Chế độ Demo gửi lệnh lên môi trường Bybit Demo bằng khóa API Demo, không phải mô phỏng nội bộ.',
              icon: Icons.warning_amber_rounded,
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          decoration: const BoxDecoration(
            color: Color(0xFF0D141A),
            border: Border(top: BorderSide(color: Color(0xFF202C35))),
          ),
          child:
              running
                  ? FilledButton.icon(
                    onPressed: _busy ? null : _stop,
                    icon:
                        _busy
                            ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                            : const Icon(Icons.stop_rounded),
                    label: Text(
                      mode == 'live'
                          ? 'Dừng Live & thanh lý'
                          : 'Dừng Demo & thanh lý',
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF3A2022),
                      foregroundColor: const Color(0xFFFF9B96),
                    ),
                  )
                  : Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _busy ? null : () => _start('paper'),
                          icon:
                              _busy
                                  ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                  : const Icon(Icons.science_outlined),
                          label: const Text('Chạy Demo'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _busy ? null : () => _start('live'),
                          icon: const Icon(Icons.bolt_rounded),
                          label: const Text('Chạy Live'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFFFFC66D),
                            side: const BorderSide(color: Color(0xFF8A6732)),
                          ),
                        ),
                      ),
                    ],
                  ),
        ),
      ),
    );
  }

  Widget _emptyChart() => DecoratedBox(
    decoration: BoxDecoration(
      color: const Color(0xFF0B1218),
      borderRadius: BorderRadius.circular(14),
    ),
    child: const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.show_chart_rounded, size: 32, color: Color(0xFF62727D)),
          SizedBox(height: 8),
          Text(
            'Chưa có dữ liệu biểu đồ',
            style: TextStyle(color: Color(0xFF91A2AE)),
          ),
          SizedBox(height: 4),
          Text(
            'Chọn thị trường để tải dữ liệu Bybit',
            style: TextStyle(color: Color(0xFF62727D), fontSize: 11),
          ),
        ],
      ),
    ),
  );

  IconData _categoryIcon(String category) => switch (category) {
    'spot' => Icons.currency_bitcoin_rounded,
    'linear' => Icons.swap_horiz_rounded,
    'inverse' => Icons.compare_arrows_rounded,
    'option' => Icons.tune_rounded,
    _ => Icons.candlestick_chart_rounded,
  };

  String _categoryLabel(String category) => switch (category) {
    'spot' => 'Spot',
    'linear' => 'USDT',
    'inverse' => 'Inverse',
    'option' => 'Options',
    _ => category,
  };

  Widget _helperText(String text, {required IconData icon}) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 15, color: const Color(0xFF81919C)),
      const SizedBox(width: 7),
      Expanded(
        child: Text(
          text,
          style: const TextStyle(
            color: Color(0xFF91A2AE),
            fontSize: 11,
            height: 1.4,
          ),
        ),
      ),
    ],
  );
  Widget _heroCard(bool running, String mode) {
    final symbol =
        _chartSnapshot?['symbol'] ??
        _status?['symbol'] ??
        _symbolController.text;
    final strategyLabel =
        _strategy == 'short_wave' ? 'SÓNG NGẮN · 5M' : 'SÓNG DÀI · 4H';
    final directionLabel =
        _category == 'linear' || _category == 'inverse'
            ? _direction == 'both'
                ? 'LONG + SHORT'
                : _direction.toUpperCase()
            : 'LONG ONLY';
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF182832), Color(0xFF111820), Color(0xFF10161C)],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(19),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color:
                          running
                              ? const Color(0xFF71E6C2)
                              : const Color(0xFF697781),
                      shape: BoxShape.circle,
                      boxShadow:
                          running
                              ? [
                                BoxShadow(
                                  color: const Color(
                                    0xFF71E6C2,
                                  ).withValues(alpha: 0.5),
                                  blurRadius: 9,
                                ),
                              ]
                              : null,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    running ? 'BOT ĐANG CHẠY' : 'BOT ĐANG DỪNG',
                    style: const TextStyle(
                      fontSize: 11,
                      letterSpacing: 0.7,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (running) ...[
                    const SizedBox(width: 8),
                    _configBadge(mode == 'live' ? 'LIVE' : 'DEMO'),
                  ],
                  const Spacer(),
                  IconButton(
                    onPressed: _busy ? null : _refresh,
                    icon: const Icon(Icons.refresh_rounded, size: 20),
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Làm mới trạng thái',
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Text(
                symbol.toString(),
                style: const TextStyle(
                  color: Color(0xFFAAB9C2),
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 3),
              ValueListenableBuilder<double?>(
                valueListenable: _livePrice,
                builder: (context, livePrice, _) {
                  final price =
                      livePrice ??
                      _chartSnapshot?['price'] ??
                      _status?['price'];
                  return Text(
                    _priceLabel(price),
                    style: const TextStyle(
                      fontSize: 35,
                      letterSpacing: -1.2,
                      fontWeight: FontWeight.w700,
                    ),
                  );
                },
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 7,
                runSpacing: 7,
                children: [
                  _configBadge(_categoryLabel(_category).toUpperCase()),
                  _configBadge(strategyLabel),
                  _configBadge(directionLabel),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _priceLabel(Object? value) {
    if (value is! num) return '—';
    final price = value.toDouble();
    final formatted =
        price >= 100
            ? price.toStringAsFixed(2)
            : price >= 1
            ? price.toStringAsFixed(4)
            : price.toStringAsPrecision(5);
    return '\$$formatted';
  }

  Widget _configBadge(String label) => DecoratedBox(
    decoration: BoxDecoration(
      color: const Color(0xFF1B2731),
      borderRadius: BorderRadius.circular(9),
      border: Border.all(color: const Color(0xFF293842)),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      child: Text(
        label,
        style: const TextStyle(
          color: Color(0xFFB7C8D2),
          fontSize: 9,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
        ),
      ),
    ),
  );

  Widget _signalCard(Map<String, dynamic>? analysis, String? sourceSymbol) {
    if (analysis == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _chartLoading
                      ? 'Đang phân tích dữ liệu thị trường từ Bybit…'
                      : 'Chưa có tín hiệu. Kiểm tra kết nối hoặc tải lại.',
                  style: const TextStyle(color: Color(0xFFB1BEC6)),
                ),
              ),
            ],
          ),
        ),
      );
    }
    final signal = (analysis['signal'] as String? ?? 'hold').toUpperCase();
    final color =
        signal == 'LONG' || signal == 'EXIT SHORT'
            ? const Color(0xFF66E3C4)
            : signal == 'SHORT' || signal == 'EXIT LONG'
            ? const Color(0xFFFF7B78)
            : Colors.white70;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: color, width: 3)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(17),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      signal.contains('SHORT')
                          ? Icons.trending_down_rounded
                          : signal.contains('LONG')
                          ? Icons.trending_up_rounded
                          : Icons.pause_rounded,
                      color: color,
                    ),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          signal.replaceAll('_', ' '),
                          style: TextStyle(
                            color: color,
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.4,
                          ),
                        ),
                        const SizedBox(height: 3),
                        const Text(
                          'TÍN HIỆU CHIẾN LƯỢC',
                          style: TextStyle(
                            color: Color(0xFF81919C),
                            fontSize: 9,
                            letterSpacing: 0.8,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _configBadge('RSI ${_format(analysis['rsi'])}'),
                ],
              ),
              const SizedBox(height: 15),
              Text(
                analysis['reason'] as String? ?? 'Chưa có mô tả tín hiệu.',
                style: const TextStyle(color: Color(0xFFD3DCE1), height: 1.4),
              ),
              if (sourceSymbol != null) ...[
                const SizedBox(height: 6),
                Text(
                  'Nguồn phân tích: $sourceSymbol',
                  style: const TextStyle(
                    color: Color(0xFF81919C),
                    fontSize: 11,
                  ),
                ),
              ],
              const Divider(height: 25, color: Color(0xFF26323B)),
              Row(
                children: [
                  Expanded(
                    child: _metric(
                      'EMA NHANH · ${analysis['fastPeriod'] ?? 9}',
                      analysis['fastEma'],
                    ),
                  ),
                  Expanded(
                    child: _metric(
                      'EMA CHẬM · ${analysis['slowPeriod'] ?? 21}',
                      analysis['slowEma'],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _accountAssetsCard() {
    final botRunning = _status?['running'] == true;
    final accountIsLive =
        botRunning
            ? (_status?['mode'] == 'live')
            : (_balanceEnvironment == 'live');
    final totals = _accountBalance?['total'] as Map?;
    final free = _accountBalance?['free'] as Map?;
    final used = _accountBalance?['used'] as Map?;
    final summary = _accountBalance?['summary'] as Map?;
    final assetDetails = {
      for (final asset in (_accountBalance?['assets'] as List? ?? const []))
        if (asset is Map) '${asset['coin']}': Map<String, dynamic>.from(asset),
    };
    final balanceTimestamp = _accountBalance?['timestamp'] as num?;
    final updatedAt =
        balanceTimestamp == null
            ? '—'
            : DateTime.fromMillisecondsSinceEpoch(
              balanceTimestamp.toInt(),
            ).toLocal().toString().substring(0, 16);
    final assets =
        totals == null
            ? <Object>[]
            : totals.keys
                .where((coin) => ((totals[coin] as num?)?.abs() ?? 0) != 0)
                .toList();
    assets.sort((left, right) => '$left'.compareTo('$right'));
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!botRunning) ...[
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'demo',
                      label: Text('Demo'),
                      icon: Icon(Icons.science_outlined),
                    ),
                    ButtonSegment(
                      value: 'live',
                      label: Text('Live'),
                      icon: Icon(Icons.bolt_rounded),
                    ),
                  ],
                  selected: {_balanceEnvironment},
                  onSelectionChanged: (selected) {
                    setState(() {
                      _balanceEnvironment = selected.first;
                      _accountBalance = null;
                      _accountBalanceError = null;
                    });
                    _loadAccountBalance();
                  },
                ),
              ),
              const SizedBox(height: 10),
            ],
            OutlinedButton.icon(
              onPressed: _accountLoading || _busy ? null : _loadAccountBalance,
              icon:
                  _accountLoading
                      ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                      : const Icon(Icons.refresh_rounded),
              label: Text(
                _accountLoading
                    ? 'Đang tải số dư…'
                    : 'Làm mới số dư ${accountIsLive ? 'Live' : 'Demo'}',
              ),
            ),
            if (_accountBalanceError != null) ...[
              const SizedBox(height: 10),
              _message(
                'Không tải được số dư từ Bybit: $_accountBalanceError',
                isError: true,
              ),
            ],
            if (summary != null) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _walletMetric(
                      'TỔNG GIÁ TRỊ TÀI KHOẢN',
                      summary['totalEquity'],
                      suffix: ' USD',
                      emphasize: true,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _walletMetric(
                      'SỐ DƯ VÍ',
                      summary['totalWalletBalance'],
                      suffix: ' USD',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _walletMetric(
                      'KHẢ DỤNG',
                      summary['totalAvailableBalance'],
                      suffix: ' USD',
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _walletMetric(
                      'LÃI/LỖ CHƯA THỰC HIỆN',
                      summary['totalPerpUPL'],
                      suffix: ' USD',
                      positive:
                          (summary['totalPerpUPL'] as num?)?.isNegative ==
                          false,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 14,
                runSpacing: 4,
                children: [
                  _detailText(
                    'Ký quỹ ban đầu',
                    '${_precise(summary['totalInitialMargin'])} USD',
                  ),
                  _detailText(
                    'Ký quỹ duy trì',
                    '${_precise(summary['totalMaintenanceMargin'])} USD',
                  ),
                  _detailText(
                    'Tỷ lệ IM / MM',
                    '${_percent(summary['accountIMRate'])} / ${_percent(summary['accountMMRate'])}',
                  ),
                  _detailText('Cập nhật', updatedAt),
                ],
              ),
            ],
            if (assets.isNotEmpty) ...[
              const SizedBox(height: 15),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text('Chi tiết từng tài sản · ${assets.length}'),
                subtitle: const Text(
                  'Mở để xem số dư, giá trị USD và ký quỹ từng coin.',
                  style: TextStyle(color: Color(0xFF91A2AE), fontSize: 11),
                ),
                children: [
                  for (final coin in assets)
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: const EdgeInsets.only(bottom: 10),
                      title: Text(
                        '$coin',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: Text(
                        'Khả dụng ${_precise(free?[coin])} · Tổng ${_precise(totals?[coin])}',
                        style: const TextStyle(
                          color: Color(0xFF91A2AE),
                          fontSize: 11,
                        ),
                      ),
                      trailing: Text(
                        assetDetails['$coin']?['usdValue'] == null
                            ? _precise(totals?[coin])
                            : '${_precise(assetDetails['$coin']?['usdValue'])} USD',
                        style: const TextStyle(
                          color: Color(0xFFE0E7EB),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      children: [
                        Wrap(
                          spacing: 16,
                          runSpacing: 8,
                          children: [
                            _detailText('Khả dụng', _precise(free?[coin])),
                            _detailText('Đang dùng', _precise(used?[coin])),
                            _detailText('Tổng ví', _precise(totals?[coin])),
                            if (assetDetails['$coin']?['equity'] != null)
                              _detailText(
                                'Equity',
                                _precise(assetDetails['$coin']?['equity']),
                              ),
                            if (assetDetails['$coin']?['usdValue'] != null)
                              _detailText(
                                'Giá trị USD',
                                '${_precise(assetDetails['$coin']?['usdValue'])} USD',
                              ),
                            if (assetDetails['$coin']?['borrowAmount'] != null)
                              _detailText(
                                'Đang vay',
                                _precise(
                                  assetDetails['$coin']?['borrowAmount'],
                                ),
                              ),
                            if (assetDetails['$coin']?['accruedInterest'] !=
                                null)
                              _detailText(
                                'Lãi vay tích lũy',
                                _precise(
                                  assetDetails['$coin']?['accruedInterest'],
                                ),
                              ),
                            if (assetDetails['$coin']?['totalOrderIM'] != null)
                              _detailText(
                                'Ký quỹ lệnh',
                                _precise(
                                  assetDetails['$coin']?['totalOrderIM'],
                                ),
                              ),
                            if (assetDetails['$coin']?['totalPositionIM'] !=
                                null)
                              _detailText(
                                'Ký quỹ vị thế',
                                _precise(
                                  assetDetails['$coin']?['totalPositionIM'],
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                ],
              ),
            ] else if (_accountBalance != null) ...[
              const SizedBox(height: 12),
              const Text(
                'Không có số dư khác 0 trong Unified Account.',
                style: TextStyle(color: Color(0xFF91A2AE), fontSize: 12),
              ),
            ] else ...[
              const SizedBox(height: 10),
              const Text(
                'Nhấn làm mới để xem từng đồng, số dư khả dụng và số dư đang dùng.',
                style: TextStyle(color: Color(0xFF91A2AE), fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _tradeHistoryCard(List<dynamic> trades) {
    final recent = trades.reversed.take(20).toList();
    return Card(
      child: ExpansionTile(
        title: Text('${recent.length} giao dịch gần nhất'),
        subtitle: const Text(
          'Mở để xem chi tiết giá khớp, khối lượng, phí và Order ID.',
          style: TextStyle(color: Color(0xFF91A2AE), fontSize: 11),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              children: [
                for (var index = 0; index < recent.length; index++) ...[
                  if (index > 0) const Divider(height: 18),
                  _tradeDetails(
                    Map<String, dynamic>.from(recent[index] as Map),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tradeDetails(Map<String, dynamic> trade) {
    final fee = trade['fee'] as Map<String, dynamic>?;
    final category = '${trade['category'] ?? ''}';
    final isClosing = trade['entryPrice'] != null;
    final timestamp = DateTime.tryParse('${trade['timestamp'] ?? ''}');
    final time =
        timestamp == null
            ? '—'
            : timestamp.toLocal().toString().substring(0, 16);
    final averagePrice = trade['average'] ?? trade['price'];
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0D171D),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF263741)),
      ),
      padding: const EdgeInsets.all(13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${trade['symbol'] ?? ''} · ${trade['side'] ?? ''}'
                      .toUpperCase(),
                  style: const TextStyle(
                    color: Color(0xFFE0E7EB),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                '${trade['status'] ?? 'đã ghi nhận'}',
                style: const TextStyle(
                  color: Color(0xFF71E6C2),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 9),
          Wrap(
            spacing: 16,
            runSpacing: 8,
            children: [
              _detailText('Thị trường', category.isEmpty ? '—' : category),
              _detailText('Loại lệnh', trade['type'] ?? 'market'),
              _detailText('Khối lượng khớp', _precise(trade['quantity'])),
              _detailText('Giá khớp TB', _precise(averagePrice)),
              if (trade['cost'] != null)
                _detailText(
                  'Giá trị khớp',
                  '${_precise(trade['cost'])} ${category == 'spot' ? 'USDT' : 'USD'}',
                ),
              if (isClosing)
                _detailText('Giá vào vị thế', _precise(trade['entryPrice'])),
              _detailText(
                'Phí giao dịch',
                '${_precise(fee?['cost'])} ${fee?['currency'] ?? ''}',
              ),
              _detailText('Thời gian', time),
              if (trade['orderId'] != null)
                _detailText('Order ID', trade['orderId']),
              if (trade['reason'] != null)
                _detailText('Ghi chú', trade['reason']),
            ],
          ),
        ],
      ),
    );
  }

  Widget _liquidationReportCard(Map<String, dynamic> report) {
    final completed = report['completed'] as List<dynamic>? ?? const [];
    final skipped = report['skipped'] as List<dynamic>? ?? const [];
    final failed = report['failed'] as List<dynamic>? ?? const [];
    final complete = report['complete'] == true;
    return Card(
      color: complete ? const Color(0xFF10231F) : const Color(0xFF2B1B1D),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              complete ? 'Thanh lý hoàn tất' : 'Thanh lý chưa hoàn tất',
              style: TextStyle(
                color:
                    complete
                        ? const Color(0xFF71E6C2)
                        : const Color(0xFFFF9B96),
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${completed.length} thao tác hoàn tất · '
              '${skipped.length} bỏ qua · ${failed.length} lỗi',
              style: const TextStyle(fontSize: 12),
            ),
            for (final (label, values) in [
              ('Đã xử lý', completed),
              ('Bỏ qua', skipped),
              ('Thất bại', failed),
            ])
              if (values.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  label,
                  style: const TextStyle(
                    color: Color(0xFF91A2AE),
                    fontWeight: FontWeight.w700,
                    fontSize: 11,
                  ),
                ),
                for (final value in values)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('$value', style: const TextStyle(fontSize: 11)),
                  ),
              ],
          ],
        ),
      ),
    );
  }

  Widget _detailText(String label, Object? value) => Text(
    '$label: ${value ?? '—'}',
    style: const TextStyle(color: Color(0xFF91A2AE), fontSize: 10),
  );

  Widget _walletMetric(
    String label,
    Object? value, {
    String suffix = '',
    bool emphasize = false,
    bool? positive,
  }) => Container(
    padding: const EdgeInsets.all(11),
    decoration: BoxDecoration(
      color: const Color(0xFF0D171D),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: const Color(0xFF263741)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Color(0xFF81919C),
            fontSize: 9,
            letterSpacing: 0.35,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          value is num ? '${_precise(value)}$suffix' : '—',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color:
                positive == null
                    ? const Color(0xFFE0E7EB)
                    : positive
                    ? const Color(0xFF71E6C2)
                    : const Color(0xFFFF9B96),
            fontSize: emphasize ? 16 : 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    ),
  );

  String _percent(Object? value) =>
      value is num ? '${(value * 100).toStringAsFixed(3)}%' : '—';

  String _precise(Object? value) {
    if (value is! num) return value?.toString() ?? '—';
    return value.toStringAsPrecision(8).replaceFirst(RegExp(r'\.?0+($|e)'), '');
  }

  Widget _executionDashboard({
    required Map<String, dynamic>? analysis,
    required Map<String, dynamic>? position,
    required Object? latestTrade,
    required Map<String, dynamic>? snapshot,
    required bool running,
    required String mode,
  }) {
    final category = snapshot?['category'] as String? ?? _category;
    final symbol = snapshot?['symbol'] as String? ?? _symbolController.text;
    return Column(
      children: [
        BybitLivePriceStream(
          key: ValueKey('dashboard-price-$category-$symbol'),
          category: category,
          symbol: symbol,
          onPrice: (price) {
            if (mounted && _livePrice.value != price) _livePrice.value = price;
          },
          onConnectionChanged: (connected) {
            if (mounted && _marketStreamConnected.value != connected) {
              _marketStreamConnected.value = connected;
            }
          },
        ),
        ValueListenableBuilder<bool>(
          valueListenable: _marketStreamConnected,
          builder:
              (context, connected, _) => ValueListenableBuilder<double?>(
                valueListenable: _livePrice,
                builder:
                    (context, livePrice, _) => _executionDashboardContent(
                      analysis: analysis,
                      position: position,
                      latestTrade: latestTrade,
                      snapshot: snapshot,
                      running: running,
                      mode: mode,
                      livePrice: livePrice,
                      marketStreamConnected: connected,
                    ),
              ),
        ),
      ],
    );
  }

  Widget _executionDashboardContent({
    required Map<String, dynamic>? analysis,
    required Map<String, dynamic>? position,
    required Object? latestTrade,
    required Map<String, dynamic>? snapshot,
    required bool running,
    required String mode,
    required double? livePrice,
    required bool marketStreamConnected,
  }) {
    final category = snapshot?['category'] as String? ?? _category;
    final symbol = snapshot?['symbol'] as String? ?? _symbolController.text;
    final timeframe = snapshot?['timeframe'] as String? ?? '5m';
    final direction = snapshot?['direction'] as String? ?? _direction;
    final signal = analysis?['signal'] as String? ?? 'hold';
    final snapshotPrice = snapshot?['price'];
    final Object? rawPrice = livePrice ?? snapshotPrice;
    final currentPrice =
        rawPrice as num? ??
        (snapshot?['price'] as num?) ??
        (analysis?['price'] as num?);
    final atrValue = analysis?['atr'] as num?;
    final maxOrder = double.tryParse(_sizeController.text);
    final canShort = category == 'linear' || category == 'inverse';
    final tradeSide =
        signal == 'long' && direction != 'short'
            ? 'long'
            : signal == 'short' &&
                canShort &&
                (direction == 'short' || direction == 'both')
            ? 'short'
            : null;
    final activePosition =
        position != null && position['pending'] != true ? position : null;
    final entry =
        currentPrice == null || tradeSide == null
            ? null
            : currentPrice.toDouble() * (tradeSide == 'long' ? 1.0005 : 0.9995);
    final stopDistance =
        currentPrice == null
            ? null
            : category == 'option'
            ? currentPrice.toDouble() * 0.5
            : (atrValue == null
                ? null
                : (atrValue.toDouble() * 2 > currentPrice.toDouble() * 0.01
                    ? atrValue.toDouble() * 2
                    : currentPrice.toDouble() * 0.01));
    final orderBudget =
        currentPrice != null && atrValue != null && maxOrder != null
            ? sizePosition(
              equity: maxOrder * 5,
              cash: maxOrder,
              price: currentPrice.toDouble(),
              atrValue:
                  category == 'option'
                      ? currentPrice.toDouble() * 0.5
                      : atrValue.toDouble(),
              maxOrder: maxOrder,
            )
            : null;
    final market = snapshot?['market'] as Map?;
    final contractSize = (market?['contractSize'] as num?)?.toDouble() ?? 1;
    final positionContractSize =
        (activePosition?['contractSize'] as num?)?.toDouble() ?? contractSize;
    final stepText = '${(market?['lotSizeFilter'] as Map?)?['qtyStep'] ?? '0'}';
    final quantityStep = double.tryParse(stepText) ?? 0;
    final rawQuantity =
        orderBudget == null || currentPrice == null || contractSize <= 0
            ? null
            : switch (category) {
              'inverse' => orderBudget / contractSize,
              'option' => orderBudget / currentPrice / contractSize,
              _ => orderBudget / currentPrice / contractSize,
            };
    final estimatedQuantity =
        rawQuantity == null
            ? null
            : quantityStep > 0
            ? (rawQuantity / quantityStep).floorToDouble() * quantityStep
            : rawQuantity;
    final riskDistance = entry == null ? null : stopDistance;
    final stopPrice =
        entry == null || riskDistance == null
            ? null
            : tradeSide == 'long'
            ? (entry - riskDistance > currentPrice!.toDouble() * 0.001
                ? entry - riskDistance
                : currentPrice.toDouble() * 0.001)
            : entry + riskDistance;
    final projectedRisk =
        orderBudget == null ||
                riskDistance == null ||
                entry == null ||
                category == 'inverse' ||
                category == 'option'
            ? null
            : orderBudget * riskDistance / entry;
    final firstTarget =
        tradeSide != null &&
                entry != null &&
                stopPrice != null &&
                (category == 'spot' || category == 'linear')
            ? takeProfitPrice(
              side: tradeSide,
              entryPrice: entry,
              initialStopPrice: stopPrice,
              stage: 1,
            )
            : null;
    final secondTarget =
        tradeSide != null &&
                entry != null &&
                stopPrice != null &&
                (category == 'spot' || category == 'linear')
            ? takeProfitPrice(
              side: tradeSide,
              entryPrice: entry,
              initialStopPrice: stopPrice,
              stage: 2,
            )
            : null;
    final signalLabel = switch (signal) {
      'long' => 'LONG',
      'short' => 'SHORT',
      'exit_long' => 'THOÁT LONG',
      'exit_short' => 'THOÁT SHORT',
      _ => 'CHỜ TÍN HIỆU',
    };
    final signalColor =
        signal == 'long'
            ? const Color(0xFF71E6C2)
            : signal == 'short' || signal == 'exit_long'
            ? const Color(0xFFFF9B96)
            : const Color(0xFFB7C8D2);
    final latestTradeTimestamp =
        latestTrade is Map
            ? DateTime.tryParse('${latestTrade['timestamp'] ?? ''}')
            : null;
    final positionPnl =
        currentPrice != null &&
                activePosition != null &&
                activePosition['entryPrice'] is num &&
                activePosition['quantity'] is num &&
                (activePosition['category'] == 'spot' ||
                    activePosition['category'] == 'linear')
            ? (currentPrice.toDouble() -
                    (activePosition['entryPrice'] as num).toDouble()) *
                (activePosition['side'] == 'short' ? -1 : 1) *
                (activePosition['quantity'] as num).toDouble() *
                positionContractSize
            : null;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: const BoxDecoration(
          border: Border(left: BorderSide(color: Color(0xFF71E6C2), width: 3)),
        ),
        padding: const EdgeInsets.all(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.dashboard_customize_rounded,
                  size: 19,
                  color: Color(0xFF71E6C2),
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'DASHBOARD GIAO DỊCH',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
                _configBadge(
                  running
                      ? mode == 'live'
                          ? 'LIVE'
                          : 'DEMO'
                      : 'THEO DÕI',
                ),
              ],
            ),
            const SizedBox(height: 13),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        symbol.toUpperCase(),
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${_categoryLabel(category)} · ${timeframe.toUpperCase()}',
                        style: const TextStyle(
                          color: Color(0xFF91A2AE),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                if (currentPrice != null)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.circle,
                            size: 7,
                            color:
                                marketStreamConnected
                                    ? const Color(0xFF71E6C2)
                                    : const Color(0xFF81919C),
                          ),
                          const SizedBox(width: 5),
                          Text(
                            marketStreamConnected ? 'GIÁ LIVE' : 'GIÁ CUỐI',
                            style: const TextStyle(
                              color: Color(0xFF81919C),
                              fontSize: 8,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        _precise(currentPrice),
                        style: const TextStyle(
                          color: Color(0xFFE0E7EB),
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(11),
              decoration: BoxDecoration(
                color: signalColor.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: signalColor.withValues(alpha: 0.2)),
              ),
              child: Row(
                children: [
                  Icon(
                    signal == 'long'
                        ? Icons.trending_up_rounded
                        : signal == 'short'
                        ? Icons.trending_down_rounded
                        : Icons.hourglass_bottom_rounded,
                    size: 19,
                    color: signalColor,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      signalLabel,
                      style: TextStyle(
                        color: signalColor,
                        fontWeight: FontWeight.w800,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  Text(
                    'RSI ${_format(analysis?['rsi'])}',
                    style: const TextStyle(
                      color: Color(0xFFB7C8D2),
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 7),
            _helperText(
              'Giá và kịch bản thay đổi theo WebSocket; tín hiệu chiến lược được xác nhận theo nến đã đóng (${timeframe.toUpperCase()}).',
              icon: Icons.sync_rounded,
            ),
            const SizedBox(height: 12),
            if (position?['pending'] == true) ...[
              _helperText(
                'Lệnh đã gửi nhưng chưa được xác nhận khớp. Kiểm tra Order ID trên Bybit trước khi thử lại.',
                icon: Icons.pending_actions_rounded,
              ),
            ] else if (activePosition != null) ...[
              _helperText(
                'Đang quản lý vị thế ${activePosition['side'] ?? ''} tại giá vào ${_precise(activePosition['entryPrice'])}; bot không mở thêm vị thế mới khi lệnh này còn hoạt động.',
                icon: Icons.shield_outlined,
              ),
              if (positionPnl != null) ...[
                const SizedBox(height: 9),
                _walletMetric(
                  'LÃI/LỖ TẠM TÍNH · CHƯA TRỪ PHÍ',
                  positionPnl,
                  suffix: ' USDT',
                  positive: positionPnl >= 0,
                ),
              ],
            ] else if (tradeSide != null &&
                entry != null &&
                stopPrice != null &&
                orderBudget != null &&
                orderBudget > 0) ...[
              Text(
                'KỊCH BẢN NẾU TÍN HIỆU KÍCH HOẠT LỆNH',
                style: const TextStyle(
                  color: Color(0xFF91A2AE),
                  fontSize: 9,
                  letterSpacing: 0.55,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: _walletMetric('GIÁ VÀO ƯỚC TÍNH', entry)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _walletMetric(
                      'GIÁ TRỊ LỆNH ƯỚC TÍNH',
                      orderBudget,
                      suffix: ' USDT',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 14,
                runSpacing: 7,
                children: [
                  if (estimatedQuantity != null)
                    _detailText(
                      'Khối lượng dự kiến',
                      _precise(estimatedQuantity),
                    ),
                  _detailText('SL tham chiếu', _precise(stopPrice)),
                  if (firstTarget != null)
                    _detailText('TP1 · chốt 50%', _precise(firstTarget)),
                  if (secondTarget != null)
                    _detailText('TP2 · chốt 25%', _precise(secondTarget)),
                  if (projectedRisk != null)
                    _detailText(
                      'Rủi ro gộp ước tính',
                      '≈ ${_precise(projectedRisk)} USDT',
                    ),
                ],
              ),
              const SizedBox(height: 8),
              _helperText(
                category == 'linear' || category == 'spot'
                    ? 'Mô phỏng điều kiện theo tín hiệu hiện tại; sizing theo giới hạn/rủi ro bot. PnL chưa trừ phí và trượt giá. Giá market, thanh khoản và khớp lệnh thực tế có thể khác; đây không phải xác suất hay cam kết lợi nhuận.'
                    : 'Chỉ là kịch bản tham chiếu theo tín hiệu và quy mô cấu hình; hợp đồng/premium, thanh khoản, phí và khớp lệnh thực tế có thể khác. Không phải xác suất khớp hay cam kết lợi nhuận.',
                icon: Icons.info_outline_rounded,
              ),
            ] else ...[
              _helperText(
                analysis?['reason'] as String? ??
                    'Chưa có đủ dữ liệu thị trường để lập kịch bản vào lệnh.',
                icon: Icons.insights_rounded,
              ),
              if (signal == 'short' && !canShort)
                _helperText(
                  'Sản phẩm ${_categoryLabel(category)} không hỗ trợ mở Short trong bot.',
                  icon: Icons.block_rounded,
                )
              else if (signal == 'short' && direction == 'long')
                _helperText(
                  'Tín hiệu Short đang bị giới hạn bởi cấu hình chỉ Long.',
                  icon: Icons.block_rounded,
                ),
            ],
            if (latestTrade is Map) ...[
              const Divider(height: 22, color: Color(0xFF26323B)),
              Row(
                children: [
                  const Icon(
                    Icons.receipt_long_rounded,
                    size: 16,
                    color: Color(0xFF71E6C2),
                  ),
                  const SizedBox(width: 7),
                  const Expanded(
                    child: Text(
                      'KHỚP LỆNH GẦN NHẤT',
                      style: TextStyle(
                        color: Color(0xFFB7C8D2),
                        fontSize: 9,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.55,
                      ),
                    ),
                  ),
                  Text(
                    '${latestTrade['status'] ?? 'đã ghi nhận'}',
                    style: const TextStyle(
                      color: Color(0xFF71E6C2),
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 7),
              Wrap(
                spacing: 14,
                runSpacing: 6,
                children: [
                  _detailText(
                    'Lệnh',
                    '${latestTrade['symbol'] ?? '—'} ${latestTrade['side'] ?? ''}'
                        .toUpperCase(),
                  ),
                  _detailText(
                    'Loại',
                    '${latestTrade['category'] ?? '—'} · ${latestTrade['type'] ?? 'market'}',
                  ),
                  _detailText(
                    'Giá khớp TB',
                    _precise(latestTrade['average'] ?? latestTrade['price']),
                  ),
                  _detailText('Khối lượng', _precise(latestTrade['quantity'])),
                  _detailText('Giá trị', _precise(latestTrade['cost'])),
                  _detailText(
                    'Phí',
                    '${_precise((latestTrade['fee'] as Map?)?['cost'])} ${(latestTrade['fee'] as Map?)?['currency'] ?? ''}',
                  ),
                  _detailText(
                    'Thời gian',
                    latestTradeTimestamp == null
                        ? '—'
                        : latestTradeTimestamp.toLocal().toString().substring(
                          0,
                          16,
                        ),
                  ),
                  if (latestTrade['orderId'] != null)
                    _detailText('Order ID', latestTrade['orderId']),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _positionCard(Map<String, dynamic> position) {
    final category = position['category'];
    final entry = position['entryPrice'];
    final initialStop = position['initialStopPrice'];
    final side = position['side'];
    final stage = (position['takeProfitStage'] as num?)?.toInt() ?? 0;
    final riskManagementEnabled =
        (category == 'spot' || category == 'linear') &&
        position['riskManagementVersion'] == 1 &&
        entry is num &&
        initialStop is num &&
        (side == 'long' || side == 'short');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _positionDetails(position),
            if (riskManagementEnabled) ...[
              const SizedBox(height: 12),
              _helperText(
                'TP1 ${_precise(takeProfitPrice(side: side.toString(), entryPrice: entry.toDouble(), initialStopPrice: initialStop.toDouble(), stage: 1))} · '
                'TP2 ${_precise(takeProfitPrice(side: side.toString(), entryPrice: entry.toDouble(), initialStopPrice: initialStop.toDouble(), stage: 2))}. '
                '${position['takeProfitFilled'] == true
                    ? 'Đã chốt TP$stage; trailing stop đang hoạt động.'
                    : position['takeProfitSkippedStage'] != null
                    ? 'TP${position['takeProfitSkippedStage']} bỏ qua vì khối lượng dưới mức tối thiểu của sàn.'
                    : 'Chốt 50% tại 1R, 25% tại 2R.'}',
                icon: Icons.trending_up_rounded,
              ),
            ],
            if (position['pending'] == true) ...[
              const SizedBox(height: 12),
              _message(
                'Lệnh chưa được xác nhận. Hãy kiểm tra Orders/Positions trong đúng môi trường Bybit trước khi chạy lại bot.',
                isError: true,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _positionDetails(Map<String, dynamic> position) => Row(
    children: [
      Expanded(child: _metric('CHIỀU', position['side'])),
      Expanded(child: _metric('KHỐI LƯỢNG', position['quantity'])),
      Expanded(child: _metric('GIÁ VÀO', position['entryPrice'])),
      Expanded(child: _metric('DỪNG LỖ', position['stopPrice'])),
    ],
  );

  Widget _metric(String title, Object? value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Color(0xFF81919C),
          fontSize: 9,
          letterSpacing: 0.4,
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(height: 5),
      Text(
        _format(value),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Color(0xFFE0E7EB),
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    ],
  );

  Widget _liveBadge(bool available) => DecoratedBox(
    decoration: BoxDecoration(
      color: const Color(0xFF66E3C4).withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.circle,
            size: 7,
            color: available ? const Color(0xFF66E3C4) : Colors.white38,
          ),
          const SizedBox(width: 5),
          Text(
            available ? 'LUỒNG BYBIT' : 'CHƯA TẢI',
            style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    ),
  );

  Widget _sectionTitle(String text, {String? subtitle}) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        text,
        style: const TextStyle(
          color: Color(0xFFE6EDF0),
          fontSize: 16,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
        ),
      ),
      if (subtitle != null) ...[
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: const TextStyle(
            color: Color(0xFF81919C),
            fontSize: 11,
            height: 1.35,
          ),
        ),
      ],
    ],
  );

  Widget _message(String text, {required bool isError}) => Container(
    decoration: BoxDecoration(
      color: (isError ? const Color(0xFFFF7B78) : const Color(0xFF71E6C2))
          .withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(
        color: (isError ? const Color(0xFFFF7B78) : const Color(0xFF71E6C2))
            .withValues(alpha: 0.22),
      ),
    ),
    padding: const EdgeInsets.all(12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          isError ? Icons.error_outline_rounded : Icons.check_circle_outline,
          size: 18,
          color: isError ? const Color(0xFFFF9B96) : const Color(0xFF71E6C2),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color:
                  isError ? const Color(0xFFFFB0AC) : const Color(0xFFBDEBDD),
              height: 1.4,
              fontSize: 12,
            ),
          ),
        ),
      ],
    ),
  );

  String _format(Object? value) {
    if (value is num) return value.toStringAsFixed(2);
    return value?.toString() ?? '—';
  }
}
