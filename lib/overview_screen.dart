import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'finance_repository.dart';
import 'money.dart';
import 'wallet_icons.dart';
import 'wallets_screen.dart' show RequestError;

class OverviewScreen extends StatefulWidget {
  const OverviewScreen({
    required this.spaces,
    required this.isOwner,
    required this.repository,
    required this.openWallets,
    super.key,
  });

  final List<FinanceSpace> spaces;
  final bool isOwner;
  final FinanceRepository repository;
  final VoidCallback openWallets;

  @override
  State<OverviewScreen> createState() => _OverviewScreenState();
}

class _OverviewScreenState extends State<OverviewScreen> {
  final _personalScroll = ScrollController();
  final _businessScroll = ScrollController();
  final Map<String, SpaceBalances> _data = {};
  bool _loading = true;
  String? _error;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    if (widget.isOwner) _load();
  }

  @override
  void didUpdateWidget(covariant OverviewScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldIds = oldWidget.spaces.map((space) => space.id).join('|');
    final newIds = widget.spaces.map((space) => space.id).join('|');
    if (oldWidget.isOwner != widget.isOwner || oldIds != newIds) {
      if (widget.isOwner) _load();
    }
  }

  @override
  void dispose() {
    _request++;
    _personalScroll.dispose();
    _businessScroll.dispose();
    super.dispose();
  }

  FinanceSpace? _space(String kind) =>
      widget.spaces.where((space) => space.kind == kind).firstOrNull;

  Future<void> _load() async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
      _data.clear();
    });
    try {
      final targetSpaces = [?_space('personal'), ?_space('business')];
      final results = await Future.wait([
        for (final space in targetSpaces)
          widget.repository.loadSpaceBalances(space.id),
      ]);
      if (!mounted || request != _request) return;
      setState(() {
        for (var index = 0; index < targetSpaces.length; index++) {
          _data[targetSpaces[index].id] = results[index];
        }
      });
    } catch (error) {
      if (mounted && request == _request) {
        setState(() => _error = financeError(error));
      }
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isOwner) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Вам доступны назначенные кошельки и собственные бизнес-расходы.',
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: widget.openWallets,
            icon: const Icon(Icons.account_balance_wallet_outlined),
            label: const Text('Перейти к кошелькам'),
          ),
        ],
      );
    }

    final personal = _space('personal');
    final business = _space('business');
    final personalData = personal == null ? null : _data[personal.id];
    final businessData = business == null ? null : _data[business.id];
    final combined = _MoneyTotals()
      ..addTotals(_totals(personalData))
      ..addTotals(_totals(businessData));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Текущие учётные остатки',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 2),
        const Text(
          'Начальные остатки + доходы − расходы + входящие переводы − исходящие переводы. Архивные кошельки не учитываются.',
        ),
        if (_loading) ...[
          const SizedBox(height: 8),
          const LinearProgressIndicator(),
        ],
        if (_error != null) ...[
          const SizedBox(height: 8),
          RequestError(message: _error!, retry: _load),
        ],
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final tables = [
              _WalletBalanceTable(
                title: 'Личные финансы',
                data: personalData,
                loading: _loading,
                scrollController: _personalScroll,
                totalLabel: 'Итого личные финансы',
              ),
              _WalletBalanceTable(
                title: 'Бизнес',
                data: businessData,
                loading: _loading,
                scrollController: _businessScroll,
                totalLabel: 'Итого бизнес',
              ),
            ];
            if (constraints.maxWidth >= 760) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: tables[0]),
                  const SizedBox(width: 12),
                  Expanded(child: tables[1]),
                ],
              );
            }
            return Column(
              children: [tables[0], const SizedBox(height: 12), tables[1]],
            );
          },
        ),
        const SizedBox(height: 12),
        _CombinedTotal(totals: combined),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh),
              label: const Text('Обновить обзор'),
            ),
            FilledButton.icon(
              onPressed: widget.openWallets,
              icon: const Icon(Icons.account_balance_wallet_outlined),
              label: const Text('Перейти к кошелькам'),
            ),
          ],
        ),
      ],
    );
  }
}

class _WalletBalanceTable extends StatelessWidget {
  const _WalletBalanceTable({
    required this.title,
    required this.data,
    required this.loading,
    required this.scrollController,
    required this.totalLabel,
  });

  final String title;
  final SpaceBalances? data;
  final bool loading;
  final ScrollController scrollController;
  final String totalLabel;

