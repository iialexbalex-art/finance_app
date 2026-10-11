import 'package:flutter/material.dart';

import 'expense.dart';
import 'finance_repository.dart';
import 'money.dart';

class CurrentBalancePanel extends StatefulWidget {
  const CurrentBalancePanel({
    required this.wallet,
    required this.repository,
    this.compact = false,
    super.key,
  });
  final Wallet wallet;
  final FinanceRepository repository;
  final bool compact;
  @override
  State<CurrentBalancePanel> createState() => _CurrentBalancePanelState();
}

class _CurrentBalancePanelState extends State<CurrentBalancePanel> {
  WalletExpenseBalance? _balance;
  bool _loading = true;
  String? _error;
  int _request = 0;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
      _balance = null;
    });
    try {
      final balance = await widget.repository.loadExpenseBalance(
        widget.wallet.id,
      );
      if (!mounted || request != _request) return;
      setState(() => _balance = balance);
    } catch (error) {
      if (mounted && request == _request) {
        setState(() => _error = financeError(error));
      }
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (_loading) const Text('Текущий остаток: загрузка…'),
      if (_balance != null) ...[
        if (widget.compact) ...[
          const Text('Текущий остаток'),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              '${formatExactMoney(_balance!.current, scale: widget.wallet.currencyScale)} ${widget.wallet.currency}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ] else
          Text(
            'Текущий остаток: ${formatExactMoney(_balance!.current, scale: widget.wallet.currencyScale)} ${widget.wallet.currency}',
          ),
        if (_balance!.opening == null)
          const Text('Начальный остаток не задан; в расчёте принят 0.'),
      ],
      if (_error != null) ...[
        Text(_error!),
        TextButton(
          onPressed: _load,
          child: const Text('Обновить текущий остаток'),
        ),
      ],
    ],
  );
}
