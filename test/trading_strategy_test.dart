import 'package:bybit_auto_trader/trading_strategy.dart';
import 'package:flutter_test/flutter_test.dart';

List<List<double>> risingCandles(int count) => List.generate(
  count,
  (index) => [
    index * 300000.0,
    100 + index.toDouble(),
    102 + index.toDouble(),
    99 + index.toDouble(),
    101 + index.toDouble(),
    10,
  ],
);

void main() {
  test('wave profiles select 5-minute and 4-hour EMA settings', () {
    expect(strategyProfiles['short_wave'], {
      'timeframe': '5',
      'fastPeriod': 9,
      'slowPeriod': 21,
    });
    expect(strategyProfiles['long_wave'], {
      'timeframe': '240',
      'fastPeriod': 20,
      'slowPeriod': 50,
    });
    expect(analyzeCandles(risingCandles(40), 'long_wave'), isNull);
    expect(analyzeCandles(risingCandles(80), 'long_wave')?['slowPeriod'], 50);
  });

  test('invalid strategy is reported rather than silently selected', () {
    expect(
      () => analyzeCandles(risingCandles(80), 'unknown'),
      throwsFormatException,
    );
  });

  test('partial take-profit targets are one and two units of initial risk', () {
    expect(
      takeProfitPrice(
        side: 'long',
        entryPrice: 100,
        initialStopPrice: 90,
        stage: 1,
      ),
      110,
    );
    expect(
      takeProfitPrice(
        side: 'long',
        entryPrice: 100,
        initialStopPrice: 90,
        stage: 2,
      ),
      120,
    );
    expect(
      takeProfitPrice(
        side: 'short',
        entryPrice: 100,
        initialStopPrice: 110,
        stage: 2,
      ),
      80,
    );
  });

  test('trailing stop tightens to breakeven and never moves backward', () {
    expect(
      trailingStopPrice(
        side: 'long',
        entryPrice: 100,
        currentStopPrice: 80,
        favorablePrice: 120,
        atrValue: 5,
      ),
      112.5,
    );
    expect(
      trailingStopPrice(
        side: 'long',
        entryPrice: 100,
        currentStopPrice: 115,
        favorablePrice: 120,
        atrValue: 5,
      ),
      115,
    );
    expect(
      trailingStopPrice(
        side: 'short',
        entryPrice: 100,
        currentStopPrice: 120,
        favorablePrice: 80,
        atrValue: 5,
      ),
      87.5,
    );
    expect(
      trailingStopPrice(
        side: 'short',
        entryPrice: 100,
        currentStopPrice: 85,
        favorablePrice: 80,
        atrValue: 5,
      ),
      85,
    );
  });
}
