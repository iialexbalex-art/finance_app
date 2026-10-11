import 'package:finance_app/money.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final cases = {
    '1234,56': '123456',
    '1234.56': '123456',
    '0,01': '1',
    '0': '0',
    '-0,00': '0',
    '-100,50': '-10050',
    '1.2': '120',
    ' 001,20 ': '120',
    '90071992547409,93': '9007199254740993',
    '92233720368547758,07': '9223372036854775807',
    '-92233720368547758,08': '-9223372036854775808',
  };
  for (final entry in cases.entries) {
    test('Exact parse and string roundtrip: ${entry.key}', () {
      final minor = parseMoney(entry.key);
      expect(minor.toString(), entry.value);
      expect(parseMoney(formatMoney(minor)), minor);
      expect(minorFromJson(entry.value), minor);
    });
  }
  for (final invalid in [
    '1,234',
    '1.234',
    '1,000',
    '92233720368547758,08',
    '-92233720368547758,09',
    '999999999999999999999999999999999',
    '',
    '1e3',
    'NaN',
    'Infinity',
    '1 234,56',
    '1,2.3',
    '--1',
    '.01',
    '1,',
  ]) {
    test('Reject without rounding: $invalid', () {
      expect(() => parseMoney(invalid), throwsFormatException);
    });
  }
  test('Format zero, negative and bigint extremes', () {
    expect(formatMoney(BigInt.zero), '0,00');
    expect(formatMoney(BigInt.from(-10050)), '-100,50');
    expect(formatMoney(minMinor), '-92233720368547758,08');
    expect(formatMoney(maxMinor), '92233720368547758,07');
  });
  test('Reject numeric JSON instead of repairing already rounded values', () {
    expect(() => minorFromJson(1), throwsFormatException);
    expect(() => minorFromJson(null), throwsFormatException);
    expect(() => minorFromJson('1.0'), throwsFormatException);
    expect(() => minorFromJson('9223372036854775808'), throwsFormatException);
  });
  test('Supported currencies have stable interface labels', () {
    expect(currencyLabel('RUB'), 'RUB (₽)');
    expect(currencyLabel('USD'), r'USD ($)');
    expect(currencyLabel('KZT'), 'KZT (₸)');
    expect(currencyLabel('THB'), 'THB (฿)');
    expect(currencyLabel('EGP'), 'EGP (EGP)');
    expect(currencyLabel('TRY'), 'TRY (₺)');
  });
}
