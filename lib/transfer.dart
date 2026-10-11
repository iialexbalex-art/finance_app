import 'money.dart';

class Transfer {
  Transfer({
    required this.id,
    required this.spaceId,
    required this.revision,
    required this.sourceId,
    required this.targetId,
    required this.sourceMinor,
    required this.targetMinor,
    required this.sourceCurrency,
    required this.targetCurrency,
    required this.sourceScale,
    required this.targetScale,
    required this.sourceName,
    required this.targetName,
    required this.date,
    required this.comment,
    required this.feeMinor,
    this.feeCategoryId,
    this.feeCategoryPath,
  });
  final String id,
      spaceId,
      revision,
      sourceId,
      targetId,
      sourceCurrency,
      targetCurrency,
      sourceName,
      targetName,
      date,
      comment;
  final int sourceScale, targetScale;
  final BigInt sourceMinor, targetMinor, feeMinor;
  final String? feeCategoryId, feeCategoryPath;
  factory Transfer.fromJson(Map<String, dynamic> j) => Transfer(
    id: j['id'] as String,
    spaceId: j['space_id'] as String,
    revision: j['revision'] as String,
    sourceId: j['source_id'] as String,
    targetId: j['target_id'] as String,
    sourceMinor: minorFromJson(j['source_minor']),
    targetMinor: minorFromJson(j['target_minor']),
    sourceCurrency: j['source_currency'] as String,
    targetCurrency: j['target_currency'] as String,
    sourceScale: j['source_scale'] as int,
    targetScale: j['target_scale'] as int,
    sourceName: j['source_name'] as String,
    targetName: j['target_name'] as String,
    date: j['transfer_date'] as String,
    comment: j['comment'] as String,
    feeMinor: minorFromJson(j['fee_minor']),
    feeCategoryId: j['fee_category_id'] as String?,
    feeCategoryPath: j['fee_category_path'] as String?,
  );
}

class TransferPage {
  const TransferPage(this.items, this.hasMore);
  final List<Transfer> items;
  final bool hasMore;
}

class PendingTransfer {
  PendingTransfer({
    required this.requestId,
    required Map<String, dynamic> data,
    required Map<String, dynamic> display,
  }) : data = Map.unmodifiable(data),
       display = Map.unmodifiable(display);
  final String requestId;
  final Map<String, dynamic> data, display;
  String get spaceId => data['space_id'] as String;
  Map<String, dynamic> toJson() => {
    'request_id': requestId,
    'data': data,
    'display': display,
  };
  factory PendingTransfer.fromJson(Map<String, dynamic> j) => PendingTransfer(
    requestId: j['request_id'] as String,
    data: Map<String, dynamic>.from(j['data'] as Map),
    display: Map<String, dynamic>.from(j['display'] as Map),
  );
}

/// Exact rational source; display truncates to eight decimal places, never used for posting.
String transferRate(
  BigInt debit,
  int debitScale,
  BigInt credit,
  int creditScale,
) {
  if (debit <= BigInt.zero || credit <= BigInt.zero) return '';
  final numerator = credit * BigInt.from(10).pow(debitScale);
  final denominator = debit * BigInt.from(10).pow(creditScale);
  final whole = numerator ~/ denominator;
  final remainder = numerator % denominator;
  if (remainder == BigInt.zero) return whole.toString();
  final fraction = (remainder * BigInt.from(10).pow(8) ~/ denominator)
      .toString()
      .padLeft(8, '0');
  final exact = remainder * BigInt.from(10).pow(8) % denominator == BigInt.zero;
  return '$whole,${exact ? fraction.replaceFirst(RegExp(r'0+$'), '') : fraction}${exact ? '' : '…'}';
}

BigInt equalCurrencyAmount(BigInt amount, int fromScale, int toScale) {
  final numerator = amount * BigInt.from(10).pow(toScale),
      divisor = BigInt.from(10).pow(fromScale);
  if (numerator % divisor != BigInt.zero) {
    throw const FormatException(
      'Сумму нельзя точно зачислить с точностью кошелька-получателя.',
    );
  }
  return checkedMinor(numerator ~/ divisor);
}
