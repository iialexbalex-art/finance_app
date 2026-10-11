import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_theme.dart';
import 'wallet_icons.dart';
import 'auth_service.dart';
import 'category.dart';
import 'category_tree.dart';
import 'expense.dart';
import 'expense_filter.dart';
import 'expense_filters_bar.dart';
import 'expenses_screen.dart' show expenseError;
import 'finance_repository.dart';
import 'money.dart';
import 'transfer.dart';

class TransfersScreen extends StatefulWidget {
  const TransfersScreen({
    required this.space,
    required this.isOwner,
    required this.userId,
    required this.auth,
    required this.repository,
    this.initialTransferId,
    super.key,
  });
  final FinanceSpace space;
  final bool isOwner;
  final String userId;
  final AuthService auth;
  final FinanceRepository repository;
  final String? initialTransferId;
  @override
  State<TransfersScreen> createState() => _TransfersScreenState();
}

class _TransfersScreenState extends State<TransfersScreen> {
  final _form = GlobalKey<FormState>(), _editorKey = GlobalKey();
  final _sourceAmount = TextEditingController(),
      _targetAmount = TextEditingController(),
      _fee = TextEditingController();
  final _date = TextEditingController(text: russianExpenseDate(DateTime.now()));
  final _comment = TextEditingController(), _search = TextEditingController();
  List<Wallet> _wallets = [];
  List<FinanceCategory> _categories = [];
  List<Transfer> _rows = [];
  ExpenseFilter _filter = const ExpenseFilter();
  Transfer? _editing;
  PendingTransfer? _pending;
  String? _sourceId,
      _targetId,
      _feeCategoryId,
      _error,
      _saveError,
      _success,
      _pageError;
  bool _loading = true,
      _saving = false,
      _adding = false,
      _more = false,
      _loadingMore = false,
      _restored = false,
      _conflict = false;
  int _request = 0;
  bool _linkedOpened = false;
  String _appliedSearch = '';
  bool get _current => mounted && widget.auth.currentUserId == widget.userId;
  bool get _locked => _saving || _pending != null;
  Wallet? get _source => _wallets.where((w) => w.id == _sourceId).firstOrNull;
  Wallet? get _target => _wallets.where((w) => w.id == _targetId).firstOrNull;
  List<Wallet> get _operationWallets => _wallets
      .where(
        (w) =>
            !w.isArchived ||
            w.id == _editing?.sourceId ||
            w.id == _editing?.targetId ||
            w.id == _pending?.data['source_id'] ||
            w.id == _pending?.data['target_id'],
      )
      .toList();
  bool get _sameCurrency =>
      _source != null &&
      _target != null &&
      _source!.currency == _target!.currency;
  CategoryTree get _tree => CategoryTree(_categories);
  List<FinanceCategory> get _available => _categories
      .where((c) => !_tree.archived(c) || c.id == _editing?.feeCategoryId)
      .toList();
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [
      _sourceAmount,
      _targetAmount,
      _fee,
      _date,
      _comment,
      _search,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    if (!widget.isOwner || _saving) return;
    final request = ++_request;
    _appliedSearch = _search.text.trim();
    setState(() {
      _loading = true;
      _error = null;
      _rows = [];
      _more = false;
      _loadingMore = false;
      _pageError = null;
    });
    try {
      final values = await Future.wait<Object?>([
        widget.repository.loadWallets(widget.space.id),
        widget.repository.loadCategories(widget.space.id, CategoryKind.expense),
        widget.repository.queryTransfers(
          widget.space.id,
          _filter,
          search: _appliedSearch,
        ),
        _restored
            ? Future.value(_pending)
            : widget.repository.transferDrafts.read(
                widget.userId,
                widget.space.id,
              ),
        !_linkedOpened && widget.initialTransferId != null
            ? widget.repository.queryTransfers(
                widget.space.id,
                const ExpenseFilter(),
                id: widget.initialTransferId,
              )
            : Future.value(null),
      ]);
      if (!_current || request != _request) return;
      setState(() {
        _wallets = values[0] as List<Wallet>;
        _categories = (values[1] as List<FinanceCategory>)
            .where(
              (c) =>
                  c.spaceId == widget.space.id &&
                  c.kind == CategoryKind.expense,
            )
            .toList();
        final page = values[2] as TransferPage;
        _rows = page.items;
        _more = page.hasMore;
        if (!_restored) {
          _pending = values[3] as PendingTransfer?;
          if (_pending != null) {
            _restore(_pending!);
          } else {
            final linked = (values[4] as TransferPage?)?.items.firstOrNull;
            if (linked != null) {
              _fill(linked);
            } else if (!_linkedOpened && widget.initialTransferId != null) {
              _error = 'Связанный перевод недоступен. Обновите данные.';
            }
          }
          _restored = true;
          _linkedOpened = true;
        }
      });
    } catch (e) {
      if (_current && request == _request) {
        setState(() => _error = expenseError(e));
      }
    } finally {
      if (_current && request == _request) setState(() => _loading = false);
    }
  }

