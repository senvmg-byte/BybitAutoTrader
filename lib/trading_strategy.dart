const strategyProfiles = <String, Map<String, Object>>{
  'short_wave': {'timeframe': '5', 'fastPeriod': 9, 'slowPeriod': 21},
  'long_wave': {'timeframe': '240', 'fastPeriod': 20, 'slowPeriod': 50},
};

double? ema(List<double> values, int period) {
  if (values.length < period || period < 1) return null;
  final alpha = 2 / (period + 1);
  return values
      .skip(1)
      .fold<double>(
        values.first,
        (current, value) => alpha * value + (1 - alpha) * current,
      );
}

double? rsi(List<double> closes, {int period = 14}) {
  if (closes.length < period + 1) return null;
  var gains = 0.0;
  var losses = 0.0;
  final first = closes.length - period - 1;
  for (var index = first + 1; index < closes.length; index++) {
    final change = closes[index] - closes[index - 1];
    gains += change > 0 ? change : 0;
    losses += change < 0 ? -change : 0;
  }
  gains /= period;
  losses /= period;
  if (gains == 0 && losses == 0) return 50;
  if (losses == 0) return 100;
  return 100 - 100 / (1 + gains / losses);
}

double? atr(List<List<double>> candles, {int period = 14}) {
  if (candles.length < period + 1) return null;
  var total = 0.0;
  for (var index = candles.length - period; index < candles.length; index++) {
    final candle = candles[index];
    final previousClose = candles[index - 1][4];
    total += [
      candle[2] - candle[3],
      (candle[2] - previousClose).abs(),
      (candle[3] - previousClose).abs(),
    ].reduce((left, right) => left > right ? left : right);
  }
  return total / period;
}

double? _recentSwingPrice(
  List<List<double>> candles, {
  required bool high,
  int lookback = 30,
  int confirmationBars = 2,
}) {
  if (candles.length < confirmationBars * 2 + 1) return null;
  final start = (candles.length - lookback).clamp(0, candles.length).toInt();
  final latestPivot = candles.length - confirmationBars - 1;
  for (var index = latestPivot; index >= start + confirmationBars; index--) {
    final candidate = candles[index][high ? 2 : 3];
    var isPivot = true;
    for (
      var neighbor = index - confirmationBars;
      neighbor <= index + confirmationBars;
      neighbor++
    ) {
      if (neighbor == index) continue;
      final other = candles[neighbor][high ? 2 : 3];
      if (high ? other > candidate : other < candidate) {
        isPivot = false;
        break;
      }
    }
    if (isPivot) return candidate;
  }

  final recentCandles = candles.skip(start);
  return recentCandles
      .map((candle) => candle[high ? 2 : 3])
      .reduce(high ? mathMax : mathMin);
}

Map<String, Object?>? analyzeCandles(
  List<List<double>> candles,
  String strategy,
) {
  final profile = strategyProfiles[strategy];
  if (profile == null) throw FormatException('Chiến lược không hợp lệ.');
  final fastPeriod = profile['fastPeriod']! as int;
  final slowPeriod = profile['slowPeriod']! as int;
  if (candles.length < slowPeriod + 2 ||
      candles.any(
        (candle) =>
            candle.length < 6 ||
            !candle.every((value) => value.isFinite) ||
            candle[2] < candle[3] ||
            candle[4] <= 0,
      )) {
    return null;
  }
  final closes = candles.map((candle) => candle[4]).toList();
  final fast = ema(closes, fastPeriod)!;
  final slow = ema(closes, slowPeriod)!;
  final previousFast = ema(closes.sublist(0, closes.length - 1), fastPeriod)!;
  final previousSlow = ema(closes.sublist(0, closes.length - 1), slowPeriod)!;
  final strength = rsi(closes);
  final averageTrueRange = atr(candles);
  if (strength == null || averageTrueRange == null) return null;
  final crossedUp = previousFast <= previousSlow && fast > slow;
  final crossedDown = previousFast >= previousSlow && fast < slow;
  var signal = 'hold';
  if (crossedUp && strength >= 45 && strength <= 68) {
    signal = 'long';
  } else if (crossedDown && strength >= 32 && strength <= 55) {
    signal = 'short';
  } else if (crossedDown || strength >= 75) {
    signal = 'exit_long';
  } else if (crossedUp || strength <= 25) {
    signal = 'exit_short';
  }
  return {
    'signal': signal,
    'price': closes.last,
    'fastEma': fast,
    'slowEma': slow,
    'fastPeriod': fastPeriod,
    'slowPeriod': slowPeriod,
    'rsi': strength,
    'atr': averageTrueRange,
    'swingLow': _recentSwingPrice(candles, high: false),
    'swingHigh': _recentSwingPrice(candles, high: true),
    'candleTimestamp': candles.last[0],
    'reason': switch (signal) {
      'long' =>
        'EMA $fastPeriod cắt lên EMA $slowPeriod; RSI xác nhận xu hướng tăng.',
      'short' =>
        'EMA $fastPeriod cắt xuống EMA $slowPeriod; RSI xác nhận xu hướng giảm.',
      'exit_long' =>
        crossedDown
            ? 'Giao cắt giảm; đóng vị thế Long.'
            : 'RSI quá mua; đóng vị thế Long.',
      'exit_short' =>
        crossedUp
            ? 'Giao cắt tăng; đóng vị thế Short.'
            : 'RSI quá bán; đóng vị thế Short.',
      _ => 'Chưa có giao cắt đủ điều kiện.',
    },
  };
}

