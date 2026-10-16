import 'package:flutter_test/flutter_test.dart';
import 'package:bybit_auto_trader/market_selector_sheet.dart';

void main() {
  group('isEligibleMarketForSelector', () {
    test(
      'includes inverse contracts quoted in USD and settled in the base',
      () {
        expect(
          isEligibleMarketForSelector({
            'active': true,
            'base': 'DOGE',
            'quote': 'USD',
            'settle': 'DOGE',
          }, 'inverse'),
          isTrue,
        );
      },
    );

    test('excludes inactive inverse markets and non-USD quotes', () {
      expect(
        isEligibleMarketForSelector({
          'active': true,
          'quote': 'USDT',
          'settle': 'BTC',
        }, 'inverse'),
        isFalse,
      );
      expect(
        isEligibleMarketForSelector({
          'active': false,
          'quote': 'USD',
          'settle': 'DOGE',
        }, 'inverse'),
        isFalse,
      );
    });

    test('keeps spot markets quoted in USDT or USDC', () {
      expect(
        isEligibleMarketForSelector({'active': true, 'quote': 'USDT'}, 'spot'),
        isTrue,
      );
      expect(
        isEligibleMarketForSelector({'active': true, 'quote': 'BTC'}, 'spot'),
        isFalse,
      );
    });

    test('excludes options expiring within the next day', () {
      final now = DateTime.utc(2026, 10, 15);
      expect(
        isEligibleMarketForSelector(
          {
            'active': true,
            'quote': 'USDC',
            'expiry': now.add(const Duration(hours: 23)).millisecondsSinceEpoch,
          },
          'option',
          now: now,
        ),
        isFalse,
      );
      expect(
        isEligibleMarketForSelector(
          {
            'active': true,
            'quote': 'USDC',
            'expiry': now.add(const Duration(hours: 25)).millisecondsSinceEpoch,
          },
          'option',
          now: now,
        ),
        isTrue,
      );
    });
  });
}
