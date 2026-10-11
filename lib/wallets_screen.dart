import 'package:flutter/material.dart';

import 'finance_controller.dart';
import 'finance_repository.dart';
import 'opening_balance_panel.dart';
import 'wallet_icons.dart';
import 'money.dart';

class RequestError extends StatelessWidget {
  const RequestError({required this.message, required this.retry, super.key});
  final String message;
  final VoidCallback retry;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 16),
    child: Column(
      children: [
        Semantics(
          liveRegion: true,
          child: Text(message, textAlign: TextAlign.center),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: retry,
          icon: const Icon(Icons.refresh),
          label: const Text('Повторить попытку'),
        ),
      ],
    ),
  );
}

class SpaceSelector extends StatelessWidget {
  const SpaceSelector({required this.controller, super.key});
  final FinanceController controller;
  @override
  Widget build(BuildContext context) {
    final state = controller;
    if (state.loadingSpaces) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(
          child: CircularProgressIndicator(
            semanticsLabel: 'Загрузка пространств',
          ),
        ),
      );
    }
    if (state.spacesError != null) {
      return RequestError(message: state.spacesError!, retry: state.loadSpaces);
    }
    if (state.spaces.isEmpty) {
      return Column(
        children: [
          const Text('Нет доступных пространств'),
          const SizedBox(height: 8),
          const Text(
            'Обратитесь к владельцу для назначения доступа.',
            textAlign: TextAlign.center,
          ),
          TextButton(
            onPressed: state.loadSpaces,
            child: const Text('Обновить пространства'),
          ),
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            key: ValueKey(state.selectedSpace?.id),
            initialValue: state.selectedSpace?.id,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Личное / Бизнес',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final space in state.spaces)
                DropdownMenuItem(
                  value: space.id,
                  child: Text(space.name, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (id) {
              if (id != null) state.selectSpace(id);
            },
          ),
        ),
        IconButton(
          tooltip: 'Обновить пространства',
          onPressed: state.loadSpaces,
          icon: const Icon(Icons.refresh),
        ),
      ],
    );
  }
}

class WalletsScreen extends StatefulWidget {
  const WalletsScreen({required this.controller, super.key});
  final FinanceController controller;
  @override
  State<WalletsScreen> createState() => _WalletsScreenState();
}

