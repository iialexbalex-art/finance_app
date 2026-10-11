import 'expense.dart';
import 'expense_filter.dart';
import 'finance_repository.dart';
import 'category.dart';
import 'money.dart';

enum ReportKind {
  businessExpenses('Расходы бизнеса'),
  businessIncomes('Доходы бизнеса'),
  personalExpenses('Личные расходы'),
  incomeCategories('Доходы по категориям'),
  expenseCategories('Расходы по категориям'),
  incomeStructure('Структура доходов'),
  expenseStructure('Структура расходов'),
  incomeComparison('Сравнение доходов за периоды'),
  expenseComparison('Сравнение расходов за периоды'),
  cashResult('Доходы и расходы'),
  incomeMonths('Доходы по месяцам'),
  expenseMonths('Расходы по месяцам'),
  dailyFlow('Денежный поток по дням'),
  custom('Настраиваемый отчёт');

  const ReportKind(this.label);
  final String label;
  bool get comparison => this == incomeComparison || this == expenseComparison;
  bool get monthly => this == incomeMonths || this == expenseMonths;
}

enum ReportPeriod {
  today('Сегодня'),
  yesterday('Вчера'),
  week('Текущая неделя'),
  month('Текущий месяц'),
  previousMonth('Прошлый месяц'),
  year('Текущий год'),
  last12('Последние 12 месяцев'),
  all('Весь период'),
  custom('Произвольные даты');

  const ReportPeriod(this.label);
  final String label;
}

enum ReportMetric {
  expense('Расходы'),
  income('Доходы'),
  net('Денежный результат');

  const ReportMetric(this.label);
  final String label;
}

enum ReportGrouping {
  category('По категориям'),
  wallet('По кошелькам'),
  day('По дням'),
  week('По неделям'),
  month('По месяцам');

  const ReportGrouping(this.label);
  final String label;
}

enum ReportView {
  table('Таблица'),
  bars('Столбцы'),
  line('Линия'),
  ring('Кольцо');

  const ReportView(this.label);
  final String label;
}

class ReportRange {
  const ReportRange(this.from, this.to);
  final String from, to;
  int get days =>
      parseExpenseDate(to).difference(parseExpenseDate(from)).inDays + 1;
  bool contains(String date) =>
      date.compareTo(from) >= 0 && date.compareTo(to) <= 0;
  String get label =>
      '${russianExpenseDate(parseExpenseDate(from))} — ${russianExpenseDate(parseExpenseDate(to))}';
  ReportRange get comparablePrevious {
    final start = parseExpenseDate(from);
    final end = parseExpenseDate(to);
    if (start.day == 1 && start.month == end.month && start.year == end.year) {
      final previous = DateTime.utc(start.year, start.month - 1);
      final last = DateTime.utc(start.year, start.month, 0).day;
      return ReportRange(
        expenseDate(previous),
        expenseDate(
          DateTime.utc(previous.year, previous.month, end.day.clamp(1, last)),
        ),
      );
    }
    return ReportRange(
      expenseDate(start.subtract(Duration(days: days))),
      expenseDate(start.subtract(const Duration(days: 1))),
    );
  }
}

