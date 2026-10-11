import 'dart:convert';
import 'dart:typed_data';

import 'expense.dart';
import 'report_model.dart';
import 'money.dart';

class ReportExport {
  ReportExport({
    required this.data,
    required this.params,
    required this.now,
    DateTime? formedAt,
  }) : formedAt = formedAt ?? now;
  final ReportData data;
  final ReportParams params;
  final DateTime now;
  final DateTime formedAt;
  late final List<ReportOperation> a = data.select(params, params.range(now));
  late final List<ReportOperation> b = params.kind.comparison
      ? data.select(params, params.comparisonRange(now))
      : [];
  late final Map<NamedReportGroup, List<ReportOperation>> groupRows = {
    for (final group in params.groups)
      group: data.select(group.params, params.range(now)),
  };
  late final Set<String> _aKeys = a.map((o) => o.key).toSet();
  late final Set<String> _bKeys = b.map((o) => o.key).toSet();
  late final Map<NamedReportGroup, Set<String>> _groupKeys = {
    for (final entry in groupRows.entries)
      entry.key: entry.value.map((o) => o.key).toSet(),
  };
  late final List<ReportOperation> operations = uniqueReportGroups([
    a,
    b,
    ...groupRows.values,
  ]);
  List<List<Object>> get parameterRows => [
    ['Параметр', 'Значение'],
    ['Отчёт', params.title],
    ['Пространство', params.scopeLabel],
    [
      'Доступные пространства',
      data.spaces
          .where((s) => params.scope == 'all' || s.kind == params.scope)
          .map((s) => s.name)
          .join(', '),
    ],
    ['Период A', params.range(now).label],
    ['Дней A', params.range(now).days],
    if (params.kind.comparison) ...[
      ['Период B', params.comparisonRange(now).label],
      ['Дней B', params.comparisonRange(now).days],
    ],
    ['Валютный режим', 'Раздельно по валютам, без конвертации'],
    ['Валюта', params.currency.isEmpty ? 'Все' : params.currency],
    [
      'Валюта диаграммы и долей',
      params.chartCurrency.isEmpty
          ? reportTotals(a).firstOrNull?.currency ?? 'Нет операций'
          : params.chartCurrency,
    ],
    [
      'Кошельки',
      params.walletIds.map((id) => data.wallet(id)?.name ?? id).join(', '),
    ],
    [
      'Категории (с подкатегориями)',
      params.categoryIds.map((id) => data.category(id)?.name ?? id).join(', '),
    ],
    ['Поиск', params.search],
    ['Показатель', params.metric.label],
    ['Группировка', params.grouping.label],
    ['Представление', params.view.label],
    ['Сортировка', params.sort],
    ['Линия', params.cumulative ? 'Нарастающим итогом' : 'По дням'],
    [
      'Часовой пояс',
      '${now.timeZoneName} (UTC${now.timeZoneOffset.isNegative ? '' : '+'}${now.timeZoneOffset.inMinutes / 60})',
    ],
    ['Даты операций', 'Календарные даты пользователя; включены обе границы'],
    ['Сформировано', formedAt.toIso8601String()],
    for (final group in params.groups)
      ['Группа: ${group.name}', jsonEncode(group.params.toJson())],
  ];
  List<List<Object>> get summaryRows {
    final result = <List<Object>>[
      [
        'Группа / период',
        'Валюта',
        'Доходы',
        'Расходы',
        'Денежный результат',
        'Операций',
      ],
    ];
    void add(String name, List<ReportOperation> rows) {
      for (final t in reportTotals(rows)) {
        result.add([
          name,
          t.currency,
          _Number(t.income, t.scale),
          _Number(t.expense, t.scale),
          _Number(t.income - t.expense, t.scale),
          t.count,
        ]);
      }
    }

    add('Период A', a);
    if (params.kind.comparison) {
      add('Период B', b);
      result.add([
        'Сравнение',
        'Валюта',
        'Сумма A',
        'Сумма B',
        'Разница',
        'Изменение',
      ]);
      final at = reportTotals(a), bt = reportTotals(b);
      for (final currency in {
        ...at.map((t) => t.currency),
        ...bt.map((t) => t.currency),
      }) {
        final x = at.where((t) => t.currency == currency).firstOrNull;
        final y = bt.where((t) => t.currency == currency).firstOrNull;
        final scale = (x?.scale ?? 0) > (y?.scale ?? 0)
            ? x!.scale
            : y?.scale ?? 0;
        final av =
            (x?.value(params.metric) ?? BigInt.zero) *
            BigInt.from(10).pow(scale - (x?.scale ?? scale));
        final bv =
            (y?.value(params.metric) ?? BigInt.zero) *
            BigInt.from(10).pow(scale - (y?.scale ?? scale));
        result.add([
          'A − B',
          currency,
          _Number(av, scale),
          _Number(bv, scale),
          _Number(av - bv, scale),
          reportChange(av, bv),
        ]);
        final ca = {
          for (final x in reportBuckets(
            data,
            a,
            params,
            currency,
            grouping: ReportGrouping.category,
          ))
            x.key: x,
        };
        final cb = {
          for (final x in reportBuckets(
            data,
            b,
            params,
            currency,
            grouping: ReportGrouping.category,
          ))
            x.key: x,
        };
        result.add([
          'Категория',
          'Валюта',
          'Сумма A',
          'Сумма B',
          'Разница',
          'Изменение',
          'Операций A',
          'Операций B',
        ]);
        for (final key in {...ca.keys, ...cb.keys}) {
          final x = ca[key], y = cb[key];
          final av =
              (x?.total.value(params.metric) ?? BigInt.zero) *
              BigInt.from(10).pow(scale - (x?.total.scale ?? scale));
          final bv =
              (y?.total.value(params.metric) ?? BigInt.zero) *
              BigInt.from(10).pow(scale - (y?.total.scale ?? scale));
          result.add([
            x?.label ?? y!.label,
            currency,
            _Number(av, scale),
            _Number(bv, scale),
            _Number(av - bv, scale),
            reportChange(av, bv),
            x?.rows.length ?? 0,
            y?.rows.length ?? 0,
          ]);
        }
      }
    }
    for (final group in params.groups) {
      add(group.name, data.select(group.params, params.range(now)));
    }
    if (params.groups.isNotEmpty) {
      add(
        'Уникальные операции групп (группы неаддитивны)',
        uniqueReportGroups([
          for (final group in params.groups)
            data.select(group.params, params.range(now)),
        ]),
      );
    }
    result.add([
      'Разбивка A',
      'Валюта',
      'Доходы',
      'Расходы',
      'Денежный результат',
      'Операций',
    ]);
    for (final t in reportTotals(a)) {
      for (final bucket in reportBuckets(
        data,
        a,
        params,
        t.currency,
        range: params.range(now),
      )) {
        final t = bucket.total;
        result.add([
          bucket.label,
          t.currency,
          _Number(t.income, t.scale),
          _Number(t.expense, t.scale),
          _Number(t.income - t.expense, t.scale),
          t.count,
        ]);
      }
    }
    return result;
  }