  Future<void> _next() async {
    if (_loading || _loadingMore || !_more || _rows.isEmpty) return;
    final request = _request;
    setState(() {
      _loadingMore = true;
      _pageError = null;
    });
    try {
      final page = await widget.repository.queryTransfers(
        widget.space.id,
        _filter,
        search: _appliedSearch,
        before: _rows.last,
      );
      if (!_current || request != _request) return;
      setState(() {
        final ids = _rows.map((e) => e.id).toSet();
        _rows.addAll(page.items.where((e) => !ids.contains(e.id)));
        _more = page.hasMore;
      });
    } catch (e) {
      if (_current && request == _request) {
        setState(() => _pageError = expenseError(e));
      }
    } finally {
      if (_current && request == _request) setState(() => _loadingMore = false);
    }
  }

  void _fill(Transfer? row) {
    _editing = row;
    _adding = true;
    _conflict = false;
    _saveError = null;
    _success = null;
    _sourceId = row?.sourceId ?? _operationWallets.firstOrNull?.id;
    _targetId =
        row?.targetId ??
        _operationWallets.where((w) => w.id != _sourceId).firstOrNull?.id;
    _sourceAmount.text = row == null
        ? ''
        : formatMoney(row.sourceMinor, scale: row.sourceScale);
    _targetAmount.text = row == null
        ? ''
        : formatMoney(row.targetMinor, scale: row.targetScale);
    _fee.text = row == null || row.feeMinor == BigInt.zero
        ? ''
        : formatMoney(row.feeMinor, scale: row.sourceScale);
    _feeCategoryId = row?.feeCategoryId;
    _date.text = russianExpenseDate(
      row == null ? DateTime.now() : parseExpenseDate(row.date),
    );
    _comment.text = row?.comment ?? '';
  }

  void _restore(PendingTransfer p) {
    final d = p.data, display = p.display;
    final row = Transfer.fromJson({
      ...d,
      ...display,
      'id': d['id'] ?? '',
      'revision': d['revision'] ?? '',
      'transfer_date': d['date'],
    });
    _fill(row);
    if (d['id'] == null) _editing = null;
    if (_editing != null && display['original_fee_category_id'] != null) {
      _editing = Transfer.fromJson({
        ...d,
        ...display,
        'transfer_date': d['date'],
        'fee_category_id': display['original_fee_category_id'],
        'fee_category_path': display['original_fee_category_path'],
      });
    }
  }

