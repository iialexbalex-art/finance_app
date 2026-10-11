import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_service.dart';
import 'category.dart';
import 'category_tree.dart';
import 'category_picker_dialog.dart';
import 'app_theme.dart';
import 'wallet_icons.dart';
import 'expense_filter.dart';
import 'expense_filters_bar.dart';
import 'expense.dart';
import 'finance_repository.dart';
import 'expense_draft_store.dart';
import 'money.dart';
import 'cashflow_delete_dialog.dart';

String expenseError(Object error) {
  if (error is FormatException) return error.message;
  if (error is PostgrestException) {
    if (error.code == 'P1005') {
      return 'Комиссия связана с переводом. Откройте перевод для изменения комиссии.';
    }
    if (error.code == 'P1006') {
      return 'Кошелёк перемещён в архив. Обновите список и выберите активный кошелёк.';
    }
    if (error.code == 'PGRST202' ||
        error.code == 'PGRST205' ||
        error.code == '42703' ||
        error.code == '42P01') {
      return 'Обновите схему: требуются миграции 001–013.';
    }
    if (error.code == 'P1001') {
      return 'Категория или её предок архивированы либо недоступны. Обновите варианты и выберите категорию.';
    }
    if (error.code == 'P1002') {
      return 'Идентификатор запроса уже использован с другими данными. Проверьте историю; повтор с изменёнными полями запрещён.';
    }
    if (error.code == 'P1003') {
      return 'Расход изменён в другой вкладке. Ваши поля сохранены для сверки. Нажмите «Отмена», обновите историю и откройте расход заново.';
    }
    if (error.code == 'P1004') {
      return 'Валюта кошелька изменилась. Обновите варианты и заново укажите сумму.';
    }
    if (error.code == '40001' || error.code == '40P01') {
      return 'Данные одновременно изменились. Повторите тот же запрос.';
    }
  }
  return financeError(error);
}

class ExpensesScreen extends StatefulWidget {
  const ExpensesScreen({
    required this.space,
    required this.isOwner,
    required this.userId,
    required this.auth,
    required this.repository,
    this.initialWalletId,
    this.isIncome = false,
    this.onOpenTransfer,
    this.onChanged,
    super.key,
  });
  final FinanceSpace space;
  final bool isOwner;
  final String userId;
  final AuthService auth;
  final FinanceRepository repository;
  final String? initialWalletId;
  final bool isIncome;
  final ValueChanged<String>? onOpenTransfer;
  final VoidCallback? onChanged;
  @override
  State<ExpensesScreen> createState() => _ExpensesScreenState();
}

class _ExpensesScreenState extends State<ExpensesScreen> {
  String _label(String text) => widget.isIncome
      ? text.replaceAll('расход', 'доход').replaceAll('Расход', 'Доход')
      : text;
  CategoryKind get _kind =>
      widget.isIncome ? CategoryKind.income : CategoryKind.expense;
  ExpenseDraftStore get _journal => widget.isIncome
      ? widget.repository.incomeDrafts
      : widget.repository.expenseDrafts;
  Future<ExpenseQueryResult> _query({
    Expense? before,
    required bool includeTotals,
  }) => widget.isIncome
      ? widget.repository.queryIncomes(
          widget.space.id,
          _filter,
          before: before,
          includeTotals: includeTotals,
        )
      : widget.repository.queryExpenses(
          widget.space.id,
          _filter,
          before: before,
          includeTotals: includeTotals,
        );
  ExpenseFilter _filter = const ExpenseFilter();
  List<ExpenseTotal> _totals = [];
  List<Wallet> _wallets = [];
  List<FinanceCategory> _categories = [];
  List<Expense> _history = [];
  final _selectedOperations = <String, Expense>{};