class ReportParams {
  ReportParams({
    this.kind = ReportKind.expenseCategories,
    this.scope = 'all',
    this.period = ReportPeriod.month,
    this.metric = ReportMetric.expense,
    this.grouping = ReportGrouping.category,
    this.view = ReportView.bars,
    this.walletIds = const [],
    this.categoryIds = const [],
    this.currency = '',
    this.chartCurrency = '',
    this.search = '',
    this.from,
    this.to,
    this.bFrom,
    this.bTo,
    this.fullPreviousMonth = false,
    this.cumulative = false,
    this.sort = 'amount',
    this.groups = const [],
  });
  ReportKind kind;
  String scope, currency, chartCurrency, search, sort;
  ReportPeriod period;
  ReportMetric metric;
  ReportGrouping grouping;
  ReportView view;
  List<String> walletIds, categoryIds;
  String? from, to, bFrom, bTo;
  bool fullPreviousMonth, cumulative;
  List<NamedReportGroup> groups;
  String get scopeLabel => switch (scope) {
    'business' => 'Бизнес',
    'personal' => 'Личное',
    _ => 'Всё',
  };
  factory ReportParams.preset(ReportKind kind) {
    final income = [
      ReportKind.businessIncomes,
      ReportKind.incomeCategories,
      ReportKind.incomeStructure,
      ReportKind.incomeComparison,
      ReportKind.incomeMonths,
    ].contains(kind);
    return ReportParams(
      kind: kind,
      scope:
          kind == ReportKind.businessExpenses ||
              kind == ReportKind.businessIncomes
          ? 'business'
          : kind == ReportKind.personalExpenses
          ? 'personal'
          : 'all',
      metric: income
          ? ReportMetric.income
          : [
              ReportKind.cashResult,
              ReportKind.dailyFlow,
              ReportKind.custom,
            ].contains(kind)
          ? ReportMetric.net
          : ReportMetric.expense,
      period: kind.monthly ? ReportPeriod.last12 : ReportPeriod.month,
      grouping: kind.monthly
          ? ReportGrouping.month
          : [ReportKind.dailyFlow, ReportKind.cashResult].contains(kind)
          ? ReportGrouping.day
          : ReportGrouping.category,
      view:
          [
            ReportKind.incomeStructure,
            ReportKind.expenseStructure,
          ].contains(kind)
          ? ReportView.ring
          : kind.comparison
          ? ReportView.line
          : ReportView.bars,
    );
  }
  ReportRange range(DateTime now) {
    final today = DateTime.utc(now.year, now.month, now.day);
    final start = switch (period) {
      ReportPeriod.today => today,
      ReportPeriod.yesterday => today.subtract(const Duration(days: 1)),
      ReportPeriod.week => today.subtract(Duration(days: today.weekday - 1)),
      ReportPeriod.month => DateTime.utc(now.year, now.month),
      ReportPeriod.previousMonth => DateTime.utc(now.year, now.month - 1),
      ReportPeriod.year => DateTime.utc(now.year),
      ReportPeriod.last12 => DateTime.utc(now.year, now.month - 11),
      ReportPeriod.all => DateTime.utc(1),
      ReportPeriod.custom => parseExpenseDate(from!),
    };
    final end = switch (period) {
      ReportPeriod.yesterday => start,
      ReportPeriod.previousMonth => DateTime.utc(now.year, now.month, 0),
      ReportPeriod.custom => parseExpenseDate(to!),
      _ => today,
    };
    if (end.isBefore(start)) {
      throw const FormatException('Начало периода позже конца.');
    }
    return ReportRange(expenseDate(start), expenseDate(end));
  }

  ReportRange comparisonRange(DateTime now) {
    if (bFrom != null && bTo != null) return ReportRange(bFrom!, bTo!);
    if (fullPreviousMonth) {
      final start = parseExpenseDate(range(now).from);
      return ReportRange(
        expenseDate(DateTime.utc(start.year, start.month - 1)),
        expenseDate(DateTime.utc(start.year, start.month, 0)),
      );
    }
    return range(now).comparablePrevious;
  }