  List<List<Object>> get operationRows => [
    [
      'Дата',
      'Тип',
      'Пространство',
      'Категория',
      'Кошелёк',
      'Сумма',
      'Валюта',
      'Комментарий',
      'ID',
      'Периоды / группы',
    ],
    for (final o in operations)
      [
        parseExpenseDate(o.entry.date),
        o.kind.label,
        data.spaces.where((s) => s.id == o.spaceId).first.name,
        data.categoryName(o.entry),
        data.walletName(o.entry),
        _Number(o.entry.amount, o.entry.scale),
        o.entry.currency,
        o.entry.comment,
        o.entry.id,
        [
          if (_aKeys.contains(o.key)) 'A',
          if (_bKeys.contains(o.key)) 'B',
          for (final g in params.groups)
            if (_groupKeys[g]!.contains(o.key)) g.name,
        ].join(', '),
      ],
  ];
  Uint8List csv() {
    String cell(Object v) {
      var s = v is _Number
          ? v.text
          : v is DateTime
          ? expenseDate(v)
          : v.toString();
      if (v is String && RegExp(r'^[\s\x00-\x1f]*[=+@-]').hasMatch(s)) {
        s = "'$s";
      }
      return '"${s.replaceAll('"', '""')}"';
    }

    return Uint8List.fromList(
      utf8.encode(
        '\uFEFF${[
          ['Параметры'],
          ...parameterRows,
          [],
          ['Сводка'],
          ...summaryRows,
          [],
          ['Операции'],
          ...operationRows,
        ].map((row) => row.map((v) => cell(v as Object)).join(';')).join('\r\n')}\r\n',
      ),
    );
  }

  Uint8List xlsx() {
    final files = <String, String>{};
    const ns = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main';
    final sheets = {
      'Сводка': summaryRows,
      'Операции': operationRows,
      'Параметры': parameterRows,
    };
    files['[Content_Types].xml'] =
        '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>${List.generate(3, (i) => '<Override PartName="/xl/worksheets/sheet${i + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>').join()}</Types>';
    files['_rels/.rels'] = '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>';
    files['xl/workbook.xml'] =
        '<workbook xmlns="$ns" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>${List.generate(3, (i) => '<sheet name="${sheets.keys.elementAt(i)}" sheetId="${i + 1}" r:id="rId${i + 1}"/>').join()}</sheets></workbook>';
    files['xl/_rels/workbook.xml.rels'] =
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">${List.generate(3, (i) => '<Relationship Id="rId${i + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet${i + 1}.xml"/>').join()}<Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>';
    files['xl/styles.xml'] =
        '<styleSheet xmlns="$ns"><numFmts count="4"><numFmt numFmtId="164" formatCode="yyyy-mm-dd"/><numFmt numFmtId="165" formatCode="0.0"/><numFmt numFmtId="166" formatCode="0.000"/><numFmt numFmtId="167" formatCode="0.0000"/></numFmts><fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border/></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="7"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="4" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="1" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="166" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="167" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>';
    for (var i = 0; i < 3; i++) {
      final rows = sheets.values.elementAt(i);
      files['xl/worksheets/sheet${i + 1}.xml'] =
          '<worksheet xmlns="$ns"><sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews><cols><col min="1" max="10" width="24" customWidth="1"/></cols><sheetData>${List.generate(rows.length, (r) => '<row r="${r + 1}">${List.generate(rows[r].length, (c) => _cell(rows[r][c], '${_column(c)}${r + 1}')).join()}</row>').join()}</sheetData></worksheet>';
    }
    return _zip(files);
  }
}

