import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'bybit_ccxt_adapter.dart';
import 'trading_strategy.dart';

bool isEligibleMarketForSelector(
  Map<String, dynamic> market,
  String category, {
  DateTime? now,
}) {
  if (market['active'] != true) return false;
  if (category == 'option') {
    final expiry = (market['expiry'] as num?)?.toInt() ?? 0;
    return expiry == 0 ||
        expiry >
            (now ?? DateTime.now())
                .add(const Duration(hours: 24))
                .millisecondsSinceEpoch;
  }
  if (category == 'inverse') return market['quote'] == 'USD';
  return const {'USDT', 'USDC'}.contains(market['quote']);
}

class MarketSelectorSheet extends StatefulWidget {
  const MarketSelectorSheet({
    required this.category,
    required this.direction,
    required this.strategy,
    super.key,
  });

  final String category;
  final String direction;
  final String strategy;

  @override
  State<MarketSelectorSheet> createState() => _MarketSelectorSheetState();
}

class _MarketSelectorSheetState extends State<MarketSelectorSheet> {
  static const _scanLimit = 30;
  static const _scanConcurrency = 4;
  static const _stablecoinBases = {
    'DAI',
    'FDUSD',
    'PYUSD',
    'TUSD',
    'USDC',
    'USDD',
    'USDE',
    'USDT',
    'USD1',
  };

  final _exchange = BybitCcxtAdapter(apiKey: '', apiSecret: '');
  final _searchController = TextEditingController();
  final _markets = <Map<String, dynamic>>[];
  final _candidates = <Map<String, dynamic>>[];
  String _query = '';
  String? _error;
  bool _loadingMarkets = true;
  bool _scanning = false;
  int _scannedCount = 0;

  @override
  void initState() {
    super.initState();
    _loadMarkets();
  }