double sizePosition({
  required double equity,
  required double cash,
  required double price,
  required double stopDistance,
  required double maxOrder,
  double riskFraction = 0.005,
}) {
  if ([
    equity,
    cash,
    price,
    stopDistance,
    maxOrder,
    riskFraction,
  ].any((value) => !value.isFinite || value <= 0) ||
      riskFraction > 0.02) {
    return 0;
  }
  final riskBudget = equity * riskFraction;
  return [
    maxOrder,
    equity * 0.2,
    riskBudget / (stopDistance / price),
    cash,
  ].reduce((left, right) => left < right ? left : right);
}

double structureStopPrice({
  required String side,
  required double referencePrice,
  required double atrValue,
  required double? swingLow,
  required double? swingHigh,
  double atrBuffer = 0.4,
}) {
  final structureLevel = side == 'long' ? swingLow : swingHigh;
  if ((side != 'long' && side != 'short') ||
      [
        referencePrice,
        atrValue,
        atrBuffer,
      ].any((value) => !value.isFinite || value <= 0) ||
      referencePrice <= 0 ||
      structureLevel == null ||
      !structureLevel.isFinite ||
      structureLevel <= 0) {
    throw const FormatException('Dữ liệu stop theo cấu trúc không hợp lệ.');
  }
  final stop =
      side == 'long'
          ? structureLevel - atrValue * atrBuffer
          : structureLevel + atrValue * atrBuffer;
  if (side == 'long' ? stop >= referencePrice : stop <= referencePrice) {
    throw const FormatException(
      'Không có mức swing hợp lệ phía ngoài giá hiện tại.',
    );
  }
  return stop;
}

double takeProfitPrice({
  required String side,
  required double entryPrice,
  required double initialStopPrice,
  required int stage,
}) {
  if ((side != 'long' && side != 'short') ||
      !entryPrice.isFinite ||
      entryPrice <= 0 ||
      !initialStopPrice.isFinite ||
      initialStopPrice <= 0 ||
      stage < 1 ||
      stage > 2) {
    throw const FormatException('Thông tin chốt lời không hợp lệ.');
  }
  final risk = (entryPrice - initialStopPrice).abs();
  if (risk <= 0) throw const FormatException('Mức rủi ro không hợp lệ.');
  final distance = risk * stage;
  return side == 'long' ? entryPrice + distance : entryPrice - distance;
}

double trailingStopPrice({
  required String side,
  required double entryPrice,
  required double currentStopPrice,
  required double favorablePrice,
  required double atrValue,
}) {
  if ((side != 'long' && side != 'short') ||
      [
        entryPrice,
        currentStopPrice,
        favorablePrice,
        atrValue,
      ].any((value) => !value.isFinite || value <= 0) ||
      atrValue <= 0) {
    throw const FormatException('Thông tin trailing stop không hợp lệ.');
  }
  final distance = atrValue * 1.5;
  if (side == 'long') {
    final candidate = favorablePrice - distance;
    return [entryPrice, currentStopPrice, candidate].reduce(mathMax);
  }
  final candidate = favorablePrice + distance;
  return [
    entryPrice,
    currentStopPrice,
    candidate,
  ].reduce((left, right) => left < right ? left : right);
}

double mathMax(double left, double right) => left > right ? left : right;