  Future<void> _deleteOperations(List<Expense> rows) async {
    if (_locked || _adding || !widget.isOwner || rows.isEmpty) return;
    if (rows.any((e) => e.transferId != null)) {
      setState(
        () => _error = 'Комиссию можно изменить только через перевод. Она не включается в массовое удаление.',
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) =>
            CashflowDeleteDialog(rows: rows, income: widget.isIncome),
      );
      if (confirmed != true || !_current) return;
      await widget.repository.deleteCashflow(
        newExpenseRequestId(),
        widget.space.id,
        _kind,
        rows,
      );
      if (!_current) return;
      setState(() {
        _selectedOperations.clear();
        _success = 'Удалено операций: ${rows.length}';
      });
      widget.onChanged?.call();
      // Query-based balances already exclude removed rows; no manual adjustment.
      setState(() => _saving = false);
      await _load();
    } catch (error) {
      if (_current) setState(() => _pageError = financeError(error));
    } finally {
      if (_current) setState(() => _saving = false);
    }
  }

  bool _loading = true,
      _more = false,
      _loadingMore = false,
      _saving = false,
      _adding = false;
  bool _restored = false;
  String? _error, _saveError, _pageError, _walletId, _categoryId, _success;
  PendingExpense? _pending;
  Expense? _editing;
  bool _conflict = false;
  String? _currencyNotice;
  final _editorKey = GlobalKey();
  final _amount = TextEditingController();
  final _date = TextEditingController(text: russianExpenseDate(DateTime.now()));
  final _comment = TextEditingController();
  final _form = GlobalKey<FormState>();
  int _request = 0;
  bool get _current => mounted && widget.auth.currentUserId == widget.userId;
  bool get _locked => _saving || _pending != null;
  Wallet? get _wallet => _wallets.where((w) => w.id == _walletId).firstOrNull;
  List<Wallet> get _operationWallets => _wallets
      .where(
        (w) =>
            !w.isArchived ||
            w.id == _editing?.walletId ||
            w.id == _pending?.walletId,
      )
      .toList();
  CategoryTree get _tree => CategoryTree(_categories);
  List<FinanceCategory> get _available => _categories
      .where(
        (c) =>
            c.kind == _kind &&
            c.spaceId == widget.space.id &&
            (!_tree.archived(c) || c.id == _editing?.categoryId),
      )
      .toList();

  @override
  void initState() {
    super.initState();
    _filter = ExpenseFilter(
      walletIds: widget.initialWalletId == null
          ? const []
          : [widget.initialWalletId!],
    );
    _load();
  }

  Future<void> _load() async {
    if (widget.isIncome && !widget.isOwner) return;
    if (_saving) return;
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
      _pageError = null;
      _history = [];
      _selectedOperations.clear();
      _totals = [];
      _more = false;
      _loadingMore = false;
    });
    try {
      final values = await Future.wait<Object?>([
        widget.repository.loadWallets(widget.space.id),
        widget.repository.loadCategories(widget.space.id, _kind),
        _query(includeTotals: widget.isOwner),
        _restored
            ? Future.value(_pending)
            : _journal.read(widget.userId, widget.space.id),
      ]);
      if (!_current || request != _request) return;
      setState(() {
        final previousWallet = _wallet;
        _wallets = values[0] as List<Wallet>;
        _categories = (values[1] as List<FinanceCategory>)
            .where((c) => c.spaceId == widget.space.id && c.kind == _kind)
            .toList();
        final result = values[2] as ExpenseQueryResult;
        final page = result.page;
        _totals = result.totals;
        _history = page.items;
        _more = page.hasMore;
        if (!_restored) {
          _pending = values[3] as PendingExpense?;
          if (_pending != null) {
            final p = _pending!;
            if (p.isEdit) {
              _editing = Expense(
                id: p.expenseId!,
                date: p.date,
                amount: BigInt.parse(p.amountMinor),
                currency: p.currency,
                scale: p.scale,
                walletName: p.walletName,
                categoryPath: p.originalCategoryPath ?? p.categoryPath,
                comment: p.comment,
                walletId: p.walletId,
                categoryId: p.originalCategoryId ?? p.categoryId,
                revision: p.expectedRevision!,
              );
            }
            _adding = true;
            _walletId = p.walletId;
            _categoryId = p.categoryId;
            _amount.text = formatMoney(
              BigInt.parse(p.amountMinor),
              scale: p.scale,
            );
            _date.text = russianExpenseDate(parseExpenseDate(p.date));
            _comment.text = p.comment;
          }
          _restored = true;
        }
        if (_pending == null) {
          if (!_operationWallets.any((w) => w.id == _walletId)) {
            _walletId = _operationWallets.firstOrNull?.id;
          }
          if (!_available.any((c) => c.id == _categoryId)) _categoryId = null;
          if (_adding &&
              previousWallet != null &&
              (previousWallet.currency != _wallet?.currency ||
                  previousWallet.currencyScale != _wallet?.currencyScale)) {
            _amount.clear();
            _currencyNotice =
                'Новая валюта: ${_wallet?.currency}. Укажите сумму заново; конвертация не выполняется.';
          }
        }
      });
    } catch (error) {
      if (_current && request == _request) {
        setState(() => _error = expenseError(error));
      }
    } finally {
      if (_current && request == _request) setState(() => _loading = false);
    }
  }

  Future<void> _nextPage() async {
    if (_loadingMore || !_more || _history.isEmpty || _loading) return;
    final request = _request;
    setState(() {
      _loadingMore = true;
      _pageError = null;
    });
    try {
      final result = await _query(includeTotals: false, before: _history.last);
      final page = result.page;
      if (!_current || request != _request) return;
      setState(() {
        final ids = _history.map((e) => e.id).toSet();
        _history = [
          ..._history,
          ...page.items.where((e) => !ids.contains(e.id)),
        ];
        _more = page.hasMore;
      });
    } catch (error) {
      if (_current && request == _request) {
        setState(() => _pageError = expenseError(error));
      }
    } finally {
      if (_current && request == _request) setState(() => _loadingMore = false);
    }
  }

  Future<void> _save() async {
    if (widget.isIncome && !widget.isOwner) return;
    if (_saving ||
        !_current ||
        _conflict ||
        (_editing != null && !widget.isOwner)) {
      return;
    }
    if (_pending == null && !_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _saveError = null;
      _success = null;
    });
    var confirmed = false;
    try {
      if (_pending == null) {
        final wallet = _wallet!;
        final cat = _available.firstWhere((c) => c.id == _categoryId);
        final draft = PendingExpense(
          requestId: newExpenseRequestId(),
          expenseId: _editing?.id,
          expectedRevision: _editing?.revision,
          originalCategoryId: _editing?.categoryId,
          originalCategoryPath: _editing?.categoryPath,
          spaceId: widget.space.id,
          walletId: wallet.id,
          categoryId: cat.id,
          amountMinor: parseExpenseMoney(
            _amount.text,
            scale: wallet.currencyScale,
          ).toString(),
          date: expenseDate(parseRussianExpenseDate(_date.text)),
          comment: _comment.text.trim(),
          currency: wallet.currency,
          scale: wallet.currencyScale,
          walletName: wallet.name,
          categoryPath: _tree.path(cat),
        );
        // No network write until the stable payload is durably stored.
        await _journal.write(widget.userId, draft);
        if (!_current) return;
        setState(() => _pending = draft);
      }
      final pending = _pending!;
      if (widget.isIncome) {
        await widget.repository.saveIncome(pending);
      } else if (pending.isEdit) {
        await widget.repository.editExpense(pending);
      } else {
        await widget.repository.createExpense(pending);
      }
      confirmed = true;
      // Clear only this submitted context, even if navigation changed meanwhile.
      await _journal.clear(
        widget.userId,
        pending.spaceId,
        requestId: pending.requestId,
      );
      if (!_current) return;
      setState(() {
        _pending = null;
        _restored = false;
        _adding = false;
        _editing = null;
        _amount.clear();
        _comment.clear();
        _date.text = russianExpenseDate(DateTime.now());
        _success = _label('Расход сохранён.');
      });
    } catch (error) {
      if (!_current) return;
      // P1001 is emitted only after server established this request does NOT exist.
      if (error is PostgrestException &&
          [
            'P1001',
            'P1003',
            'P1004',
            'P1005',
            '22023',
            '22003',
            '42501',
          ].contains(error.code) &&
          _pending != null) {
        try {
          await _journal.clear(
            widget.userId,
            widget.space.id,
            requestId: _pending!.requestId,
          );
          if (!_current) return;
          setState(() {
            _pending = null;
            _conflict = error.code == 'P1003';
          });
        } catch (_) {
          /* Keep immutable retry when local storage fails. */
        }
      }
      if (_current) {
        setState(
          () => _saveError = confirmed
              ? _label(
                  'Сервер подтвердил расход, но локальное завершение не удалось. Повторите: дубль не создастся.',
                )
              : expenseError(error),
        );
      }
    } finally {
      if (_current) {
        setState(() => _saving = false);
        if (_success != null) await _load();
      }
    }
  }

  void _openEdit(Expense expense) {
    if (!widget.isOwner || _locked) return;
    if (expense.transferId != null) {
      widget.onOpenTransfer?.call(expense.transferId!);
      return;
    }
    setState(() {
      _editing = expense;
      _adding = true;
      _conflict = false;
      _saveError = null;
      _success = null;
      _currencyNotice = null;
      _walletId = expense.walletId;
      _categoryId = expense.categoryId;
      _amount.text = formatMoney(expense.amount, scale: expense.scale);
      _date.text = russianExpenseDate(parseExpenseDate(expense.date));
      _comment.text = expense.comment;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_editorKey.currentContext != null) {
        Scrollable.ensureVisible(_editorKey.currentContext!);
      }
    });
  }

  Future<void> _pickDate() async {
    DateTime initial;
    try {
      initial = parseRussianExpenseDate(_date.text);
    } on FormatException {
      initial = DateTime.now();
    }
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(1),
      lastDate: DateTime(9999, 12, 31),
      initialEntryMode: DatePickerEntryMode.calendarOnly,
      helpText: _label('Выберите дату расхода'),
    );
    if (_current && !_locked && date != null) {
      setState(() => _date.text = russianExpenseDate(date));
    }
  }

  @override
  void dispose() {
    _request++;
    _amount.dispose();
    _date.dispose();
    _comment.dispose();
    super.dispose();
  }

  Widget _editor() {
    final wallets = _operationWallets;
    final categories = _available;
    return Card(
      key: _editorKey,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _editing == null
                    ? _label('Новый расход')
                    : _label('Редактирование расхода'),
              ),
              if (_pending != null)
                Text(
                  'Запрос ожидает подтверждения: ${_wallet?.name ?? 'Кошелёк недоступен'}, ${_pending!.categoryPath}. Поля зафиксированы; повтор использует тот же идентификатор.',
                ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: ValueKey('expense-wallet:$_walletId'),
                initialValue: _walletId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Кошелёк',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final w in wallets)
                    DropdownMenuItem(
                      value: w.id,
                      child: WalletLabel(w, currency: true),
                    ),
                  if (_pending != null &&
                      !wallets.any((w) => w.id == _walletId))
                    DropdownMenuItem(
                      value: _walletId,
                      child: const WalletLabel(null),
                    ),
                ],
                onChanged: _locked
                    ? null
                    : (id) => setState(() {
                        final previous = _wallet;
                        _walletId = id;
                        if (previous?.currency != _wallet?.currency ||
                            previous?.currencyScale != _wallet?.currencyScale) {
                          _amount.clear();
                          _currencyNotice =
                              'Новая валюта: ${_wallet?.currency}. Укажите сумму заново; конвертация не выполняется.';
                        }
                      }),
                validator: (v) => v == null ? 'Выберите кошелёк.' : null,
              ),
              const SizedBox(height: 12),
              if (_currencyNotice != null) Text(_currencyNotice!),
              TextFormField(
                controller: _amount,
                enabled: !_locked,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText:
                      'Сумма (${_pending?.currency ?? _wallet?.currency ?? ''})',
                  border: const OutlineInputBorder(),
                  errorMaxLines: 4,
                ),
                validator: (value) {
                  try {
                    if (_wallet == null) return 'Выберите кошелёк.';
                    parseExpenseMoney(
                      value ?? '',
                      scale: _wallet!.currencyScale,
                    );
                    return null;
                  } on FormatException catch (e) {
                    return _label(e.message);
                  }
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: ValueKey('expense-category:$_categoryId'),
                initialValue: _categoryId,
                isExpanded: true,
                itemHeight: null,
                decoration: InputDecoration(
                  labelText: _label('Категория расхода'),
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final c in categories)
                    DropdownMenuItem(
                      value: c.id,
                      child: CategoryLabel(
                        c.iconId,
                        c.id == _editing?.categoryId
                            ? '${_editing!.categoryPath}${_tree.archived(c) ? ' (архивная; можно оставить)' : ''}'
                            : _tree.path(c),
                      ),
                    ),
                  if (_pending != null &&
                      !categories.any((c) => c.id == _categoryId))
                    DropdownMenuItem(
                      value: _categoryId,
                      child: Text(_pending!.categoryPath),
                    ),
                ],
                onChanged: _locked
                    ? null
                    : (id) => setState(() => _categoryId = id),
                validator: (v) =>
                    v == null ? _label('Выберите категорию расхода.') : null,
              ),
              const SizedBox(height: 12),
              if (widget.space.kind == 'business')
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.search),
                    label: const Text('Найти категорию в дереве'),
                    onPressed: _locked
                        ? null
                        : () async {
                            final selected = await showDialog<String>(
                              context: context,
                              builder: (_) => CategoryPickerDialog(
                                categories: categories,
                                selected: _categoryId,
                              ),
                            );
                            if (mounted && !_locked && selected != null) {
                              setState(() => _categoryId = selected);
                            }
                          },
                  ),
                ),
              TextFormField(
                controller: _date,
                enabled: !_locked,
                decoration: InputDecoration(
                  labelText: 'Дата',
                  helperText: 'День, месяц, год: 30 сентября 2026',
                  helperMaxLines: 2,
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    onPressed: _locked ? null : _pickDate,
                    tooltip: 'Выбрать дату',
                    icon: const Icon(Icons.calendar_month),
                  ),
                ),
                validator: (value) {
                  try {
                    parseRussianExpenseDate(value ?? '');
                    return null;
                  } on FormatException catch (e) {
                    return e.message;
                  }
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _comment,
                enabled: !_locked,
                maxLength: 1000,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Комментарий (необязательно)',
                  border: OutlineInputBorder(),
                ),
                validator: (v) => (v ?? '').runes.length > 1000
                    ? 'Не более 1000 символов.'
                    : null,
              ),
              if (_saveError != null)
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _saveError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton(
                    onPressed: _saving || _conflict ? null : _save,
                    child: Text(
                      _saving
                          ? 'Сохраняем…'
                          : _pending == null
                          ? (_editing == null
                                ? _label('Сохранить расход')
                                : 'Сохранить')
                          : 'Повторить сохранение',
                    ),
                  ),
                  if (_pending == null)
                    TextButton(
                      onPressed: _saving
                          ? null
                          : () => setState(() {
                              _adding = false;
                              _editing = null;
                              _conflict = false;
                            }),
                      child: const Text('Отмена'),
                    ),
                  TextButton(
                    onPressed: _saving ? null : _load,
                    child: const Text('Обновить варианты'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.isIncome && !widget.isOwner
      ? const Text('Доходы доступны только владельцу.')
      : Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ExpenseFiltersBar(
              filter: _filter,
              wallets: _wallets,
              categories: _categories,
              enabled: !_saving && !_loading,
              onChanged: (filter) {
                setState(() => _filter = filter);
                _load();
              },
            ),
            Wrap(
              spacing: 8,
              children: [
                if (!_adding)
                  FilledButton(
                    onPressed:
                        _locked ||
                            _loading ||
                            _error != null ||
                            _operationWallets.isEmpty ||
                            _available.isEmpty
                        ? null
                        : () => setState(() {
                            _adding = true;
                            _editing = null;
                            _conflict = false;
                            _saveError = null;
                            _currencyNotice = null;
                            _amount.clear();
                            _comment.clear();
                            _date.text = russianExpenseDate(DateTime.now());
                            _categoryId = null;
                            _success = null;
                          }),
                    child: Text(_label('Добавить расход')),
                  ),
                TextButton(
                  onPressed: _saving || _loading ? null : _load,
                  child: Text(_label('Обновить расходы')),
                ),
              ],
            ),
            if (_success != null)
              Semantics(liveRegion: true, child: Text(_success!)),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(16),
                child: LinearProgressIndicator(),
              ),
            if (_error != null) Text(_error!),
            if (!_loading && _error == null && _wallets.isEmpty)
              const Text(
                'Нет доступных кошельков. Владельцу нужно создать кошелёк или назначить вам доступ.',
              ),
            if (!_loading &&
                _error == null &&
                _wallets.isNotEmpty &&
                _operationWallets.isEmpty)
              const Text(
                'Все кошельки находятся в архиве. Верните нужный кошелёк из архива для новой операции.',
              ),
            if (!_loading && _error == null && _available.isEmpty)
              Text(
                _label(
                  'Нет доступных неархивных категорий расходов. Обратитесь к владельцу или создайте категорию в разделе «Категории».',
                ),
              ),
            if (_adding && !_loading) _editor(),
            if (widget.isOwner && !_loading && _error == null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(_label('Итог расходов по выбранным фильтрам')),
                      const Text('Все подходящие записи за период'),
                      if (_totals.isEmpty) Text(_label('Нет расходов')),
                      for (final total in _totals)
                        Text(
                          '${widget.isIncome ? '+' : '−'}${formatExactMoney(total.amount, scale: total.scale)} ${total.currency}',
                          style: TextStyle(
                            color: widget.isIncome ? incomeColor : expenseColor,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 16),
            Text(_label('История расходов')),
            if (widget.isOwner)
              Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  TextButton(
                    onPressed: _locked || _adding || _loading
                        ? null
                        : () => setState(() {
                            for (final e in _history.where(
                              (e) => e.transferId == null,
                            )) {
                              _selectedOperations[e.id] = e;
                            }
                          }),
                    child: const Text('Выделить все операции'),
                  ),
                  if (_selectedOperations.isNotEmpty) ...[
                    Text('Выбрано операций: ${_selectedOperations.length}'),
                    FilledButton.tonal(
                      onPressed: _locked || _adding
                          ? null
                          : () => _deleteOperations(
                              _selectedOperations.values.toList(),
                            ),
                      child: const Text('Удалить выбранные'),
                    ),
                    TextButton(
                      onPressed: _locked
                          ? null
                          : () => setState(_selectedOperations.clear),
                      child: const Text('Снять выделение'),
                    ),
                  ],
                ],
              ),
            if (!_loading && _error == null && _history.isEmpty)
              Text(_label('По выбранным фильтрам расходов нет')),
            for (var index = 0; index < _history.length; index++) ...[
              if (index == 0 ||
                  _history[index - 1].date != _history[index].date)
                Padding(
                  padding: const EdgeInsets.only(top: 16, bottom: 6),
                  child: Text(
                    russianExpenseDate(parseExpenseDate(_history[index].date)),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
              _expenseRow(_history[index]),
            ],
            if (_pageError != null) Text(_pageError!),
            if (_more)
              TextButton(
                onPressed: _loadingMore ? null : _nextPage,
                child: Text(_loadingMore ? 'Загружаем…' : 'Загрузить ещё'),
              ),
          ],
        );

  Widget _expenseRow(Expense e) {
    final category = _categories
        .where((candidate) => candidate.id == e.categoryId)
        .firstOrNull;
    return FinanceRow(
      icon: walletIcon(
        _wallets.where((w) => w.id == e.walletId).firstOrNull?.group ??
            WalletGroup.cash,
      ),
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.isOwner)
            Checkbox(
              key: ValueKey('select-operation:${e.id}'),
              value: _selectedOperations.containsKey(e.id),
              onChanged: _locked || _adding || e.transferId != null
                  ? null
                  : (selected) => setState(() {
                      if (selected == true) {
                        _selectedOperations[e.id] = e;
                      } else {
                        _selectedOperations.remove(e.id);
                      }
                    }),
            ),
          CategoryMark(
            _categories.where((c) => c.id == e.categoryId).firstOrNull?.iconId,
          ),
        ],
      ),
      title: category == null ? e.categoryPath : _tree.path(category),
      details: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          WalletLabel(
            _wallets.where((w) => w.id == e.walletId).firstOrNull,
            size: 20,
          ),
          if (e.transferId != null)
            const Text('Комиссия перевода · изменить через перевод'),
          if (e.comment.isNotEmpty) Text(e.comment),
          if (widget.isOwner)
            const Text('Редактировать', style: TextStyle(fontSize: 12)),
        ],
      ),
      amount: Text(
        '${widget.isIncome ? '+' : '−'}${formatMoney(e.amount, scale: e.scale)} ${e.currency}',
        style: TextStyle(
          color: widget.isIncome ? incomeColor : expenseColor,
          fontWeight: FontWeight.w600,
        ),
      ),
      onTap: widget.isOwner && !_locked ? () => _openEdit(e) : null,
      action: widget.isOwner
          ? PopupMenuButton<String>(
              key: ValueKey('operation-menu:${e.id}'),
              tooltip: 'Действия операции',
              enabled: !_locked && !_adding,
              onSelected: (action) {
                if (action == 'transfer') {
                  widget.onOpenTransfer?.call(e.transferId!);
                } else if (action == 'edit') {
                  _openEdit(e);
                } else {
                  _deleteOperations([e]);
                }
              },
              itemBuilder: (_) => [
                if (e.transferId != null)
                  PopupMenuItem(
                    value: 'transfer',
                    enabled: widget.onOpenTransfer != null,
                    child: const Text('Открыть перевод и изменить комиссию'),
                  )
                else ...[
                  const PopupMenuItem(
                    value: 'edit',
                    child: Text('Редактировать'),
                  ),
                  const PopupMenuItem(
                    value: 'delete',
                    child: Text('Удалить операцию'),
                  ),
                ],
              ],
            )
          : null,
    );
  }
}
