import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'category.dart';
import 'catalog_marks.dart';
import 'expense.dart';
import 'finance_repository.dart';
import 'money.dart';
import 'report_model.dart';
import 'report_export.dart';
import 'report_download.dart';

import 'package:supabase_flutter/supabase_flutter.dart';

const reportColors = [
  Color(0xff2563eb),
  Color(0xff16a34a),
  Color(0xffea580c),
  Color(0xff9333ea),
  Color(0xff0891b2),
  Color(0xffe11d48),
  Color(0xffca8a04),
  Color(0xff64748b),
];
Color reportColor(String key) {
  var hash = 0;
  for (final c in key.codeUnits) {
    hash = (hash * 31 + c) & 0x7fffffff;
  }
  return reportColors[hash % reportColors.length];
}

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({
    required this.repository,
    required this.spaces,
    required this.userId,
    super.key,
  });
  final FinanceRepository repository;
  final List<FinanceSpace> spaces;
  final String userId;
  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  ReportParams? _params;
  ReportData? _data;
  DateTime _now = DateTime.now();
  String _chartCurrency = '';
  String? _openedTemplate;
  String? _templateRevision;
  bool _hasServerTemplates = true;
  bool _loading = false;
  String? _error, _templateError;
  int _request = 0;
  List<Map<String, dynamic>> _templates = [];
  String get _storageKey => 'report_templates_v1:${widget.userId}';
  bool get _hasIncome =>
      widget.spaces.any((s) => s.ownerUserId == widget.userId);
  @override
  void initState() {
    super.initState();
    _readTemplates();
  }

  @override
  void dispose() {
    _request++;
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ReportsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.spaces.map((s) => s.id).join() !=
        widget.spaces.map((s) => s.id).join()) {
      if (_params != null) {
        _params!.walletIds = [];
        _params!.categoryIds = [];
        _load();
      }
    }
  }

  Future<void> _readTemplates() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);
      final rows = raw == null
          ? <Map<String, dynamic>>[]
          : (jsonDecode(raw) as List)
                .map((v) => Map<String, dynamic>.from(v))
                .toList();
      if (_hasIncome && widget.repository is SupabaseFinanceRepository) {
        final client = (widget.repository as SupabaseFinanceRepository).client;
        try {
          final saved = await client
              .from('finance_settings')
              .select('report_templates,revision')
              .eq('owner_id', widget.userId)
              .maybeSingle();
          _hasServerTemplates = true;
          if (saved == null && rows.isNotEmpty) {
            final created = await client.rpc(
              'backup_save_templates',
              params: {
                'p_request': newExpenseRequestId(),
                'p_expected': null,
                'p_templates': rows,
              },
            ) as Map;
            _templateRevision = created['revision'] as String;
          } else if (saved != null) {
            _templateRevision = saved['revision'] as String;
            rows.clear();
            rows.addAll(
              (saved['report_templates'] as List).map(
                (e) => Map<String, dynamic>.from(e as Map),
              ),
            );
          }
        } on PostgrestException catch (error) {
          if (!['42P01', 'PGRST205', '42703'].contains(error.code)) rethrow;
          _hasServerTemplates = false;
        }
      }
      for (final row in rows) {
        ReportParams.fromJson(Map<String, dynamic>.from(row['params']));
      }
      if (mounted) setState(() => _templates = rows);
    } catch (_) {
      if (mounted) {
        setState(
          () => _templateError =
              'Не удалось прочитать шаблоны на этом устройстве.',
        );
      }
    }
  }

  Future<void> _writeTemplates(List<Map<String, dynamic>> rows) async {
    try {
      var serverSaved = false;
      if (_hasIncome &&
          _hasServerTemplates &&
          widget.repository is SupabaseFinanceRepository) {
        final client = (widget.repository as SupabaseFinanceRepository).client;
        try {
          final saved = await client.rpc(
            'backup_save_templates',
            params: {
              'p_request': newExpenseRequestId(),
              'p_expected': _templateRevision,
              'p_templates': rows,
            },
          ) as Map;
          _templateRevision = saved['revision'] as String;
          serverSaved = true;
        } on PostgrestException catch (error) {
          if (!['42P01', 'PGRST205', '42703'].contains(error.code)) rethrow;
        }
      }
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(_storageKey, jsonEncode(rows)) &&
          !serverSaved) {
        throw StateError('Storage');
      }
      if (mounted) {
        setState(() {
          _templates = rows;
          _templateError = null;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _templateError =
              error is PostgrestException && error.code == 'P1003'
              ? 'Шаблоны изменились в другом окне или были восстановлены. Откройте раздел заново.'
              : 'Не удалось сохранить шаблоны. Проверьте подключение и хранилище браузера.',
        );
      }
    }
  }

  Future<void> _open(ReportParams p, {String? templateName}) async {
    setState(() {
      _params = p.copy();
      _openedTemplate = templateName;
      _chartCurrency = p.chartCurrency.isEmpty ? p.currency : p.chartCurrency;
      _now = DateTime.now();
    });
    await _load();
  }

  Future<void> _load() async {
    if (_params == null) return;
    final request = ++_request;
    final p = _params!.copy();
    setState(() {
      _loading = true;
      _error = null;
      _data = null;
    });
    try {
      var range = p.range(_now);
      if (p.kind.comparison) {
        final b = p.comparisonRange(_now);
        range = ReportRange(
          range.from.compareTo(b.from) < 0 ? range.from : b.from,
          range.to.compareTo(b.to) > 0 ? range.to : b.to,
        );
      }
      final data = await loadReportData(
        widget.repository,
        widget.spaces,
        widget.userId,
        range,
      );
      if (mounted && request == _request) setState(() => _data = data);
    } catch (e) {
      if (mounted && request == _request) {
        setState(
          () => _error = e is FormatException ? e.message : financeError(e),
        );
      }
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  Future<String?> _name(String title, [String initial = '']) async {
    var name = initial;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextFormField(
          initialValue: initial,
          onChanged: (v) => name = v,
          autofocus: true,
          maxLength: 100,
          decoration: const InputDecoration(labelText: 'Название'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () {
              if (name.trim().isNotEmpty) {
                Navigator.pop(context, name.trim());
              }
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    return result;
  }

  Future<void> _save() async {
    final name = await _name('Сохранить шаблон отчёта');
    if (name == null || !mounted) return;
    await _writeTemplates([
      ..._templates,
      {'id': newExpenseRequestId(), 'name': name, 'params': _params!.toJson()},
    ]);
    if (mounted && _templateError == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Шаблон сохранён в каталоге')),
      );
    }
  }

  void _catalog() {
    setState(() {
      _request++;
      _params = null;
      _data = null;
      _loading = false;
      _error = null;
    });
  }

  Widget _catalogTile(
    String title,
    VoidCallback onTap, {
    bool primary = false,
    Widget? trailing,
  }) => Card(
    color: primary ? Theme.of(context).colorScheme.primaryContainer : null,
    child: ListTile(
      leading: Icon(
        primary ? Icons.business_center_outlined : Icons.analytics_outlined,
      ),
      title: Text(title),
      subtitle: primary
          ? const Text('С начала текущего месяца • все бизнес-кошельки')
          : null,
      trailing: trailing ?? const Icon(Icons.chevron_right),
      onTap: onTap,
    ),
  );
  @override
  Widget build(BuildContext context) {
    final p = _params;
    if (p == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Быстрые отчёты',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          for (final kind in ReportKind.values.take(3))
            if (_hasIncome || kind != ReportKind.businessIncomes)
              _catalogTile(
                kind.label,
                () => _open(ReportParams.preset(kind)),
                primary: kind == ReportKind.businessExpenses,
              ),
          const SizedBox(height: 20),
          for (final section in [
            (
              'Категории и структура',
              [
                ReportKind.incomeCategories,
                ReportKind.expenseCategories,
                ReportKind.incomeStructure,
                ReportKind.expenseStructure,
              ],
            ),
            (
              'Сравнение и динамика',
              [
                ReportKind.incomeComparison,
                ReportKind.expenseComparison,
                ReportKind.cashResult,
                ReportKind.incomeMonths,
                ReportKind.expenseMonths,
                ReportKind.dailyFlow,
              ],
            ),
            ('Конструктор', [ReportKind.custom]),
          ]) ...[
            Text(
              section.$1,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            for (final kind in section.$2)
              if (_hasIncome ||
                  ReportParams.preset(kind).metric == ReportMetric.expense ||
                  kind == ReportKind.custom)
                _catalogTile(kind.label, () {
                  final p = ReportParams.preset(kind);
                  if (!_hasIncome) p.metric = ReportMetric.expense;
                  _open(p);
                }),
            const SizedBox(height: 16),
          ],
          const Text(
            'Сохранённые шаблоны',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const Text(
            'Настройки сохраняются для вашей учётной записи в этом браузере. Относительные даты пересчитываются при открытии.',
          ),
          if (_templateError != null)
            Text(_templateError!, style: const TextStyle(color: Colors.red)),
          if (_templates.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Пока нет сохранённых шаблонов'),
            ),
          for (final t in _templates)
            _catalogTile(
              t['name'],
              () => _open(
                ReportParams.fromJson(Map<String, dynamic>.from(t['params'])),
                templateName: t['name'],
              ),
              trailing: PopupMenuButton<String>(
                onSelected: (action) async {
                  if (action == 'delete') {
                    await _writeTemplates(
                      _templates.where((x) => x['id'] != t['id']).toList(),
                    );
                  } else {
                    final name = await _name('Переименовать шаблон', t['name']);
                    if (name != null) {
                      await _writeTemplates([
                        for (final x in _templates)
                          x['id'] == t['id'] ? {...x, 'name': name} : x,
                      ]);
                    }
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'rename', child: Text('Переименовать')),
                  PopupMenuItem(value: 'delete', child: Text('Удалить шаблон')),
                ],
              ),
            ),
        ],
      );
    }
    final data = _data;
    final rows = data?.select(p, p.range(_now)) ?? <ReportOperation>[];
    final bRows = data != null && p.kind.comparison
        ? data.select(p, p.comparisonRange(_now))
        : <ReportOperation>[];
    final totals = reportTotals(rows), bTotals = reportTotals(bRows);
    final currencies = {
      ...totals.map((t) => t.currency),
      ...bTotals.map((t) => t.currency),
    }.toList()..sort();
    final currency = currencies.contains(_chartCurrency)
        ? _chartCurrency
        : currencies.firstOrNull ?? p.currency;
    if (data != null) p.chartCurrency = currency;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _catalog,
            icon: const Icon(Icons.arrow_back),
            label: const Text('Каталог отчётов'),
          ),
        ),
        Text(
          _openedTemplate == null ? p.title : '$_openedTemplate • ${p.title}',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _choice<String>(
              'Пространство',
              p.scope,
              const {'all': 'Всё', 'personal': 'Личное', 'business': 'Бизнес'},
              (v) => setState(() {
                p.scope = v;
                p.walletIds = [];
                p.categoryIds = [];
              }),
            ),
            _choice<ReportPeriod>(
              'Период',
              p.period,
              {
                for (final v in ReportPeriod.values)
                  if (!p.kind.comparison || v != ReportPeriod.all) v: v.label,
              },
              (v) async {
                if (v == ReportPeriod.custom) {
                  final range = await _pickRange(p.range(_now));
                  if (range == null) return;
                  p.from = range.from;
                  p.to = range.to;
                }
                setState(() => p.period = v);
                await _load();
              },
            ),
            OutlinedButton.icon(
              onPressed: data == null ? null : () => _filters(p),
              icon: const Icon(Icons.filter_alt_outlined),
              label: Text('Фильтры (${p.filterCount})'),
            ),
            TextButton(
              onPressed: () => _open(ReportParams.preset(p.kind)),
              child: const Text('Сбросить'),
            ),
            IconButton(
              tooltip: 'Обновить данные',
              onPressed: _load,
              icon: const Icon(Icons.refresh),
            ),
            OutlinedButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.bookmark_add_outlined),
              label: const Text('Сохранить шаблон'),
            ),
            PopupMenuButton<String>(
              enabled: data != null,
              tooltip: 'Экспорт',
              onSelected: _export,
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'xlsx', child: Text('XLSX')),
                PopupMenuItem(value: 'csv', child: Text('CSV')),
              ],
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.download),
                    SizedBox(width: 8),
                    Text('Экспорт'),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text('Период A: ${p.range(_now).label} • ${p.range(_now).days} дн.'),
        const Text('Валюты считаются раздельно • без конвертации'),
        if (p.filterCount > 0)
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              if (p.currency.isNotEmpty)
                Chip(label: Text('Валюта: ${p.currency}')),
              if (p.search.isNotEmpty) Chip(label: Text('Поиск: ${p.search}')),
              for (final id in p.walletIds)
                Chip(label: Text('Кошелёк: ${data?.wallet(id)?.name ?? id}')),
              for (final id in p.categoryIds)
                Chip(
                  label: Text(
                    'Категория: ${data?.category(id)?.name ?? id} + подкатегории',
                  ),
                ),
            ],
          ),
        if (!_hasIncome)
          const Text(
            'Доступны только ваши расходы в назначенных кошельках. Доходы доступны владельцу.',
          ),
        if (p.range(_now).to == expenseDate(_now))
          const Text(
            'Текущий период неполный, по сегодняшний день включительно',
          ),
        if (_templateError != null)
          Text(_templateError!, style: const TextStyle(color: Colors.red)),
        if (p.kind.comparison) ...[
          const SizedBox(height: 8),
          Text(
            'Период B: ${p.comparisonRange(_now).label} • ${p.comparisonRange(_now).days} дн.',
          ),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: () {
                  setState(() {
                    p.bFrom = p.bTo = null;
                    p.fullPreviousMonth = false;
                  });
                  _load();
                },
                child: const Text('Сопоставимый отрезок'),
              ),
              TextButton(
                onPressed: () {
                  setState(() {
                    p.bFrom = p.bTo = null;
                    p.fullPreviousMonth = true;
                  });
                  _load();
                },
                child: const Text('Полный предыдущий месяц'),
              ),
              TextButton(
                onPressed: () async {
                  final r = await _pickRange(p.comparisonRange(_now));
                  if (r != null) {
                    setState(() {
                      p.bFrom = r.from;
                      p.bTo = r.to;
                    });
                    _load();
                  }
                },
                child: const Text('Выбрать период B'),
              ),
              FilterChip(
                label: const Text('Нарастающим итогом'),
                selected: p.cumulative,
                onSelected: (v) => setState(() => p.cumulative = v),
              ),
            ],
          ),
        ],
        const SizedBox(height: 16),
        if (_loading)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(),
            ),
          ),
        if (_error != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Text(_error!),
                  TextButton(
                    onPressed: _load,
                    child: const Text('Повторить попытку'),
                  ),
                ],
              ),
            ),
          ),
        if (data != null) ...[
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              for (final t in totals)
                ActionChip(
                  label: Text(
                    '${p.metric.label}: ${t.format(p.metric)} • ${t.count} оп.',
                  ),
                  onPressed: () => _detail(
                    rows.where((o) => o.entry.currency == t.currency).toList(),
                    '${p.metric.label} • ${t.currency}',
                    p.metric,
                  ),
                ),
              if (p.metric == ReportMetric.net)
                for (final t in totals)
                  Text(
                    'Доходы ${t.format(ReportMetric.income)} · Расходы ${t.format(ReportMetric.expense)}',
                  ),
            ],
          ),
          if (currencies.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: _choice<String>(
                'Валюта диаграммы и долей',
                currency,
                {for (final c in currencies) c: c},
                (v) => setState(() {
                  _chartCurrency = v;
                  p.chartCurrency = v;
                }),
              ),
            ),
          if (rows.isNotEmpty && p.metric != ReportMetric.net)
            Builder(
              builder: (context) {
                final ranked = reportBuckets(
                  data,
                  rows,
                  p.copy()..sort = 'amount',
                  currency,
                  grouping: ReportGrouping.category,
                );
                final largest = ranked.firstOrNull;
                return largest == null
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Text(
                          'Крупнейшая статья ($currency): ${largest.label} • ${largest.total.format(p.metric)}',
                        ),
                      );
              },
            ),
          if (p.kind == ReportKind.custom) _constructor(p),
          if (rows.isEmpty && bRows.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('Нет операций за выбранный период и условия'),
              ),
            ),
          if (p.kind.comparison && currencies.isNotEmpty)
            _comparison(data, rows, bRows, currency),
          if (!p.kind.comparison && rows.isNotEmpty) ...[
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                _choice<ReportGrouping>('Группировка', p.grouping, {
                  for (final v in ReportGrouping.values) v: v.label,
                }, (v) => setState(() => p.grouping = v)),
                _choice<String>('Сортировка', p.sort, const {
                  'amount': 'По сумме ↓',
                  'name': 'По названию',
                  'count': 'По количеству ↓',
                }, (v) => setState(() => p.sort = v)),
              ],
            ),
            const SizedBox(height: 12),
            _result(data, rows, currency),
          ],
          if (p.kind == ReportKind.custom && p.groups.isNotEmpty)
            _customGroups(data),
        ],
      ],
    );
  }

  Widget _choice<T>(
    String label,
    T value,
    Map<T, String> options,
    ValueChanged<T> change,
  ) => SizedBox(
    width: 245,
    child: DropdownButtonFormField<T>(
      key: ValueKey('$label:$value'),
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: options.entries
          .map(
            (v) => DropdownMenuItem(
              value: v.key,
              child: Text(v.value, overflow: TextOverflow.ellipsis),
            ),
          )
          .toList(),
      onChanged: (v) {
        if (v != null) change(v);
      },
    ),
  );
  Future<ReportRange?> _pickRange(ReportRange initial) async {
    final result = await showDateRangePicker(
      context: context,
      firstDate: DateTime(1),
      lastDate: DateTime.now(),
      initialDateRange: DateTimeRange(
        start: parseExpenseDate(initial.from),
        end: parseExpenseDate(initial.to),
      ),
      locale: const Locale('ru'),
    );
    return result == null
        ? null
        : ReportRange(expenseDate(result.start), expenseDate(result.end));
  }

  Future<bool> _filters(ReportParams target, {bool group = false}) async {
    final draft = target.copy();
    final data = _data!;
    var searchEpoch = 0;
    final applied = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) {
          final spaceIds = data.spaces
              .where((s) => draft.scope == 'all' || s.kind == draft.scope)
              .map((s) => s.id)
              .toSet();
          return AlertDialog(
            title: Text(group ? 'Фильтры группы' : 'Фильтры отчёта'),
            content: SizedBox(
              width: 560,
              height: 450,
              child: ListView(
                children: [
                  if (group)
                    _choice<String>(
                      'Пространство группы',
                      draft.scope,
                      const {
                        'all': 'Всё',
                        'personal': 'Личное',
                        'business': 'Бизнес',
                      },
                      (v) => update(() {
                        draft.scope = v;
                        draft.walletIds = [];
                        draft.categoryIds = [];
                      }),
                    ),
                  const SizedBox(height: 12),
                  TextFormField(
                    key: ValueKey(searchEpoch),
                    initialValue: draft.search,
                    onChanged: (v) => draft.search = v,
                    decoration: const InputDecoration(
                      labelText: 'Поиск по комментарию, кошельку, категории',
                    ),
                  ),
                  const SizedBox(height: 12),
                  _choice<String>('Валюта', draft.currency, {
                    '': 'Все валюты раздельно',
                    for (final c in data.wallets.map((w) => w.currency).toSet())
                      c: c,
                  }, (v) => update(() => draft.currency = v)),
                  if (target.kind == ReportKind.custom ||
                      group ||
                      target.kind == ReportKind.cashResult ||
                      target.kind == ReportKind.dailyFlow) ...[
                    const SizedBox(height: 12),
                    _choice<ReportMetric>('Тип / показатель', draft.metric, {
                      for (final v in ReportMetric.values)
                        if (_hasIncome || v == ReportMetric.expense) v: v.label,
                    }, (v) => update(() => draft.metric = v)),
                  ],
                  const SizedBox(height: 16),
                  const Text('Кошельки • без выбора — все, включая архив'),
                  for (final w in data.wallets.where(
                    (w) => spaceIds.contains(w.spaceId),
                  ))
                    CheckboxListTile(
                      dense: true,
                      secondary: WalletMark(w.displayIconId, size: 32),
                      title: Text(
                        '${w.name} · ${w.currency}${w.isArchived ? ' (архив)' : ''}',
                      ),
                      value: draft.walletIds.contains(w.id),
                      onChanged: (v) => update(
                        () => draft.walletIds = v!
                            ? [...draft.walletIds, w.id]
                            : draft.walletIds
                                  .where((id) => id != w.id)
                                  .toList(),
                      ),
                    ),
                  const Text('Категории • выбор включает всех потомков'),
                  for (final c in data.categories.where(
                    (c) =>
                        spaceIds.contains(c.spaceId) &&
                        (draft.metric == ReportMetric.net ||
                            c.kind.name == draft.metric.name),
                  ))
                    CheckboxListTile(
                      dense: true,
                      secondary: CategoryMark(c.iconId, size: 32),
                      title: Text(
                        '${c.kind.label}: ${_categoryPath(c)}${c.isArchived ? ' (архив)' : ''}',
                      ),
                      value: draft.categoryIds.contains(c.id),
                      onChanged: (v) => update(
                        () => draft.categoryIds = v!
                            ? [...draft.categoryIds, c.id]
                            : draft.categoryIds
                                  .where((id) => id != c.id)
                                  .toList(),
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Отмена'),
              ),
              TextButton(
                onPressed: () => update(() {
                  draft.walletIds = [];
                  draft.categoryIds = [];
                  draft.currency = '';
                  draft.search = '';
                  searchEpoch++;
                }),
                child: const Text('Сбросить'),
              ),
              FilledButton(
                onPressed: () {
                  draft.search = draft.search.trim();
                  Navigator.pop(context, true);
                },
                child: const Text('Применить'),
              ),
            ],
          );
        },
      ),
    );
    if (applied == true && mounted) {
      setState(() {
        target.scope = draft.scope;
        target.walletIds = draft.walletIds;
        target.categoryIds = draft.categoryIds;
        target.currency = draft.currency;
        target.search = draft.search;
        target.metric = draft.metric;
      });
    }
    return applied == true;
  }

  String _categoryPath(FinanceCategory c) {
    final names = [c.name], seen = {c.id};
    var parent = _data!.category(c.parentId ?? '');
    while (parent != null && seen.add(parent.id)) {
      names.insert(0, parent.name);
      parent = _data!.category(parent.parentId ?? '');
    }
    return names.join(' / ');
  }

  Widget _constructor(ReportParams p) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        _choice<ReportMetric>('Показатель', p.metric, {
          for (final v in ReportMetric.values)
            if (_hasIncome || v == ReportMetric.expense) v: v.label,
        }, (v) => setState(() => p.metric = v)),
        _choice<ReportView>('Представление', p.view, {
          for (final v in ReportView.values) v: v.label,
        }, (v) => setState(() => p.view = v)),
        OutlinedButton.icon(
          onPressed: () async {
            final name = await _name('Добавить группу сравнения');
            if (name == null || !mounted) return;
            final config = p.copy()..groups = [];
            if (!await _filters(config, group: true)) return;
            if (mounted) {
              setState(
                () => p.groups = [...p.groups, NamedReportGroup(name, config)],
              );
            }
          },
          icon: const Icon(Icons.add),
          label: const Text('Добавить группу'),
        ),
      ],
    ),
  );
  Widget _result(ReportData data, List<ReportOperation> rows, String currency) {
    final p = _params!, range = p.range(_now);
    final buckets = reportBuckets(data, rows, p, currency, range: range);
    final chart = _chart(
      buckets,
      p.metric,
      p.view,
      currency,
      (bucket) => _bucketDetail(bucket),
      paired: p.metric == ReportMetric.net,
    );
    final table = _bucketTable(buckets, rows, currency);
    return LayoutBuilder(
      builder: (context, box) =>
          box.maxWidth >= 800 && p.view != ReportView.table
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: chart),
                const SizedBox(width: 16),
                Expanded(child: table),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [if (p.view != ReportView.table) chart, table],
            ),
    );
  }

  Widget _bucketTable(
    List<ReportBucket> buckets,
    List<ReportOperation> rows,
    String currency,
  ) {
    final p = _params!;
    final total = reportTotals(rows.where((o) => o.entry.currency == currency))
        .firstOrNull;
    final base = total?.value(p.metric) ?? BigInt.zero;
    return Card(
      child: Column(
        children: [
          ListTile(
            title: Text('${p.grouping.label} • $currency'),
            subtitle: Text('${buckets.length} групп • нажмите для детализации'),
          ),
          for (final bucket in buckets)
            InkWell(
              onTap: () => _bucketDetail(bucket),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      spacing: 12,
                      runSpacing: 6,
                      children: [
                        Text(
                          '${bucket.label}${p.grouping == ReportGrouping.month && bucket.key.substring(0, 7) == expenseDate(_now).substring(0, 7) ? ' (неполный)' : ''}',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          bucket.total.format(p.metric),
                          textAlign: TextAlign.right,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                    Text(
                      '${bucket.rows.length} операций${p.metric != ReportMetric.net && base > BigInt.zero ? ' • ${reportShare(bucket.total.value(p.metric), base)}' : ''}',
                    ),
                    if (p.metric == ReportMetric.net)
                      Text(
                        'Доходы: ${bucket.total.format(ReportMetric.income)}\nРасходы: ${bucket.total.format(ReportMetric.expense)}\nРазница: ${bucket.total.format(ReportMetric.net)}',
                      ),
                    if (p.metric != ReportMetric.net)
                      LinearProgressIndicator(
                        value: reportRatio(bucket.total.value(p.metric), base),
                        color: reportColor(bucket.key),
                        backgroundColor: Colors.black.withValues(alpha: .04),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _bucketDetail(ReportBucket bucket) {
    if (_params!.grouping == ReportGrouping.month) {
      _monthDetail(bucket);
    } else {
      _detail(bucket.rows, bucket.label, _params!.metric);
    }
  }

  Future<void> _monthDetail(ReportBucket bucket) async {
    final p = _params!.copy()..grouping = ReportGrouping.day;
    final start = parseExpenseDate(bucket.key);
    final monthEnd = expenseDate(DateTime.utc(start.year, start.month + 1, 0));
    final end = monthEnd.compareTo(p.range(_now).to) > 0
        ? p.range(_now).to
        : monthEnd;
    final from = bucket.key.compareTo(p.range(_now).from) < 0
        ? p.range(_now).from
        : bucket.key;
    final days = reportBuckets(
      _data!,
      bucket.rows,
      p,
      bucket.total.currency,
      range: ReportRange(from, end),
    );
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => Scaffold(
          appBar: AppBar(title: Text('Месяц ${bucket.label}')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'Итог месяца: ${bucket.total.format(p.metric)}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              _chart(
                days,
                p.metric,
                ReportView.bars,
                bucket.total.currency,
                (b) => _detail(b.rows, 'День ${b.label}', p.metric),
              ),
              for (final day in days)
                ListTile(
                  title: Text(day.label),
                  subtitle: Text('${day.rows.length} операций'),
                  trailing: Text(day.total.format(p.metric)),
                  onTap: () => _detail(day.rows, 'День ${day.label}', p.metric),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _detail(
    List<ReportOperation> rows,
    String title,
    ReportMetric metric,
  ) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ReportDetailScreen(
          data: _data!,
          rows: rows,
          title: title,
          metric: metric,
        ),
      ),
    );
  }

  Widget _comparison(
    ReportData data,
    List<ReportOperation> rows,
    List<ReportOperation> bRows,
    String currency,
  ) {
    final p = _params!, a = p.range(_now), b = p.comparisonRange(_now);
    final at = reportTotals(rows.where((o) => o.entry.currency == currency))
        .firstOrNull;
    final bt = reportTotals(bRows.where((o) => o.entry.currency == currency))
        .firstOrNull;
    final scale = math.max(at?.scale ?? 0, bt?.scale ?? 0);
    final av =
        (at?.value(p.metric) ?? BigInt.zero) *
        BigInt.from(10).pow(scale - (at?.scale ?? scale));
    final bv =
        (bt?.value(p.metric) ?? BigInt.zero) *
        BigInt.from(10).pow(scale - (bt?.scale ?? scale));
    String amount(BigInt v) => '${formatExactMoney(v, scale: scale)} $currency';
    final ac = reportBuckets(
      data,
      rows,
      p,
      currency,
      grouping: ReportGrouping.category,
    );
    final bc = reportBuckets(
      data,
      bRows,
      p,
      currency,
      grouping: ReportGrouping.category,
    );
    final dayA = reportBuckets(
      data,
      rows,
      p,
      currency,
      grouping: ReportGrouping.day,
      range: a,
    );
    final dayB = reportBuckets(
      data,
      bRows,
      p,
      currency,
      grouping: ReportGrouping.day,
      range: b,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            ActionChip(
              label: Text('A: ${amount(av)} • ${at?.count ?? 0} оп.'),
              onPressed: () => _detail(
                rows.where((o) => o.entry.currency == currency).toList(),
                'Период A: ${a.label}',
                p.metric,
              ),
            ),
            ActionChip(
              label: Text('B: ${amount(bv)} • ${bt?.count ?? 0} оп.'),
              onPressed: () => _detail(
                bRows.where((o) => o.entry.currency == currency).toList(),
                'Период B: ${b.label}',
                p.metric,
              ),
            ),
            Text('Разница A − B: ${amount(av - bv)} • ${reportChange(av, bv)}'),
          ],
        ),
        if (a.days != b.days)
          Text(
            'Периоды разной длительности: A ${a.days} дн., B ${b.days} дн.\nСредняя сумма в день: A ${amount(av ~/ BigInt.from(a.days))}, B ${amount(bv ~/ BigInt.from(b.days))}',
          ),
        _comparisonChart(dayA, dayB, currency),
        const Text(
          'Изменение по категориям • суммы открывают операции своего периода',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        for (final key in {...ac.map((x) => x.key), ...bc.map((x) => x.key)})
          Builder(
            builder: (context) {
              final x = ac.where((x) => x.key == key).firstOrNull,
                  y = bc.where((x) => x.key == key).firstOrNull;
              final xa =
                  (x?.total.value(p.metric) ?? BigInt.zero) *
                  BigInt.from(10).pow(scale - (x?.total.scale ?? scale));
              final ya =
                  (y?.total.value(p.metric) ?? BigInt.zero) *
                  BigInt.from(10).pow(scale - (y?.total.scale ?? scale));
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(x?.label ?? y!.label),
                      Wrap(
                        spacing: 12,
                        children: [
                          TextButton(
                            onPressed: () => _detail(
                              x?.rows ?? [],
                              'A • ${x?.label ?? y!.label}',
                              p.metric,
                            ),
                            child: Text('A: ${amount(xa)}'),
                          ),
                          TextButton(
                            onPressed: () => _detail(
                              y?.rows ?? [],
                              'B • ${y?.label ?? x!.label}',
                              p.metric,
                            ),
                            child: Text('B: ${amount(ya)}'),
                          ),
                        ],
                      ),
                      Text(
                        'A − B: ${amount(xa - ya)} • ${reportChange(xa, ya)} • ${x?.rows.length ?? 0} / ${y?.rows.length ?? 0} операций',
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
      ],
    );
  }

  Widget _comparisonChart(
    List<ReportBucket> a,
    List<ReportBucket> b,
    String currency,
  ) {
    final p = _params!, size = math.max(a.length, b.length);
    if (size == 0) return const SizedBox.shrink();
    List<double> values(List<ReportBucket> buckets) {
      var sum = 0.0;
      return List.generate(size, (i) {
        final v = i < buckets.length
            ? buckets[i].total.value(p.metric).toDouble() /
                  math.pow(10, buckets[i].total.scale)
            : 0.0;
        sum += v;
        return p.cumulative ? sum : v;
      });
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text(
              '${p.cumulative ? 'Нарастающим итогом' : 'По дням'} • $currency • номер дня периода',
            ),
            _lineChart([values(a), values(b)], ['A', 'B'], currency, (
              series,
              index,
            ) {
              final list = series == 0 ? a : b;
              if (index < list.length) {
                _detail(
                  list[index].rows,
                  '${series == 0 ? 'A' : 'B'} • ${list[index].label}',
                  p.metric,
                );
              }
            }),
            const Text(
              'Нажмите на точку ряда A или B для операций соответствующего дня',
            ),
          ],
        ),
      ),
    );
  }

  Widget _customGroups(ReportData data) {
    final p = _params!, range = p.range(_now);
    final selections = [for (final g in p.groups) data.select(g.params, range)];
    final unique = uniqueReportGroups(selections);
    final overlap =
        selections.fold<int>(0, (v, r) => v + r.length) - unique.length;
    final currencies = reportTotals(unique).map((t) => t.currency).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 16),
        const Text(
          'Группы сравнения',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        Text(
          'Общий период: ${range.label}. Валюты раздельно. Группы неаддитивны; повторных вхождений: $overlap.',
        ),
        Wrap(
          spacing: 8,
          children: [
            for (final t in reportTotals(unique))
              ActionChip(
                label: Text(
                  'Уникальный итог: ${t.format(p.metric)} • ${t.count} оп.',
                ),
                onPressed: () => _detail(
                  unique.where((o) => o.entry.currency == t.currency).toList(),
                  'Уникальные операции групп',
                  p.metric,
                ),
              ),
          ],
        ),
        for (var i = 0; i < p.groups.length; i++)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Icon(
                        Icons.circle,
                        color: reportColors[i % reportColors.length],
                        size: 14,
                      ),
                      Text(
                        '${p.groups[i].name} • ${p.groups[i].params.scopeLabel} • ${p.groups[i].params.metric.label}',
                      ),
                      IconButton(
                        tooltip: 'Фильтры группы',
                        onPressed: () =>
                            _filters(p.groups[i].params, group: true),
                        icon: const Icon(Icons.filter_alt),
                      ),
                      IconButton(
                        tooltip: 'Переименовать группу',
                        onPressed: () async {
                          final name = await _name(
                            'Название группы',
                            p.groups[i].name,
                          );
                          if (name != null && mounted) {
                            setState(() => p.groups[i].name = name);
                          }
                        },
                        icon: const Icon(Icons.edit_outlined),
                      ),
                      IconButton(
                        tooltip: 'Удалить группу',
                        onPressed: () => setState(
                          () => p.groups = [...p.groups]..removeAt(i),
                        ),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  for (final c in currencies) ...[
                    for (final t in reportTotals(
                      selections[i].where((o) => o.entry.currency == c),
                    ))
                      Text(t.format(p.groups[i].params.metric)),
                    _chart(
                      reportBuckets(data, selections[i], p, c, range: range),
                      p.groups[i].params.metric,
                      p.view,
                      c,
                      (bucket) => _detail(
                        bucket.rows,
                        '${p.groups[i].name} • ${bucket.label}',
                        p.groups[i].params.metric,
                      ),
                      color: reportColors[i % reportColors.length],
                    ),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }

  void _export(String format) {
    try {
      final export = ReportExport(
        data: _data!,
        params: _params!.copy(),
        now: _now,
        formedAt: DateTime.now(),
      );
      final bytes = format == 'xlsx' ? export.xlsx() : export.csv();
      downloadReport(
        bytes,
        'report_${_params!.kind.name}_${expenseDate(_now)}.$format',
        format == 'xlsx'
            ? 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
            : 'text/csv;charset=utf-8',
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Экспорт $format: ${export.operations.length} операций',
          ),
        ),
      );
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Не удалось выгрузить отчёт. Повторите попытку в Web-версии.',
          ),
        ),
      );
    }
  }

  Widget _chart(
    List<ReportBucket> buckets,
    ReportMetric metric,
    ReportView view,
    String currency,
    ValueChanged<ReportBucket> tap, {
    bool paired = false,
    Color? color,
  }) {
    if (view == ReportView.table || buckets.isEmpty) {
      return const SizedBox.shrink();
    }
    if (view == ReportView.ring) {
      final sorted = [
        ...buckets,
      ]..sort((a, b) => b.total.value(metric).compareTo(a.total.value(metric)));
      final total = sorted.fold<BigInt>(
        BigInt.zero,
        (s, b) => s + b.total.value(metric),
      );
      if (total <= BigInt.zero ||
          sorted.any((b) => b.total.value(metric).isNegative)) {
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                const Text(
                  'Кольцо недоступно при неположительной базе или отрицательных значениях. Показаны столбцы.',
                ),
                _chart(
                  buckets,
                  metric,
                  ReportView.bars,
                  currency,
                  tap,
                  color: color,
                ),
              ],
            ),
          ),
        );
      }
      final sectors = sorted.take(7).toList();
      if (sorted.length > 7) {
        final rest = sorted.skip(7).expand((b) => b.rows).toList();
        final others = sorted.skip(7);
        sectors.add(
          ReportBucket(
            'other',
            'Остальное',
            rest,
            ReportAmount(
              currency,
              sorted.first.total.scale,
              others.fold(BigInt.zero, (s, b) => s + b.total.income),
              others.fold(BigInt.zero, (s, b) => s + b.total.expense),
              rest.length,
            ),
          ),
        );
      }
      void sectorTap(ReportBucket sector) {
        if (sector.key != 'other') {
          tap(sector);
          return;
        }
        showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Остальное — входящие группы'),
            content: SizedBox(
              width: 460,
              height: 360,
              child: ListView(
                children: [
                  for (final bucket in sorted.skip(7))
                    ListTile(
                      title: Text(bucket.label),
                      subtitle: Text(bucket.total.format(metric)),
                      leading: Icon(
                        Icons.circle,
                        size: 14,
                        color: reportColor(bucket.key),
                      ),
                      onTap: () {
                        Navigator.pop(context);
                        tap(bucket);
                      },
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Закрыть'),
              ),
            ],
          ),
        );
      }

      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Text('${metric.label} • $currency'),
              SizedBox(
                height: 240,
                width: 240,
                child: GestureDetector(
                  onTapUp: (event) {
                    final point = event.localPosition - const Offset(120, 120);
                    if (point.distance < 65 || point.distance > 115) return;
                    var angle =
                            (math.atan2(point.dy, point.dx) + math.pi / 2) %
                            (2 * math.pi),
                        cumulative = 0.0;
                    for (final sector in sectors) {
                      cumulative +=
                          reportRatio(sector.total.value(metric), total) *
                          2 *
                          math.pi;
                      if (angle <= cumulative) {
                        sectorTap(sector);
                        break;
                      }
                    }
                  },
                  child: CustomPaint(
                    painter: _RingPainter(sectors, metric, total),
                  ),
                ),
              ),
              for (final s in sectors)
                ListTile(
                  dense: true,
                  leading: Icon(
                    Icons.circle,
                    size: 12,
                    color: reportColor(s.key),
                  ),
                  title: Text(s.label),
                  subtitle: Text(
                    '${s.total.format(metric)} • ${(reportRatio(s.total.value(metric), total) * 100).toStringAsFixed(2)}%',
                  ),
                  onTap: () => sectorTap(s),
                ),
            ],
          ),
        ),
      );
    }
    if (view == ReportView.line) {
      final values = [
        for (final b in buckets)
          b.total.value(metric).toDouble() / math.pow(10, b.total.scale),
      ];
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Text('${metric.label} • $currency'),
              _lineChart(
                [values],
                [metric.label],
                currency,
                (_, index) => tap(buckets[index]),
                labels: buckets.map((b) => b.label).toList(),
              ),
            ],
          ),
        ),
      );
    }
    final maxValue = buckets.fold<double>(
      0,
      (v, b) => math.max(
        v,
        paired
            ? math.max(
                b.total.income.toDouble() / math.pow(10, b.total.scale),
                b.total.expense.toDouble() / math.pow(10, b.total.scale),
              )
            : b.total.value(metric).abs().toDouble() /
                  math.pow(10, b.total.scale),
      ),
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('${paired ? 'Доходы / Расходы' : metric.label} • $currency'),
            if (paired)
              const Text('Зелёный: доходы • Красный: расходы • общая шкала'),
            if (!paired && buckets.any((b) => b.total.value(metric).isNegative))
              const Text(
                'Отрицательные значения показаны ниже нулевой линии; положительные — выше.',
              ),
            SizedBox(
              height: 230,
              child: Scrollbar(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (final b in buckets)
                        SizedBox(
                          width: 82,
                          child: InkWell(
                            onTap: () => tap(b),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                Tooltip(
                                  message:
                                      '${b.label}\n${b.total.format(metric)}',
                                  child: SizedBox(
                                    height: 170,
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.end,
                                      children: [
                                        for (final m
                                            in paired
                                                ? [
                                                    ReportMetric.income,
                                                    ReportMetric.expense,
                                                  ]
                                                : [metric])
                                          _bar(
                                            b,
                                            m,
                                            maxValue,
                                            paired,
                                            color,
                                            !paired &&
                                                buckets.any(
                                                  (b) => b.total
                                                      .value(metric)
                                                      .isNegative,
                                                ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                                SizedBox(
                                  height: 44,
                                  child: Padding(
                                    padding: const EdgeInsets.all(4),
                                    child: Text(
                                      b.label,
                                      textAlign: TextAlign.center,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 10),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            Text(
              'Шкала: 0 — ${maxValue.toStringAsFixed(2)} $currency. Нажмите столбец для операций.',
            ),
          ],
        ),
      ),
    );
  }

  Widget _bar(
    ReportBucket b,
    ReportMetric metric,
    double maximum,
    bool paired,
    Color? color,
    bool signed,
  ) {
    final value = b.total.value(metric);
    final height = maximum == 0
        ? 0.0
        : (value.abs().toDouble() /
                  math.pow(10, b.total.scale) /
                  maximum *
                  (signed ? 80 : 160))
              .clamp(0, signed ? 80 : 160)
              .toDouble();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: SizedBox(
        width: paired ? 24 : 40,
        height: 170,
        child: Stack(
          children: [
            if (signed)
              const Positioned(
                top: 85,
                left: 0,
                right: 0,
                child: Divider(height: 1),
              ),
            Positioned(
              left: 0,
              right: 0,
              top: signed
                  ? value.isNegative
                        ? 85
                        : 85 - height
                  : 170 - height,
              child: Container(
                height: height,
                decoration: BoxDecoration(
                  color: paired
                      ? metric == ReportMetric.income
                            ? Colors.green
                            : Colors.red
                      : color ?? reportColor(b.key),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _lineChart(
    List<List<double>> series,
    List<String> names,
    String currency,
    void Function(int, int) tap, {
    List<String>? labels,
  }) {
    final max = series
        .expand((s) => s)
        .fold<double>(0, (v, x) => math.max(v, x.abs()));
    final count = series.first.length;
    return Column(
      children: [
        SizedBox(
          height: 220,
          child: LayoutBuilder(
            builder: (context, box) => GestureDetector(
              onTapUp: (event) {
                final index =
                    ((event.localPosition.dx - 12) /
                            (box.maxWidth - 24) *
                            math.max(1, count - 1))
                        .round()
                        .clamp(0, count - 1);
                var nearest = 0, distance = double.infinity;
                for (var s = 0; s < series.length; s++) {
                  final y = 100 - (max == 0 ? 0 : series[s][index] / max * 85);
                  final d = (event.localPosition.dy - y).abs();
                  if (d < distance) {
                    distance = d;
                    nearest = s;
                  }
                }
                tap(nearest, index);
              },
              child: CustomPaint(
                size: Size(box.maxWidth, 220),
                painter: _LinePainter(series, max),
              ),
            ),
          ),
        ),
        Text(
          'Шкала: −${max.toStringAsFixed(2)} … ${max.toStringAsFixed(2)} $currency',
        ),
        Wrap(
          spacing: 16,
          children: [
            for (var s = 0; s < names.length; s++)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.show_chart, color: reportColors[s], size: 18),
                  Text(names[s]),
                ],
              ),
          ],
        ),
        Text(
          count == 0
              ? ''
              : labels == null
              ? 'Дни периода: 1 — $count'
              : '${labels.first} — ${labels.last}',
        ),
      ],
    );
  }
}

class ReportDetailScreen extends StatefulWidget {
  const ReportDetailScreen({
    required this.data,
    required this.rows,
    required this.title,
    required this.metric,
    super.key,
  });
  final ReportData data;
  final List<ReportOperation> rows;
  final String title;
  final ReportMetric metric;
  @override
  State<ReportDetailScreen> createState() => _ReportDetailScreenState();
}

class _ReportDetailScreenState extends State<ReportDetailScreen> {
  String _search = '', _sort = 'date';
  @override
  Widget build(BuildContext context) {
    final rows = widget.rows
        .where(
          (o) =>
              '${o.entry.comment} ${widget.data.walletName(o.entry)} ${widget.data.categoryName(o.entry)}'
                  .toLowerCase()
                  .contains(_search.toLowerCase()),
        )
        .toList();
    rows.sort(
      (a, b) => _sort == 'date'
          ? b.entry.date.compareTo(a.entry.date)
          : _sort == 'name'
          ? widget.data
                .categoryName(a.entry)
                .compareTo(widget.data.categoryName(b.entry))
          : a.entry.currency.compareTo(b.entry.currency) != 0
          ? a.entry.currency.compareTo(b.entry.currency)
          : (b.entry.amount * BigInt.from(10).pow(a.entry.scale)).compareTo(
              a.entry.amount * BigInt.from(10).pow(b.entry.scale),
            ),
    );
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    for (final t in reportTotals(widget.rows))
                      Text(
                        'Итог выбранного агрегата: ${t.format(widget.metric)} • ${t.count} оп.',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                  ],
                ),
                if (_search.isNotEmpty)
                  Wrap(
                    spacing: 12,
                    children: [
                      for (final t in reportTotals(rows))
                        Text(
                          'Результат поиска: ${t.format(widget.metric)} • ${t.count} оп.',
                        ),
                    ],
                  ),
                const SizedBox(height: 12),
                TextField(
                  decoration: const InputDecoration(
                    labelText: 'Поиск в операциях',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (v) => setState(() => _search = v),
                ),
                DropdownButton<String>(
                  isExpanded: true,
                  value: _sort,
                  items: const [
                    DropdownMenuItem(value: 'date', child: Text('По дате ↓')),
                    DropdownMenuItem(
                      value: 'amount',
                      child: Text('По сумме ↓ (внутри валюты)'),
                    ),
                    DropdownMenuItem(
                      value: 'name',
                      child: Text('По категории'),
                    ),
                  ],
                  onChanged: (v) => setState(() => _sort = v!),
                ),
              ],
            ),
          ),
          if (rows.isEmpty)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text('Нет операций'),
            ),
          Expanded(
            child: ListView.builder(
              key: const PageStorageKey('report-detail-rows'),
              itemCount: rows.length,
              itemBuilder: (context, index) {
                final o = rows[index],
                    e = o.entry,
                    c = widget.data.category(e.categoryId);
                return Card(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CategoryMark(c?.iconId ?? 'category', size: 48),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Wrap(
                                alignment: WrapAlignment.spaceBetween,
                                spacing: 12,
                                runSpacing: 4,
                                children: [
                                  Text(
                                    widget.data.categoryName(e),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    '${formatExactMoney(e.amount, scale: e.scale)} ${e.currency}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                              Text(
                                '${russianExpenseDate(parseExpenseDate(e.date))} • ${o.kind.label}${e.transferId != null ? ' • Комиссия перевода' : ''}',
                              ),
                              Row(
                                children: [
                                  WalletMark(
                                    widget.data
                                            .wallet(e.walletId)
                                            ?.displayIconId ??
                                        'cash',
                                    size: 28,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(widget.data.walletName(e)),
                                  ),
                                ],
                              ),
                              if (e.comment.isNotEmpty) Text(e.comment),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.buckets, this.metric, this.total);
  final List<ReportBucket> buckets;
  final ReportMetric metric;
  final BigInt total;
  @override
  void paint(Canvas canvas, Size size) {
    var start = -math.pi / 2;
    for (final b in buckets) {
      final angle = reportRatio(b.total.value(metric), total) * math.pi * 2;
      canvas.drawArc(
        Rect.fromCircle(
          center: Offset(size.width / 2, size.height / 2),
          radius: 90,
        ),
        start,
        angle,
        false,
        Paint()
          ..color = reportColor(b.key)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 44,
      );
      start += angle;
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) => true;
}

class _LinePainter extends CustomPainter {
  _LinePainter(this.series, this.max);
  final List<List<double>> series;
  final double max;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawLine(
      const Offset(12, 100),
      Offset(size.width - 12, 100),
      Paint()..color = Colors.grey,
    );
    for (var s = 0; s < series.length; s++) {
      final path = Path(), values = series[s];
      for (var i = 0; i < values.length; i++) {
        final point = Offset(
          12 + (size.width - 24) * i / math.max(1, values.length - 1),
          100 - (max == 0 ? 0 : values[i] / max * 85),
        );
        if (i == 0) {
          path.moveTo(point.dx, point.dy);
        } else {
          path.lineTo(point.dx, point.dy);
        }
        canvas.drawCircle(point, 3, Paint()..color = reportColors[s]);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = reportColors[s]
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _LinePainter old) => true;
}