  int get filterCount =>
      walletIds.length +
      categoryIds.length +
      (search.isEmpty ? 0 : 1) +
      (currency.isEmpty ? 0 : 1);
  String get title => switch (kind) {
    ReportKind.businessExpenses ||
    ReportKind.personalExpenses ||
    ReportKind.businessIncomes =>
      metric == ReportMetric.income
          ? scope == 'business'
                ? 'Доходы бизнеса'
                : scope == 'personal'
                ? 'Личные доходы'
                : 'Доходы'
          : scope == 'business'
          ? 'Расходы бизнеса'
          : scope == 'personal'
          ? 'Личные расходы'
          : 'Расходы',
    _ => kind.label,
  };
  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'scope': scope,
    'period': period.name,
    'metric': metric.name,
    'grouping': grouping.name,
    'view': view.name,
    'walletIds': walletIds,
    'categoryIds': categoryIds,
    'currency': currency,
    'chartCurrency': chartCurrency,
    'search': search,
    'from': from,
    'to': to,
    'bFrom': bFrom,
    'bTo': bTo,
    'fullPreviousMonth': fullPreviousMonth,
    'cumulative': cumulative,
    'sort': sort,
    'groups': groups.map((g) => g.toJson()).toList(),
  };
  factory ReportParams.fromJson(Map<String, dynamic> j) => ReportParams(
    kind: ReportKind.values.byName(j['kind']),
    scope: j['scope'],
    period: ReportPeriod.values.byName(j['period']),
    metric: ReportMetric.values.byName(j['metric']),
    grouping: ReportGrouping.values.byName(j['grouping']),
    view: ReportView.values.byName(j['view']),
    walletIds: List<String>.from(j['walletIds']),
    categoryIds: List<String>.from(j['categoryIds']),
    currency: j['currency'],
    chartCurrency: j['chartCurrency'] ?? '',
    search: j['search'],
    from: j['from'],
    to: j['to'],
    bFrom: j['bFrom'],
    bTo: j['bTo'],
    fullPreviousMonth: j['fullPreviousMonth'] ?? false,
    cumulative: j['cumulative'] ?? false,
    sort: j['sort'] ?? 'amount',
    groups: [
      for (final g in j['groups'] ?? [])
        NamedReportGroup.fromJson(Map<String, dynamic>.from(g)),
    ],
  );
  ReportParams copy() => ReportParams.fromJson(toJson());
}

class NamedReportGroup {
  NamedReportGroup(this.name, this.params);
  String name;
  final ReportParams params;
  Map<String, dynamic> toJson() => {'name': name, 'params': params.toJson()};
  factory NamedReportGroup.fromJson(Map<String, dynamic> j) => NamedReportGroup(
    j['name'],
    ReportParams.fromJson(Map<String, dynamic>.from(j['params'])),
  );
}

class ReportOperation {
  const ReportOperation(this.spaceId, this.kind, this.entry);
  final String spaceId;
  final CategoryKind kind;
  final Expense entry;
  String get key => '${kind.name}:${entry.id}';
}

class ReportData {
  const ReportData(this.spaces, this.wallets, this.categories, this.operations);
  final List<FinanceSpace> spaces;
  final List<Wallet> wallets;
  final List<FinanceCategory> categories;
  final List<ReportOperation> operations;
  Wallet? wallet(String id) => wallets.where((w) => w.id == id).firstOrNull;
  FinanceCategory? category(String id) =>
      categories.where((c) => c.id == id).firstOrNull;
  String categoryName(Expense e) {
    final names = <String>[];
    final seen = <String>{};
    var c = category(e.categoryId);
    while (c != null && seen.add(c.id)) {
      names.insert(0, '${c.name}${c.isArchived ? ' (архив)' : ''}');
      c = category(c.parentId ?? '');
    }
    return names.isNotEmpty
        ? names.join(' / ')
        : e.categoryPath.isEmpty
        ? 'Без категории'
        : e.categoryPath;
  }

  String walletName(Expense e) {
    final w = wallet(e.walletId);
    return w == null
        ? e.walletName
        : '${w.name}${w.isArchived ? ' (архив)' : ''}';
  }

  Set<String> descendants(List<String> ids) {
    final result = ids.toSet();
    var changed = true;
    while (changed) {
      changed = false;
      for (final c in categories) {
        if (result.contains(c.parentId) && result.add(c.id)) changed = true;
      }
    }
    return result;
  }