  @override
  Widget build(BuildContext context) {
    final wallets = data == null
        ? <Wallet>[]
        : (data!.wallets.where((wallet) => !wallet.isArchived).toList()
            ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder)));
    final totals = _totals(data);
    final listHeight = math.min(420.0, math.max(72.0, wallets.length * 58.0));

    return Card(
      key: ValueKey('overview-table:$title'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            const _TableHeader(),
            const Divider(height: 8),
            if (!loading && wallets.isEmpty)
              const SizedBox(
                height: 72,
                child: Center(child: Text('Активных кошельков нет')),
              )
            else
              SizedBox(
                height: listHeight,
                child: Scrollbar(
                  controller: scrollController,
                  thumbVisibility: wallets.length * 58 > listHeight,
                  trackVisibility: wallets.length * 58 > listHeight,
                  child: ListView.separated(
                    controller: scrollController,
                    primary: false,
                    padding: const EdgeInsets.only(right: 10),
                    itemCount: wallets.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final wallet = wallets[index];
                      final balance =
                          data!.balances[wallet.id]?.current ?? BigInt.zero;
                      return _WalletBalanceRow(
                        wallet: wallet,
                        balance: balance,
                      );
                    },
                  ),
                ),
              ),
            const Divider(height: 12),
            _TotalsBlock(label: totalLabel, totals: totals),
          ],
        ),
      ),
    );
  }
}

class _TableHeader extends StatelessWidget {
  const _TableHeader();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(horizontal: 4),
    child: Row(
      children: [
        Expanded(
          child: Text('Кошелёк', style: TextStyle(fontWeight: FontWeight.w600)),
        ),
        Text('Остаток', style: TextStyle(fontWeight: FontWeight.w600)),
      ],
    ),
  );
}

class _WalletBalanceRow extends StatelessWidget {
  const _WalletBalanceRow({required this.wallet, required this.balance});

  final Wallet wallet;
  final BigInt balance;

  @override
  Widget build(BuildContext context) {
    final amount =
        '${formatExactMoney(balance, scale: wallet.currencyScale)} ${wallet.currency}';
    return Semantics(
      key: ValueKey('overview-wallet:${wallet.id}'),
      label: '${wallet.name}, $amount',
      child: SizedBox(
        height: 57,
        child: Row(
          children: [
            WalletMark(wallet.displayIconId, size: 46),
            const SizedBox(width: 8),
            Expanded(
              child: Tooltip(
                message: wallet.name,
                child: Text(
                  wallet.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 180),
              child: Tooltip(
                message: amount,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text(
                    amount,
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TotalsBlock extends StatelessWidget {
  const _TotalsBlock({required this.label, required this.totals});

  final String label;
  final _MoneyTotals totals;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
      const SizedBox(height: 4),
      if (totals.amounts.isEmpty)
        const Text('0,00', style: TextStyle(fontWeight: FontWeight.w700))
      else
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 12,
          runSpacing: 2,
          children: [
            for (final currency in totals.currencies)
              Text(
                totals.formatted(currency),
                key: ValueKey('$label:$currency'),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
          ],
        ),
    ],
  );
}

class _CombinedTotal extends StatelessWidget {
  const _CombinedTotal({required this.totals});

  final _MoneyTotals totals;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    color: Theme.of(context).colorScheme.primaryContainer,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Всего средств',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: totals.amounts.isEmpty
                ? const Text(
                    '0,00',
                    textAlign: TextAlign.right,
                    style: TextStyle(fontWeight: FontWeight.w700),
                  )
                : Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 14,
                    runSpacing: 2,
                    children: [
                      for (final currency in totals.currencies)
                        Text(
                          totals.formatted(currency),
                          key: ValueKey('Всего средств:$currency'),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    ),
  );
}

_MoneyTotals _totals(SpaceBalances? data) {
  final totals = _MoneyTotals();
  if (data == null) return totals;
  for (final wallet in data.wallets.where((wallet) => !wallet.isArchived)) {
    totals.add(
      wallet.currency,
      wallet.currencyScale,
      data.balances[wallet.id]?.current ?? BigInt.zero,
    );
  }
  return totals;
}

class _MoneyTotals {
  final Map<String, BigInt> amounts = {};
  final Map<String, int> scales = {};

  Iterable<String> get currencies sync* {
    for (final currency in walletCurrencies) {
      if (amounts.containsKey(currency)) yield currency;
    }
    final other =
        amounts.keys
            .where((currency) => !walletCurrencies.contains(currency))
            .toList()
          ..sort();
    yield* other;
  }

  void add(String currency, int scale, BigInt amount) {
    final previousScale = scales[currency] ?? scale;
    final targetScale = math.max(previousScale, scale);
    amounts[currency] =
        (amounts[currency] ?? BigInt.zero) *
            BigInt.from(10).pow(targetScale - previousScale) +
        amount * BigInt.from(10).pow(targetScale - scale);
    scales[currency] = targetScale;
  }

  void addTotals(_MoneyTotals other) {
    for (final currency in other.amounts.keys) {
      add(currency, other.scales[currency]!, other.amounts[currency]!);
    }
  }

  String formatted(String currency) =>
      '${formatExactMoney(amounts[currency]!, scale: scales[currency]!)} $currency';
}