class _WalletsScreenState extends State<WalletsScreen> {
  bool _adding = false;
  bool _showArchive = false;
  Wallet? _editing;
  Wallet? _opening;
  final _actionsKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !widget.controller.loadingWallets) {
        widget.controller.loadWallets();
      }
    });
  }

  void _showAction(Wallet wallet, String action) {
    setState(() {
      _editing = action == 'details' ? wallet : null;
      _opening = action == 'opening' ? wallet : null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _actionsKey.currentContext;
      if (mounted && target != null) {
        Scrollable.ensureVisible(
          target,
          duration: const Duration(milliseconds: 200),
        );
      }
    });
  }

  Future<void> _handleAction(Wallet wallet, String action) async {
    if (action == 'details' || action == 'opening') {
      _showAction(wallet, action);
      return;
    }
    if (action == 'up' || action == 'down') {
      await widget.controller.moveWallet(wallet, action == 'up' ? -1 : 1);
      return;
    }
    if (action == 'archive') {
      final saved = await widget.controller.setWalletArchived(
        wallet,
        !wallet.isArchived,
      );
      if (mounted && saved) setState(() => _editing = null);
      return;
    }
    if (action == 'delete') {
      final opening = widget.controller.walletBalances[wallet.id]?.opening;
      final openingText = opening != null && opening != BigInt.zero
          ? '\n\nНачальный остаток: ${formatExactMoney(opening, scale: wallet.currencyScale)} ${wallet.currency}. Он будет удалён вместе с кошельком.'
          : '';
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Удалить «${wallet.name}»?'),
          content: Text(
            'Кошелёк будет окончательно удалён из Supabase. Это возможно только при отсутствии связанных расходов, доходов и переводов.$openingText',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Удалить кошелёк'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      final deleted = await widget.controller.deleteWallet(wallet);
      if (!mounted) return;
      if (deleted) {
        setState(() => _editing = null);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Кошелёк «${wallet.name}» удалён.')),
        );
      } else if (widget.controller.deleteFailure ==
          WalletDeleteFailure.linkedHistory) {
        final archive = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Удаление невозможно'),
            content: Text(widget.controller.saveError!),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Закрыть'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Переместить в архив'),
              ),
            ],
          ),
        );
        if (archive == true) await _handleAction(wallet, 'archive');
      }
    }
  }

  Map<String, _CurrencyTotal>? _totals(Iterable<Wallet> wallets) {
    final result = <String, _CurrencyTotal>{};
    for (final wallet in wallets.where((wallet) => !wallet.isArchived)) {
      final balance = widget.controller.walletBalances[wallet.id];
      if (balance == null) return null;
      final previous = result[wallet.currency];
      if (previous == null) {
        result[wallet.currency] = _CurrencyTotal(
          balance.current,
          wallet.currencyScale,
        );
      } else {
        previous.add(balance.current, wallet.currencyScale);
      }
    }
    return result;
  }

  Widget _walletRow(Wallet wallet, {required bool archived}) {
    final balance = widget.controller.walletBalances[wallet.id];
    final amount = widget.controller.isOwner
        ? balance == null
              ? 'Остаток недоступен'
              : '${formatExactMoney(balance.current, scale: wallet.currencyScale)} ${wallet.currency}'
        : 'Остаток скрыт';
    return Semantics(
      button: true,
      label: '${wallet.name}, $amount',
      child: InkWell(
        onTap: () => _showAction(wallet, 'details'),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              WalletMark(wallet.displayIconId, size: 64),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      wallet.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 2),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        amount,
                        maxLines: 1,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (archived)
                      const Text('В архиве', style: TextStyle(fontSize: 12)),
                  ],
                ),
              ),
              if (widget.controller.isOwner)
                archived
                    ? IconButton(
                        tooltip: 'Восстановить',
                        onPressed: widget.controller.saving
                            ? null
                            : () => _handleAction(wallet, 'archive'),
                        icon: const Icon(Icons.unarchive_outlined),
                      )
                    : PopupMenuButton<String>(
                        tooltip: 'Действия с кошельком',
                        onSelected: (action) => _handleAction(wallet, action),
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: 'details',
                            child: Text('Редактировать реквизиты'),
                          ),
                          PopupMenuItem(
                            value: 'opening',
                            child: Text('Начальный остаток'),
                          ),
                          PopupMenuItem(
                            value: 'up',
                            child: Text('Переместить выше'),
                          ),
                          PopupMenuItem(
                            value: 'down',
                            child: Text('Переместить ниже'),
                          ),
                          PopupMenuItem(
                            value: 'archive',
                            child: Text('Переместить в архив'),
                          ),
                          PopupMenuDivider(),
                          PopupMenuItem(
                            value: 'delete',
                            child: Text('Удалить кошелёк'),
                          ),
                        ],
                      ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _groupCard(WalletGroup group) {
    final state = widget.controller;
    final wallets = state.wallets
        .where((wallet) => wallet.group == group && !wallet.isArchived)
        .toList();
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(group.label, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            if (wallets.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: Text('Кошельков пока нет')),
              )
            else
              for (var index = 0; index < wallets.length; index++) ...[
                if (index > 0) const Divider(height: 1),
                _walletRow(wallets[index], archived: false),
              ],
            if (state.isOwner)
              _WalletTotalsBlock(
                title: switch (group) {
                  WalletGroup.cash => 'Итого наличные',
                  WalletGroup.bankAccount => 'Итого по счетам',
                  WalletGroup.card => 'Итого по картам',
                },
                totals: _totals(wallets),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.controller;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            if (state.isOwner && !_adding)
              FilledButton.icon(
                onPressed: state.saving
                    ? null
                    : () => setState(() => _adding = true),
                icon: const Icon(Icons.add),
                label: const Text('Добавить кошелёк'),
              ),
            OutlinedButton.icon(
              onPressed: state.loadingWallets ? null : state.loadWallets,
              icon: const Icon(Icons.refresh),
              label: const Text('Обновить кошельки'),
            ),
            OutlinedButton.icon(
              onPressed: () => setState(() => _showArchive = !_showArchive),
              icon: const Icon(Icons.inventory_2_outlined),
              label: Text(
                'Архив кошельков (${state.wallets.where((wallet) => wallet.isArchived).length})',
              ),
            ),
          ],
        ),
        if (state.saveError != null) ...[
          const SizedBox(height: 12),
          MaterialBanner(
            content: Text(state.saveError!),
            actions: [
              TextButton(
                onPressed: state.loadWallets,
                child: const Text('Обновить'),
              ),
            ],
          ),
        ],
        if (_adding && state.isOwner) ...[
          const SizedBox(height: 16),
          WalletForm(
            controller: state,
            close: () {
              if (mounted) setState(() => _adding = false);
            },
          ),
        ],
        SizedBox(key: _actionsKey),
        if (_editing != null)
          state.isOwner
              ? WalletDetailsForm(
                  key: ValueKey(_editing!.id),
                  wallet: _editing!,
                  controller: state,
                  close: () => setState(() => _editing = null),
                  archive: () => _handleAction(_editing!, 'archive'),
                  delete: () => _handleAction(_editing!, 'delete'),
                )
              : WalletReadOnlyDetails(
                  wallet: _editing!,
                  close: () => setState(() => _editing = null),
                ),
        if (_opening != null && state.isOwner)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(_opening!.name),
                  OpeningBalancePanel(
                    key: ValueKey(_opening!.id),
                    wallet: _opening!,
                    repository: state.repository,
                  ),
                  TextButton(
                    onPressed: () {
                      setState(() => _opening = null);
                      state.loadWallets();
                    },
                    child: const Text('Закрыть'),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 16),
        if (state.loadingWallets)
          const Center(
            child: CircularProgressIndicator(
              semanticsLabel: 'Загрузка кошельков',
            ),
          )
        else if (state.walletsError != null)
          RequestError(message: state.walletsError!, retry: state.loadWallets)
        else if (_opening == null && _editing == null)
          LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 900;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (wide)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (
                          var index = 0;
                          index < WalletGroup.values.length;
                          index++
                        ) ...[
                          if (index > 0) const SizedBox(width: 12),
                          Expanded(
                            child: _groupCard(WalletGroup.values[index]),
                          ),
                        ],
                      ],
                    )
                  else
                    for (final group in WalletGroup.values) ...[
                      _groupCard(group),
                      const SizedBox(height: 12),
                    ],
                  if (state.isOwner)
                    _WalletTotalsBlock(
                      title: 'Всего в кошельках',
                      totals: _totals(state.wallets),
                      prominent: true,
                    ),
                  if (_showArchive)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'Архив кошельков',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 8),
                            if (!state.wallets.any(
                              (wallet) => wallet.isArchived,
                            ))
                              const Text('Архив пуст'),
                            for (final wallet in state.wallets.where(
                              (wallet) => wallet.isArchived,
                            ))
                              _walletRow(wallet, archived: true),
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
      ],
    );
  }
}