  List<ReportOperation> select(ReportParams p, ReportRange range) {
    final spaceIds = spaces
        .where((s) => p.scope == 'all' || s.kind == p.scope)
        .map((s) => s.id)
        .toSet();
    final categories = descendants(p.categoryIds);
    final search = p.search.trim().toLowerCase();
    return operations.where((o) {
      final e = o.entry;
      return spaceIds.contains(o.spaceId) &&
          range.contains(e.date) &&
          (p.metric == ReportMetric.net || o.kind.name == p.metric.name) &&
          (p.walletIds.isEmpty || p.walletIds.contains(e.walletId)) &&
          (categories.isEmpty || categories.contains(e.categoryId)) &&
          (p.currency.isEmpty || p.currency == e.currency) &&
          (search.isEmpty ||
              '${e.comment} ${categoryName(e)} ${walletName(e)}'
                  .toLowerCase()
                  .contains(search));
    }).toList();
  }
}

/// Uses the same RLS-protected keyset queries as the operation journal. No local
/// pending drafts, balances or synthetic transfer fees enter this dataset.
Future<ReportData> loadReportData(
  FinanceRepository repository,
  List<FinanceSpace> spaces,
  String userId,
  ReportRange range,
) async {
  final wallets = <Wallet>[], categories = <FinanceCategory>[];
  final operations = <ReportOperation>[];
  for (final space in spaces) {
    wallets.addAll(await repository.loadWallets(space.id));
    for (final kind in CategoryKind.values) {
      if (kind == CategoryKind.income && space.ownerUserId != userId) continue;
      categories.addAll(await repository.loadCategories(space.id, kind));
      Expense? cursor;
      final seen = <String>{};
      while (true) {
        final filter = ExpenseFilter(from: range.from, to: range.to);
        final result = kind == CategoryKind.income
            ? await repository.queryIncomes(
                space.id,
                filter,
                before: cursor,
                includeTotals: false,
              )
            : await repository.queryExpenses(
                space.id,
                filter,
                before: cursor,
                includeTotals: false,
              );
        for (final e in result.page.items) {
          if (!seen.add(e.id)) {
            throw StateError('Повтор страницы журнала. Обновите отчёт.');
          }
          operations.add(ReportOperation(space.id, kind, e));
        }
        if (!result.page.hasMore) break;
        if (result.page.items.isEmpty) {
          throw StateError('Пустая промежуточная страница.');
        }
        cursor = result.page.items.last;
      }
    }
  }
  return ReportData(spaces, wallets, categories, operations);
}

class ReportAmount {
  const ReportAmount(
    this.currency,
    this.scale,
    this.income,
    this.expense,
    this.count,
  );
  final String currency;
  final int scale, count;
  final BigInt income, expense;
  BigInt value(ReportMetric metric) => switch (metric) {
    ReportMetric.income => income,
    ReportMetric.expense => expense,
    ReportMetric.net => income - expense,
  };
  String format(ReportMetric metric) =>
      '${formatExactMoney(value(metric), scale: scale)} $currency';
}

List<ReportAmount> reportTotals(Iterable<ReportOperation> rows) {
  final byCurrency = <String, List<ReportOperation>>{};
  for (final o in rows) {
    (byCurrency[o.entry.currency] ??= []).add(o);
  }
  return [
    for (final currency in byCurrency.keys.toList()..sort())
      _sum(currency, byCurrency[currency]!),
  ];
}

ReportAmount _sum(
  String currency,
  List<ReportOperation> rows, {
  int? targetScale,
}) {
  final scale =
      targetScale ??
      rows.fold<int>(0, (v, o) => v > o.entry.scale ? v : o.entry.scale);
  var income = BigInt.zero, expense = BigInt.zero;
  for (final o in rows) {
    final amount = o.entry.amount * BigInt.from(10).pow(scale - o.entry.scale);
    if (o.kind == CategoryKind.income) {
      income += amount;
    } else {
      expense += amount;
    }
  }
  return ReportAmount(currency, scale, income, expense, rows.length);
}

class ReportBucket {
  const ReportBucket(this.key, this.label, this.rows, this.total);
  final String key, label;
  final List<ReportOperation> rows;
  final ReportAmount total;
}

