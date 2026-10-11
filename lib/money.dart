// Money never passes through int, double or JSON numeric values.
final minMinor = BigInt.parse('-9223372036854775808');
final maxMinor = BigInt.parse('9223372036854775807');

const currencySymbols = <String, String>{
  'RUB': '₽',
  'KZT': '₸',
  'USD': r'$',
  'EUR': '€',
  'THB': '฿',
  'EGP': 'EGP',
  'TRY': '₺',
};

String currencyLabel(String code) =>
    currencySymbols[code] == null ? code : '$code (${currencySymbols[code]})';

BigInt checkedMinor(BigInt value) {
  if (value < minMinor || value > maxMinor) {
    throw const FormatException('Сумма выходит за допустимый диапазон.');
  }
  return value;
}

BigInt parseMoney(String input) {
  final text = input.trim();
  if (!RegExp(r'^-?[0-9]+(?:[.,][0-9]{1,2})?$').hasMatch(text)) {
    throw const FormatException(
      'Введите сумму с точкой или запятой, не более двух знаков после разделителя.',
    );
  }
  final negative = text.startsWith('-');
  final parts = (negative ? text.substring(1) : text).split(RegExp('[.,]'));
  final fraction = parts.length == 2 ? parts[1].padRight(2, '0') : '00';
  final magnitude =
      BigInt.parse(parts[0]) * BigInt.from(100) + BigInt.parse(fraction);
  return checkedMinor(negative ? -magnitude : magnitude);
}

// Fail closed if a server/query accidentally returns a JSON number. Converting
// a rounded JS Number to String/BigInt would not recover its original precision.
BigInt minorFromJson(Object? raw) {
  if (raw is! String || !RegExp(r'^-?[0-9]+$').hasMatch(raw)) {
    throw const FormatException(
      'Сервер вернул сумму в неточном формате. Обновите данные.',
    );
  }
  return checkedMinor(BigInt.parse(raw));
}

String formatMoney(BigInt minor, {int scale = 2}) {
  checkedMinor(minor);
  return formatExactMoney(minor, scale: scale);
}

// Aggregates may exceed bigint; PostgreSQL SUM(bigint) returns exact numeric.
String formatExactMoney(BigInt minor, {int scale = 2}) {
  if (scale < 0 || scale > 4) {
    throw const FormatException('Неизвестный масштаб валюты.');
  }
  final sign = minor.isNegative ? '-' : '';
  final digits = minor.abs().toString().padLeft(scale + 1, '0');
  if (scale == 0) return '$sign$digits';
  final split = digits.length - scale;
  return '$sign${digits.substring(0, split)},${digits.substring(split)}';
}

BigInt parseExpenseMoney(String input, {required int scale}) {
  if (scale < 0 || scale > 4) {
    throw const FormatException('Неизвестный масштаб валюты.');
  }
  final text = input.trim();
  final pattern = scale == 0
      ? r'^[0-9]+$'
      : '^[0-9]+(?:[.,][0-9]{1,$scale})?\$';
  if (!RegExp(pattern).hasMatch(text)) {
    throw FormatException(
      'Введите положительную сумму: не более $scale знаков после разделителя, без округления.',
    );
  }
  final parts = text.split(RegExp('[.,]'));
  final factor = BigInt.from(10).pow(scale);
  final amount =
      BigInt.parse(parts.first) * factor +
      (parts.length == 2
          ? BigInt.parse(parts[1].padRight(scale, '0'))
          : BigInt.zero);
  checkedMinor(amount);
  if (amount <= BigInt.zero) {
    throw const FormatException('Сумма расхода должна быть больше нуля.');
  }
  return amount;
}

BigInt aggregateFromJson(Object? raw) {
  if (raw is! String || !RegExp(r'^-?[0-9]+$').hasMatch(raw)) {
    throw const FormatException('Сервер вернул неточную денежную сумму.');
  }
  return BigInt.parse(raw);
}