class _Number {
  const _Number(this.minor, this.scale);
  final BigInt minor;
  final int scale;
  String get text => formatExactMoney(minor, scale: scale).replaceAll(',', '.');
}

String _xml(String s) => s
    .replaceAll(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f]'), '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
String _column(int i) {
  var n = i + 1, s = '';
  while (n > 0) {
    s = String.fromCharCode(65 + (n - 1) % 26) + s;
    n = (n - 1) ~/ 26;
  }
  return s;
}

String _cell(Object v, String ref) {
  if (v is _Number) {
    final style = switch (v.scale) {
      0 => 3,
      1 => 4,
      2 => 2,
      3 => 5,
      4 => 6,
      _ => throw const FormatException('Неизвестный масштаб валюты'),
    };
    return '<c r="$ref" s="$style"><v>${v.text}</v></c>';
  }
  if (v is int) return '<c r="$ref"><v>$v</v></c>';
  if (v is DateTime) {
    return '<c r="$ref" s="1"><v>${DateTime.utc(v.year, v.month, v.day).difference(DateTime.utc(1899, 12, 30)).inDays}</v></c>';
  }
  // Inline strings never become formulas, even when they start with '='.
  return '<c r="$ref" t="inlineStr"><is><t xml:space="preserve">${_xml(v.toString())}</t></is></c>';
}

// A small standards-compliant ZIP writer (stored entries). XLSX is an OOXML ZIP,
// not CSV renamed. CRC and offsets are computed over actual UTF-8 bytes.
Uint8List _zip(Map<String, String> files) {
  final output = BytesBuilder(), central = BytesBuilder();
  void number(BytesBuilder b, int n, int bytes) {
    for (var i = 0; i < bytes; i++) {
      b.addByte((n >> (8 * i)) & 255);
    }
  }

  int crc(List<int> bytes) {
    var value = 0xffffffff;
    for (final byte in bytes) {
      value ^= byte;
      for (var i = 0; i < 8; i++) {
        value = (value >> 1) ^ ((value & 1) != 0 ? 0xedb88320 : 0);
      }
    }
    return (value ^ 0xffffffff) & 0xffffffff;
  }

  for (final entry in files.entries) {
    final name = utf8.encode(entry.key),
        bytes = utf8.encode(entry.value),
        offset = output.length,
        checksum = crc(bytes);
    number(output, 0x04034b50, 4);
    for (final n in [20, 0x800, 0, 0, 0]) {
      number(output, n, 2);
    }
    for (final n in [checksum, bytes.length, bytes.length]) {
      number(output, n, 4);
    }
    number(output, name.length, 2);
    number(output, 0, 2);
    output.add(name);
    output.add(bytes);
    number(central, 0x02014b50, 4);
    for (final n in [20, 20, 0x800, 0, 0, 0]) {
      number(central, n, 2);
    }
    for (final n in [checksum, bytes.length, bytes.length]) {
      number(central, n, 4);
    }
    for (final n in [name.length, 0, 0, 0, 0]) {
      number(central, n, 2);
    }
    number(central, 0, 4);
    number(central, offset, 4);
    central.add(name);
  }
  final offset = output.length, length = central.length;
  output.add(central.takeBytes());
  number(output, 0x06054b50, 4);
  number(output, 0, 2);
  number(output, 0, 2);
  number(output, files.length, 2);
  number(output, files.length, 2);
  number(output, length, 4);
  number(output, offset, 4);
  number(output, 0, 2);
  return output.takeBytes();
}