List<ReportBucket> reportBuckets(
  ReportData data,
  List<ReportOperation> rows,
  ReportParams p,
  String currency, {
  ReportGrouping? grouping,
  ReportRange? range,
}) {
  final g = grouping ?? p.grouping;
  final groups = <String, List<ReportOperation>>{};
  final labels = <String, String>{};
  for (final o in rows.where((o) => o.entry.currency == currency)) {
    final e = o.entry;
    final date = parseExpenseDate(e.date);
    final key = switch (g) {
      ReportGrouping.category => '${o.kind.name}:${e.categoryId}',
      ReportGrouping.wallet => e.walletId,
      ReportGrouping.day => e.date,
      ReportGrouping.week => expenseDate(
        date.subtract(Duration(days: date.weekday - 1)),
      ),
      ReportGrouping.month => expenseDate(DateTime.utc(date.year, date.month)),
    };
    labels[key] = switch (g) {
      ReportGrouping.category => data.categoryName(e),
      ReportGrouping.wallet => data.walletName(e),
      ReportGrouping.month =>
        '${date.month.toString().padLeft(2, '0')}.${date.year}',
      _ => russianExpenseDate(parseExpenseDate(key)),
    };
    (groups[key] ??= []).add(o);
  }
  // Add elapsed empty calendar buckets; future dates are never generated.
  if (range != null &&
      g != ReportGrouping.category &&
      g != ReportGrouping.wallet) {
    var date = parseExpenseDate(range.from);
    final end = parseExpenseDate(range.to);
    // An all-history range starts at the earliest actual entry, not year 1.
    if (range.from == '0001-01-01') {
      final dates = rows.map((o) => o.entry.date).toList()..sort();
      date = dates.isEmpty ? end : parseExpenseDate(dates.first);
    }
    if (g == ReportGrouping.month) date = DateTime.utc(date.year, date.month);
    if (g == ReportGrouping.week) {
      date = date.subtract(Duration(days: date.weekday - 1));
    }
    while (!date.isAfter(end)) {
      final key = expenseDate(date);
      groups.putIfAbsent(key, () => []);
      labels.putIfAbsent(
        key,
        () => g == ReportGrouping.month
            ? '${date.month.toString().padLeft(2, '0')}.${date.year}'
            : russianExpenseDate(date),
      );
      date = g == ReportGrouping.month
          ? DateTime.utc(date.year, date.month + 1)
          : date.add(Duration(days: g == ReportGrouping.week ? 7 : 1));
    }
  }
  final currencyScale = rows
      .where((o) => o.entry.currency == currency)
      .fold<int>(0, (v, o) => v > o.entry.scale ? v : o.entry.scale);
  final result = [
    for (final key in groups.keys)
      ReportBucket(
        key,
        labels[key]!,
        groups[key]!,
        _sum(currency, groups[key]!, targetScale: currencyScale),
      ),
  ];
  result.sort(
    (a, b) => g == ReportGrouping.category || g == ReportGrouping.wallet
        ? switch (p.sort) {
            'name' => a.label.compareTo(b.label),
            'count' => b.rows.length.compareTo(a.rows.length),
            _ => b.total.value(p.metric).compareTo(a.total.value(p.metric)),
          }
        : a.key.compareTo(b.key),
  );
  return result;
}

String reportChange(BigInt a, BigInt b) {
  if (b == BigInt.zero) {
    return a == BigInt.zero ? '0%' : '—, в предыдущем периоде 0';
  }
  if (b.isNegative) return '—, неположительная база';
  final hundredths = (a - b) * BigInt.from(10000) ~/ b;
  return '${formatExactMoney(hundredths)}%';
}

double reportRatio(BigInt value, BigInt base) => base <= BigInt.zero
    ? 0
    : ((value * BigInt.from(1000000) ~/ base).toDouble() / 1000000).clamp(0, 1);

String reportShare(BigInt value, BigInt base) => base <= BigInt.zero
    ? '—'
    : '${formatExactMoney(value * BigInt.from(10000) ~/ base)}%';

List<ReportOperation> uniqueReportGroups(
  Iterable<List<ReportOperation>> groups,
) => {
  for (final rows in groups)
    for (final o in rows) o.key: o,
}.values.toList();