  Future<void> _loadMarkets() async {
    try {
      final markets = await _exchange.fetchMarkets(category: widget.category);
      final eligible =
          markets.where((market) {
              return isEligibleMarketForSelector(market, widget.category);
            }).toList()
            ..sort(
              (left, right) => (left['symbol'] as String).compareTo(
                right['symbol'] as String,
              ),
            );
      if (!mounted) return;
      setState(() {
        _markets
          ..clear()
          ..addAll(eligible);
        _loadingMarkets = false;
      });
      await _scanMarkets();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingMarkets = false;
        _error = 'Không tải được danh sách thị trường: $error';
      });
    }
  }

  Future<void> _scanMarkets() async {
    if (_scanning || _markets.isEmpty) return;
    setState(() {
      _scanning = true;
      _scannedCount = 0;
      _candidates.clear();
      _error = null;
    });
    try {
      final tickers = await _exchange.fetchTickers(category: widget.category);
      final marketById = {
        for (final market in _markets) market['id'] as String: market,
      };
      final liquidMarkets =
          tickers.where((ticker) {
              final turnover = ticker['quoteVolume'];
              final market = marketById[ticker['id']];
              return marketById.containsKey(ticker['id']) &&
                  !_stablecoinBases.contains(market?['base']) &&
                  ticker['last'] is num &&
                  turnover is num &&
                  turnover > 0;
            }).toList()
            ..sort(
              (left, right) => (right['quoteVolume'] as num).compareTo(
                left['quoteVolume'] as num,
              ),
            );
      final selected = liquidMarkets.take(_scanLimit).toList();
      if (selected.isEmpty) {
        throw StateError('Không có market đủ dữ liệu thanh khoản để quét.');
      }
      final maximumTurnover = (selected.first['quoteVolume'] as num).toDouble();
      final results = <Map<String, dynamic>>[];
      var failedMarketCount = 0;
      String? firstMarketError;
      for (var start = 0; start < selected.length; start += _scanConcurrency) {
        final end = math.min(start + _scanConcurrency, selected.length);
        final batch = await Future.wait(
          selected.sublist(start, end).map((ticker) async {
            try {
              final id = ticker['id'] as String;
              final market = marketById[id]!;
              final analysisCategory =
                  widget.category == 'option' ? 'spot' : widget.category;
              final analysisSymbol =
                  widget.category == 'option' ? '${market['base']}USDT' : id;
              final candles = await _exchange.fetchOHLCV(
                category: analysisCategory,
                symbol: analysisSymbol,
                timeframe: widget.strategy == 'short_wave' ? '5m' : '4h',
                limit: 120,
              );
              final closedCandles =
                  candles.length > 1
                      ? candles.sublist(0, candles.length - 1)
                      : candles;
              final analysis = analyzeCandles(closedCandles, widget.strategy);
              if (analysis == null) return null;
              final turnover = (ticker['quoteVolume'] as num).toDouble();
              final percentage =
                  (ticker['percentage'] as num?)?.toDouble() ?? 0;
              final fast = analysis['fastEma'] as double;
              final slow = analysis['slowEma'] as double;
              final strength = analysis['rsi'] as double;
              final signal = analysis['signal'] as String;
              final bullish = fast >= slow;
              final bias = bullish ? 'long' : 'short';
              final technicalScore = switch ((bias, signal)) {
                ('long', 'long' || 'exit_short') => 45.0,
                ('short', 'short' || 'exit_long') => 45.0,
                ('long', _) when strength >= 45 && strength <= 68 => 34.0,
                ('short', _) when strength >= 32 && strength <= 55 => 34.0,
                _ => 18.0,
              };
              final liquidityScore =
                  math.log(1 + turnover) / math.log(1 + maximumTurnover) * 35;
              final momentumScore = math.min(20.0, percentage.abs() / 8 * 20);
              final directionAdjustment =
                  widget.category == 'spot' || widget.category == 'option'
                      ? (bullish ? 10.0 : -15.0)
                      : widget.direction == 'both'
                      ? 0.0
                      : bias == widget.direction
                      ? 10.0
                      : -15.0;
              return <String, dynamic>{
                ...market,
                'ticker': ticker,
                'analysis': analysis,
                'analysisSymbol': analysisSymbol,
                'score':
                    liquidityScore +
                    momentumScore +
                    technicalScore +
                    directionAdjustment,
                'bias': bias == 'long' ? 'Long' : 'Short',
              };
            } catch (error) {
              failedMarketCount++;
              firstMarketError ??= error.toString();
              return null;
            }
          }),
        );
        results.addAll(batch.whereType<Map<String, dynamic>>());
        if (mounted) setState(() => _scannedCount = end);
      }
      results.sort(
        (left, right) =>
            (right['score'] as double).compareTo(left['score'] as double),
      );
      if (!mounted) return;
      setState(() {
        _candidates
          ..clear()
          ..addAll(results.take(20));
        _scanning = false;
        _error =
            failedMarketCount == 0
                ? null
                : results.isEmpty
                ? 'Không đọc được nến của $failedMarketCount market. Lỗi mẫu: $firstMarketError'
                : 'Đã bỏ qua $failedMarketCount market bị lỗi dữ liệu; vẫn hiển thị ${results.length} kết quả hợp lệ. Lỗi mẫu: $firstMarketError';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _error = 'Quét thị trường thất bại: $error';
      });
    }
  }

  List<Map<String, dynamic>> get _visibleMarkets {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return _markets;
    return _markets
        .where(
          (market) =>
              (market['symbol'] as String).toLowerCase().contains(query) ||
              (market['id'] as String).toLowerCase().contains(query),
        )
        .toList();
  }

  List<Map<String, dynamic>> get _visibleCandidates {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return _candidates;
    return _candidates
        .where(
          (market) =>
              (market['symbol'] as String).toLowerCase().contains(query) ||
              (market['id'] as String).toLowerCase().contains(query),
        )
        .toList();
  }

  @override
  void dispose() {
    _exchange.close();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: FractionallySizedBox(
      heightFactor: 0.92,
      child: DefaultTabController(
        length: 2,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 14),
              child: Row(
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Chọn thị trường',
                          style: TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Quét gợi ý hoặc tìm và chọn thủ công.',
                          style: TextStyle(
                            color: Color(0xFF91A2AE),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                    tooltip: 'Đóng',
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _searchController,
                onChanged: (value) => setState(() => _query = value),
                decoration: const InputDecoration(
                  hintText: 'Tìm tên coin hoặc mã hợp đồng',
                  prefixIcon: Icon(Icons.search_rounded),
                ),
              ),
            ),
            const SizedBox(height: 12),
            const TabBar(
              tabs: [
                Tab(text: 'Gợi ý tiềm năng'),
                Tab(text: 'Tất cả thị trường'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [_buildScannerList(), _buildManualList()],
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _buildScannerList() {
    if (_loadingMarkets) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_markets.isEmpty) return _errorPanel();
    if (_scanning) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 14),
            Text('Đang phân tích $_scannedCount/$_scanLimit thị trường…'),
          ],
        ),
      );
    }
    if (_candidates.isEmpty) {
      return Column(
        children: [
          _InfoPanel(
            icon:
                _error == null
                    ? Icons.insights_rounded
                    : Icons.error_outline_rounded,
            isError: _error != null,
            message:
                _error ??
                (widget.category == 'option'
                    ? 'Xếp hạng tối đa 30 hợp đồng theo thanh khoản và biến động; tín hiệu EMA/RSI lấy từ Spot underlying. Xu hướng giảm chỉ để theo dõi, không có nghĩa là khuyến nghị mua Put.'
                    : 'Chưa có market đủ dữ liệu từ lượt quét. Xếp hạng kết hợp thanh khoản 24 giờ, biến động và EMA/RSI trên 30 market có thanh khoản cao nhất; hướng được chọn chỉ ảnh hưởng điểm xếp hạng, không ẩn các market ngược xu hướng. Đây chỉ là gợi ý, không bảo đảm lợi nhuận.'),
          ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton.icon(
              onPressed: _scanMarkets,
              icon: const Icon(Icons.radar_rounded),
              label: const Text('Quét thị trường'),
            ),
          ),
        ],
      );
    }
    final candidates = _visibleCandidates;
    if (candidates.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Không có kết quả khớp từ khóa này trong danh sách gợi ý. '
            'Xóa từ khóa hoặc mở tab Tất cả thị trường.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFF91A2AE), height: 1.4),
          ),
        ),
      );
    }
    return Column(
      children: [
        if (_error != null)
          _InfoPanel(
            icon: Icons.warning_amber_rounded,
            isError: true,
            message: _error!,
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Top ${_candidates.length} theo thanh khoản và tín hiệu',
                  style: const TextStyle(
                    color: Color(0xFF91A2AE),
                    fontSize: 11,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: _scanMarkets,
                icon: const Icon(Icons.refresh_rounded, size: 17),
                label: const Text('Quét lại'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            itemCount: candidates.length,
            separatorBuilder: (_, _) => const SizedBox(height: 7),
            itemBuilder:
                (context, index) => _candidateTile(candidates[index], index),
          ),
        ),
      ],
    );
  }

  Widget _buildManualList() {
    if (_loadingMarkets) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_markets.isEmpty) return _errorPanel();
    final markets = _visibleMarkets;
    if (markets.isEmpty) {
      return const Center(child: Text('Không tìm thấy thị trường phù hợp.'));
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
      itemCount: markets.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 56),
      itemBuilder: (context, index) {
        final market = markets[index];
        return ListTile(
          leading: _coinAvatar(market['base'] as String? ?? '?'),
          title: Text(
            market['symbol'] as String? ?? '',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            '${market['id']} · ${market['quote'] ?? market['settle'] ?? ''}',
            style: const TextStyle(fontSize: 11, color: Color(0xFF91A2AE)),
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => Navigator.pop(context, market['id'] as String),
        );
      },
    );
  }

  Widget _candidateTile(Map<String, dynamic> market, int index) {
    final ticker = market['ticker'] as Map<String, dynamic>;
    final analysis = market['analysis'] as Map<String, dynamic>;
    final change = (ticker['percentage'] as num?)?.toDouble() ?? 0;
    final bullish = market['bias'] == 'Long';
    final biasColor =
        bullish ? const Color(0xFF71E6C2) : const Color(0xFFFF8D88);
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 13, vertical: 4),
        leading: _coinAvatar(market['base'] as String? ?? '?', rank: index + 1),
        title: Row(
          children: [
            Expanded(
              child: Text(
                market['symbol'] as String? ?? '',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            Text(
              '${change >= 0 ? '+' : ''}${change.toStringAsFixed(2)}%',
              style: TextStyle(
                color:
                    change >= 0
                        ? const Color(0xFF71E6C2)
                        : const Color(0xFFFF8D88),
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Wrap(
            spacing: 7,
            runSpacing: 4,
            children: [
              Text(
                widget.category == 'option'
                    ? bullish
                        ? 'Underlying tăng'
                        : 'Underlying giảm · thận trọng'
                    : widget.category == 'spot' && !bullish
                    ? 'Giảm · theo dõi'
                    : widget.category != 'spot' &&
                        widget.direction != 'both' &&
                        market['bias'].toString().toLowerCase() !=
                            widget.direction
                    ? '${market['bias']} · ngược chiều chọn'
                    : '${market['bias']} xu hướng',
                style: TextStyle(
                  color: biasColor,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                'RSI ${(analysis['rsi'] as num).toStringAsFixed(0)}',
                style: const TextStyle(fontSize: 10),
              ),
              Text(
                '24h ${_formatTurnover(ticker['quoteVolume'])}',
                style: const TextStyle(fontSize: 10),
              ),
              Text(
                'Điểm ${(market['score'] as double).toStringAsFixed(0)}',
                style: const TextStyle(fontSize: 10),
              ),
            ],
          ),
        ),
        trailing: const Icon(Icons.add_circle_outline_rounded, size: 20),
        onTap: () => Navigator.pop(context, market['id'] as String),
      ),
    );
  }

  Widget _coinAvatar(String symbol, {int? rank}) => CircleAvatar(
    radius: 19,
    backgroundColor: const Color(0xFF1B2932),
    child:
        rank == null
            ? Text(
              symbol.characters.take(1).toString(),
              style: const TextStyle(
                color: Color(0xFF71E6C2),
                fontWeight: FontWeight.w700,
              ),
            )
            : Text(
              '$rank',
              style: const TextStyle(
                color: Color(0xFF71E6C2),
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
  );

  Widget _errorPanel() => Padding(
    padding: const EdgeInsets.all(16),
    child: _InfoPanel(
      icon: Icons.error_outline_rounded,
      message: _error ?? 'Không có thị trường khả dụng.',
      isError: true,
    ),
  );

  String _formatTurnover(Object? value) {
    if (value is! num) return '—';
    final amount = value.toDouble();
    if (amount >= 1e9) return '\$${(amount / 1e9).toStringAsFixed(1)}B';
    if (amount >= 1e6) return '\$${(amount / 1e6).toStringAsFixed(1)}M';
    if (amount >= 1e3) return '\$${(amount / 1e3).toStringAsFixed(0)}K';
    return '\$${amount.toStringAsFixed(0)}';
  }
}

class _InfoPanel extends StatelessWidget {
  const _InfoPanel({
    required this.icon,
    required this.message,
    this.isError = false,
  });

  final IconData icon;
  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF1B2932),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              icon,
              size: 18,
              color:
                  isError ? const Color(0xFFFF8D88) : const Color(0xFF71E6C2),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                  color:
                      isError
                          ? const Color(0xFFFFB0AC)
                          : const Color(0xFFB7C5CD),
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