class _CurrencyTotal {
  _CurrencyTotal(this.minor, this.scale);
  BigInt minor;
  int scale;

  void add(BigInt value, int valueScale) {
    if (valueScale > scale) {
      minor *= BigInt.from(10).pow(valueScale - scale);
      scale = valueScale;
    }
    minor += value * BigInt.from(10).pow(scale - valueScale);
  }
}

class _WalletTotalsBlock extends StatelessWidget {
  const _WalletTotalsBlock({
    required this.title,
    required this.totals,
    this.prominent = false,
  });
  final String title;
  final Map<String, _CurrencyTotal>? totals;
  final bool prominent;

  @override
  Widget build(BuildContext context) {
    final entries = totals?.entries.toList()
      ?..sort((a, b) => a.key.compareTo(b.key));
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: prominent
            ? Theme.of(context).colorScheme.primaryContainer
            : Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: prominent
                ? Theme.of(context).textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700)
                : Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 6),
          if (entries == null)
            const Text('Не удалось загрузить итог.')
          else if (entries.isEmpty)
            const Text('Нет активных кошельков')
          else
            for (final entry in entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  '${formatExactMoney(entry.value.minor, scale: entry.value.scale)} ${entry.key}',
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    fontWeight: prominent ? FontWeight.w700 : FontWeight.w600,
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

class WalletReadOnlyDetails extends StatelessWidget {
  const WalletReadOnlyDetails({
    required this.wallet,
    required this.close,
    super.key,
  });
  final Wallet wallet;
  final VoidCallback close;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Реквизиты кошелька',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          WalletLabel(wallet, size: 40),
          const SizedBox(height: 12),
          Text('Группа: ${wallet.group.label}'),
          Text('Валюта: ${wallet.currency}'),
          if (wallet.isArchived) const Text('Статус: в архиве'),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: close,
              icon: const Icon(Icons.arrow_back),
              label: const Text('Назад к кошелькам'),
            ),
          ),
        ],
      ),
    ),
  );
}

class WalletForm extends StatefulWidget {
  const WalletForm({required this.controller, required this.close, super.key});
  final FinanceController controller;
  final VoidCallback close;
  @override
  State<WalletForm> createState() => _WalletFormState();
}