  void _open(Transfer? row) {
    if (_locked || !widget.isOwner) return;
    setState(() => _fill(row));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _editorKey.currentContext;
      if (mounted && target != null) {
        Scrollable.ensureVisible(
          target,
          duration: const Duration(milliseconds: 200),
        );
      }
    });
  }

  void _syncEqual() {
    if (!_sameCurrency) return;
    try {
      _targetAmount.text = formatMoney(
        equalCurrencyAmount(
          parseExpenseMoney(_sourceAmount.text, scale: _source!.currencyScale),
          _source!.currencyScale,
          _target!.currencyScale,
        ),
        scale: _target!.currencyScale,
      );
    } catch (_) {
      _targetAmount.clear();
    }
  }

  BigInt _feeValue() =>
      _fee.text.trim().isEmpty ||
          (_source?.currencyScale == 0
                  ? RegExp(r'^0+$')
                  : RegExp('^0+(?:[.,]0{1,${_source?.currencyScale ?? 2}})?\$'))
              .hasMatch(_fee.text.trim())
      ? BigInt.zero
      : parseExpenseMoney(_fee.text, scale: _source!.currencyScale);
  Future<void> _save() async {
    if (!_current || !widget.isOwner || _saving || _conflict) return;
    if (_pending == null && !_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _saveError = null;
      _success = null;
    });
    var confirmed = false;
    try {
      if (_pending == null) {
        final source = _source!, target = _target!;
        final fee = _feeValue();
        final feeCategory = fee == BigInt.zero
            ? null
            : _available.firstWhere((c) => c.id == _feeCategoryId);
        final draft = PendingTransfer(
          requestId: newExpenseRequestId(),
          data: {
            'space_id': widget.space.id,
            'id': _editing?.id,
            'revision': _editing?.revision,
            'source_id': source.id,
            'target_id': target.id,
            'source_minor': parseExpenseMoney(
              _sourceAmount.text,
              scale: source.currencyScale,
            ).toString(),
            'target_minor': parseExpenseMoney(
              _targetAmount.text,
              scale: target.currencyScale,
            ).toString(),
            'source_currency': source.currency,
            'target_currency': target.currency,
            'source_scale': source.currencyScale,
            'target_scale': target.currencyScale,
            'date': expenseDate(parseRussianExpenseDate(_date.text)),
            'comment': _comment.text.trim(),
            'fee_minor': fee.toString(),
            'fee_category_id': feeCategory?.id,
          },
          display: {
            'source_name': source.name,
            'target_name': target.name,
            'fee_category_path': feeCategory == null
                ? null
                : _tree.path(feeCategory),
            'original_fee_category_id': _editing?.feeCategoryId,
            'original_fee_category_path': _editing?.feeCategoryPath,
          },
        );
        await widget.repository.transferDrafts.write(widget.userId, draft);
        if (!_current) return;
        setState(() => _pending = draft);
      }
      final draft = _pending!;
      await widget.repository.saveTransfer(draft);
      confirmed = true;
      await widget.repository.transferDrafts.clear(
        widget.userId,
        draft.spaceId,
        draft.requestId,
      );
      if (!_current) return;
      setState(() {
        _pending = null;
        _editing = null;
        _adding = false;
        _restored = false;
        _success = 'Перевод сохранён.';
      });
    } catch (e) {
      if (!_current) return;
      if (e is PostgrestException &&
          [
            'P1001',
            'P1003',
            'P1004',
            '22023',
            '22003',
            '22P02',
            '42501',
          ].contains(e.code) &&
          _pending != null) {
        try {
          await widget.repository.transferDrafts.clear(
            widget.userId,
            widget.space.id,
            _pending!.requestId,
          );
          if (!_current) return;
          setState(() {
            _pending = null;
            _conflict = e.code == 'P1003';
          });
        } catch (_) {
          /* Keep immutable retry if local cleanup fails. */
        }
      }
      if (_current) {
        setState(
          () => _saveError = confirmed
              ? 'Сервер подтвердил перевод, но локальное завершение не удалось. Повторите тот же запрос.'
              : e is PostgrestException && e.code == 'P1003'
              ? 'Перевод изменён в другой вкладке. Поля сохранены для сверки. Отмените форму, обновите историю и откройте перевод заново.'
              : expenseError(e),
        );
      }
    } finally {
      if (_current) {
        setState(() => _saving = false);
        if (_success != null) await _load();
      }
    }
  }

  String? _amountError(String? value, Wallet? wallet) {
    try {
      if (wallet == null) return 'Выберите кошелёк.';
      parseExpenseMoney(value ?? '', scale: wallet.currencyScale);
      return null;
    } on FormatException catch (e) {
      return e.message.replaceAll('расхода', 'перевода');
    }
  }

  Widget _walletField(bool source) {
    final id = source ? _sourceId : _targetId;
    return DropdownButtonFormField<String>(
      key: ValueKey('${source ? 'source' : 'target'}:$id'),
      initialValue: id,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: source ? 'Кошелёк списания' : 'Кошелёк зачисления',
      ),
      items: [
        for (final w in _operationWallets)
          DropdownMenuItem(value: w.id, child: WalletLabel(w, currency: true)),
        if (id != null && !_wallets.any((w) => w.id == id))
          DropdownMenuItem(value: id, child: const WalletLabel(null)),
      ],
      onChanged: _locked
          ? null
          : (value) => setState(() {
              final old = source ? _source : _target;
              if (source) {
                _sourceId = value;
              } else {
                _targetId = value;
              }
              final next = source ? _source : _target;
              if (old?.currency != next?.currency ||
                  old?.currencyScale != next?.currencyScale) {
                (source ? _sourceAmount : _targetAmount).clear();
                if (source) _fee.clear();
                _saveError = 'Валюта или точность кошелька изменена. Укажите сумму заново; автоматической конвертации нет.';
              }
              _syncEqual();
            }),
      validator: (v) => v == null || !_operationWallets.any((w) => w.id == v)
          ? 'Выберите кошелёк.'
          : _sourceId == _targetId
          ? 'Выберите разные кошельки.'
          : null,
    );
  }

  String? get _rate {
    if (_source == null || _target == null || _sameCurrency) return null;
    try {
      final result = transferRate(
        parseExpenseMoney(_sourceAmount.text, scale: _source!.currencyScale),
        _source!.currencyScale,
        parseExpenseMoney(_targetAmount.text, scale: _target!.currencyScale),
        _target!.currencyScale,
      );
      return 'Справочно: 1 ${_source!.currency} = $result ${_target!.currency}. Рассчитано из введённых сумм, без комиссии.';
    } catch (_) {
      return null;
    }
  }

  Widget _editor() => Card(
    key: _editorKey,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _editing == null ? 'Новый перевод' : 'Редактирование перевода',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (widget.initialTransferId != null)
              const Text(
                'Открыт перевод, с которым связан расход комиссии. Комиссия изменяется вместе с переводом.',
              ),
            if (_pending != null)
              const Text(
                'Запрос ожидает подтверждения. Поля зафиксированы; повтор использует тот же идентификатор.',
              ),
            const SizedBox(height: 12),
            _walletField(true),
            const SizedBox(height: 12),
            _walletField(false),
            const SizedBox(height: 12),
            TextFormField(
              controller: _sourceAmount,
              enabled: !_locked,
              decoration: InputDecoration(
                labelText:
                    'Сумма списания (${_source?.currency ?? _pending?.data['source_currency'] ?? ''})',
                errorMaxLines: 3,
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              validator: (v) => _amountError(v, _source),
              onChanged: (_) => setState(_syncEqual),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _targetAmount,
              enabled: !_locked,
              readOnly: _sameCurrency,
              decoration: InputDecoration(
                labelText:
                    'Сумма зачисления (${_target?.currency ?? _pending?.data['target_currency'] ?? ''})',
                errorMaxLines: 3,
                helperText: _sameCurrency
                    ? 'Та же валюта: сумма равна списанию, комиссия отдельно.'
                    : null,
                helperMaxLines: 3,
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              validator: (v) => _amountError(v, _target),
              onChanged: (_) => setState(() {}),
            ),
            if (_rate != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(_rate!),
              ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _fee,
              enabled: !_locked,
              decoration: InputDecoration(
                labelText:
                    'Комиссия (${_source?.currency ?? _pending?.data['source_currency'] ?? ''}), необязательно',
                errorMaxLines: 3,
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              onChanged: (_) => setState(() {}),
              validator: (_) {
                try {
                  if (_source == null) return 'Выберите кошелёк.';
                  _feeValue();
                  return null;
                } on FormatException catch (e) {
                  return e.message;
                }
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: ValueKey('fee:$_feeCategoryId'),
              initialValue: _available.any((c) => c.id == _feeCategoryId)
                  ? _feeCategoryId
                  : null,
              isExpanded: true,
              itemHeight: null,
              decoration: const InputDecoration(
                labelText: 'Категория комиссии',
              ),
              items: [
                for (final c in _available)
                  DropdownMenuItem(
                    value: c.id,
                    child: CategoryLabel(
                      c.iconId,
                      '${_tree.path(c)}${_tree.archived(c) ? ' (архивная; можно оставить)' : ''}',
                    ),
                  ),
              ],
              onChanged: _locked
                  ? null
                  : (v) => setState(() => _feeCategoryId = v),
              validator: (v) {
                try {
                  return _feeValue() > BigInt.zero && v == null
                      ? 'Выберите категорию расхода.'
                      : null;
                } catch (_) {
                  return null;
                }
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _date,
              enabled: !_locked,
              decoration: InputDecoration(
                labelText: 'Дата',
                hintText: '1 октября 2026',
                suffixIcon: IconButton(
                  tooltip: 'Выбрать дату',
                  icon: const Icon(Icons.calendar_month),
                  onPressed: _locked
                      ? null
                      : () async {
                          DateTime initial;
                          try {
                            initial = parseRussianExpenseDate(_date.text);
                          } catch (_) {
                            initial = DateTime.now();
                          }
                          final date = await showDatePicker(
                            context: context,
                            initialDate: initial,
                            firstDate: DateTime(1),
                            lastDate: DateTime(9999, 12, 31),
                          );
                          if (_current && !_locked && date != null) {
                            _date.text = russianExpenseDate(date);
                          }
                        },
                ),
              ),
              validator: (v) {
                try {
                  parseRussianExpenseDate(v ?? '');
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
              decoration: const InputDecoration(labelText: 'Комментарий'),
              validator: (v) => (v ?? '').runes.length > 1000
                  ? 'Не более 1000 символов.'
                  : null,
            ),
            if (_saveError != null)
              Text(
                _saveError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: _saving || _conflict ? null : _save,
                  child: Text(
                    _saving
                        ? 'Сохраняем…'
                        : _pending != null
                        ? 'Повторить сохранение'
                        : 'Сохранить перевод',
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

  @override
  Widget build(BuildContext context) {
    if (!widget.isOwner) {
      return const Text('Переводы доступны только владельцу.');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ExpenseFiltersBar(
          filter: _filter,
          wallets: _wallets,
          categories: const [],
          showCategories: false,
          enabled: !_loading && !_saving,
          onReset: _search.clear,
          onChanged: (f) {
            setState(() {
              _filter = f;
            });
            _load();
          },
        ),
        TextField(
          controller: _search,
          enabled: !_saving,
          decoration: InputDecoration(
            labelText: 'Поиск по комментарию',
            suffixIcon: IconButton(
              tooltip: 'Найти переводы',
              onPressed: _saving ? null : _load,
              icon: const Icon(Icons.search),
            ),
          ),
          onSubmitted: (_) => _load(),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          children: [
            if (!_adding)
              FilledButton.icon(
                onPressed: _loading || _operationWallets.length < 2
                    ? null
                    : () => _open(null),
                icon: const Icon(Icons.add),
                label: const Text('Добавить перевод'),
              ),
            TextButton(
              onPressed: _loading || _saving ? null : _load,
              child: const Text('Обновить переводы'),
            ),
          ],
        ),
        if (_loading) const LinearProgressIndicator(),
        if (_error != null) Text(_error!),
        if (_success != null) Text(_success!),
        if (!_loading && _operationWallets.length < 2)
          const Text('Для перевода нужны два кошелька одного пространства.'),
        if (_adding && !_loading) _editor(),
        if (!_loading && _error == null && _rows.isEmpty)
          const Text('По выбранным фильтрам переводов нет'),
        for (var i = 0; i < _rows.length; i++) ...[
          if (i == 0 || _rows[i - 1].date != _rows[i].date)
            Padding(
              padding: const EdgeInsets.only(top: 16, bottom: 6),
              child: Text(russianExpenseDate(parseExpenseDate(_rows[i].date))),
            ),
          FinanceRow(
            icon: Icons.swap_horiz,
            title: '${_rows[i].sourceName} → ${_rows[i].targetName}',
            titleWidget: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                WalletLabel(
                  _wallets.where((w) => w.id == _rows[i].sourceId).firstOrNull,
                ),
                const Padding(
                  padding: EdgeInsets.only(left: 12),
                  child: Text('↓'),
                ),
                WalletLabel(
                  _wallets.where((w) => w.id == _rows[i].targetId).firstOrNull,
                ),
              ],
            ),
            details: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_rows[i].comment.isNotEmpty) Text(_rows[i].comment),
                if (_rows[i].feeMinor > BigInt.zero)
                  Text(
                    'Комиссия: −${formatMoney(_rows[i].feeMinor, scale: _rows[i].sourceScale)} ${_rows[i].sourceCurrency} · ${_rows[i].feeCategoryPath}',
                    style: const TextStyle(color: expenseColor),
                  ),
                const Text('Редактировать', style: TextStyle(fontSize: 12)),
              ],
            ),
            amount: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '−${formatMoney(_rows[i].sourceMinor, scale: _rows[i].sourceScale)} ${_rows[i].sourceCurrency}',
                  style: const TextStyle(
                    color: expenseColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '+${formatMoney(_rows[i].targetMinor, scale: _rows[i].targetScale)} ${_rows[i].targetCurrency}',
                  style: const TextStyle(
                    color: incomeColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            onTap: _locked ? null : () => _open(_rows[i]),
          ),
        ],
        if (_pageError != null) Text(_pageError!),
        if (_more)
          TextButton(
            onPressed: _loadingMore ? null : _next,
            child: Text(_loadingMore ? 'Загружаем…' : 'Загрузить ещё'),
          ),
      ],
    );
  }
}