class WalletDetailsForm extends StatefulWidget {
  const WalletDetailsForm({
    required this.wallet,
    required this.controller,
    required this.close,
    required this.archive,
    required this.delete,
    super.key,
  });
  final Wallet wallet;
  final FinanceController controller;
  final VoidCallback close;
  final VoidCallback archive;
  final VoidCallback delete;
  @override
  State<WalletDetailsForm> createState() => _WalletDetailsFormState();
}

class _WalletDetailsFormState extends State<WalletDetailsForm> {
  late final _name = TextEditingController(text: widget.wallet.name);
  late WalletGroup _group = widget.wallet.group;
  late String _iconId = widget.wallet.displayIconId;
  final _form = GlobalKey<FormState>();
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Реквизиты кошелька',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _name,
              enabled: !widget.controller.saving,
              decoration: InputDecoration(
                labelText: 'Название',
                prefixIcon: WalletMark(_iconId),
              ),
              validator: (value) =>
                  (value ?? '').trim().isEmpty ||
                      value!.trim().runes.length > 100
                  ? 'Название: от 1 до 100 символов.'
                  : null,
            ),
            const SizedBox(height: 12),
            WalletIconField(
              value: _iconId,
              onChanged: widget.controller.saving
                  ? null
                  : (id) => setState(() => _iconId = id),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<WalletGroup>(
              initialValue: _group,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Группа'),
              items: [
                for (final g in WalletGroup.values)
                  DropdownMenuItem(value: g, child: Text(g.label)),
              ],
              onChanged: widget.controller.saving
                  ? null
                  : (g) => setState(() => _group = g!),
            ),
            const SizedBox(height: 12),
            Text('Валюта: ${widget.wallet.currency}'),
            if (widget.controller.saveError != null)
              Text(widget.controller.saveError!),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  onPressed: widget.controller.saving
                      ? null
                      : () async {
                          if (!_form.currentState!.validate()) return;
                          final saved = await widget.controller.editWallet(
                            widget.wallet,
                            _name.text,
                            _group,
                            iconId: _iconId,
                          );
                          if (mounted && saved) widget.close();
                        },
                  child: const Text('Сохранить реквизиты'),
                ),
                TextButton(
                  onPressed: widget.controller.saving ? null : widget.close,
                  child: const Text('Назад к кошелькам'),
                ),
                OutlinedButton.icon(
                  onPressed: widget.controller.saving ? null : widget.archive,
                  icon: Icon(
                    widget.wallet.isArchived
                        ? Icons.unarchive_outlined
                        : Icons.inventory_2_outlined,
                  ),
                  label: Text(
                    widget.wallet.isArchived
                        ? 'Восстановить'
                        : 'Переместить в архив',
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: widget.controller.saving ? null : widget.delete,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Удалить кошелёк'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class _WalletFormState extends State<WalletForm> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  WalletGroup _group = WalletGroup.cash;
  String _currency = 'RUB';
  String _iconId = 'cash';

  Future<void> _save() async {
    if (widget.controller.saving || !_form.currentState!.validate()) return;
    final saved = await widget.controller.createWallet(
      _name.text,
      _group,
      _currency,
      iconId: _iconId,
    );
    if (mounted && saved) widget.close();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.controller;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Новый кошелёк',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _name,
                enabled: !state.saving,
                decoration: InputDecoration(
                  labelText: 'Название',
                  border: const OutlineInputBorder(),
                  prefixIcon: WalletMark(_iconId),
                ),
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _save(),
                validator: (value) {
                  final name = (value ?? '').trim();
                  if (name.isEmpty) return 'Введите название кошелька.';
                  if (name.runes.length > 100) {
                    return 'Название — не более 100 символов.';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              WalletIconField(
                value: _iconId,
                onChanged: state.saving
                    ? null
                    : (id) => setState(() => _iconId = id),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<WalletGroup>(
                initialValue: _group,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Группа',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final group in WalletGroup.values)
                    DropdownMenuItem(value: group, child: Text(group.label)),
                ],
                onChanged: state.saving
                    ? null
                    : (group) => setState(() => _group = group!),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _currency,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Валюта',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final currency in walletCurrencies)
                    DropdownMenuItem(
                      value: currency,
                      child: Text(currencyLabel(currency)),
                    ),
                ],
                onChanged: state.saving
                    ? null
                    : (currency) => setState(() => _currency = currency!),
              ),
              if (state.saveError != null) ...[
                const SizedBox(height: 16),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    state.saveError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  FilledButton(
                    onPressed: state.saving ? null : _save,
                    child: Text(state.saving ? 'Сохраняем…' : 'Сохранить'),
                  ),
                  TextButton(
                    onPressed: state.saving ? null : widget.close,
                    child: const Text('Отмена'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
