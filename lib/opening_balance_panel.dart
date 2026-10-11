import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'finance_repository.dart';
import 'money.dart';
import 'current_balance_panel.dart';

// Mounted only for the owner. Keyed by wallet ID under the session/space subtree,
// so switching space or signing out disposes drafts and pending response handlers.
class OpeningBalancePanel extends StatefulWidget {
  const OpeningBalancePanel({
    required this.wallet,
    required this.repository,
    super.key,
  });
  final Wallet wallet;
  final FinanceRepository repository;
  @override
  State<OpeningBalancePanel> createState() => _OpeningBalancePanelState();
}

class _OpeningBalancePanelState extends State<OpeningBalancePanel> {
  final _form = GlobalKey<FormState>();
  final _input = TextEditingController();
  BigInt? _amount;
  bool _loading = true;
  bool _loaded = false;
  bool _editing = false;
  bool _saving = false;
  String? _error;
  int _request = 0;
  int _balanceRevision = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_saving) return;
    final request = ++_request;
    setState(() {
      _loading = true;
      _loaded = false;
      _amount = null;
      _error = null;
      _editing = false;
      _input.clear();
    });
    try {
      final amount = await widget.repository.loadOpeningBalance(
        widget.wallet.id,
      );
      if (!mounted || request != _request) return;
      setState(() {
        _amount = amount;
        _loaded = true;
      });
    } catch (error) {
      if (!mounted || request != _request) return;
      setState(() => _error = _message(error));
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  String _message(Object error) {
    if (error is FormatException) return error.message;
    if (error is PostgrestException &&
        (error.code == '23505' || error.code == 'PGRST116')) {
      return 'Остаток изменён в другой сессии или доступ отозван. Обновите данные перед сохранением.';
    }
    return financeError(error);
  }

  Future<void> _save() async {
    if (_saving || !_loaded || !_form.currentState!.validate()) return;
    final amount = parseMoney(_input.text);
    final request = ++_request;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await widget.repository.saveOpeningBalance(
        widget.wallet.id,
        amount,
        previous: _amount,
      );
      if (!mounted || request != _request) return;
      setState(() {
        _amount = saved;
        _balanceRevision++;
        _editing = false;
        _input.clear();
      });
    } catch (error) {
      if (!mounted || request != _request) return;
      setState(
        () => _error =
            '${_message(error)} При потере ответа сначала обновите остаток: запись могла сохраниться.',
      );
    } finally {
      if (mounted && request == _request) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _request++;
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final supported =
        widget.wallet.currencyScale == 2 &&
        walletCurrencies.contains(widget.wallet.currency);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CurrentBalancePanel(
            key: ValueKey(_balanceRevision),
            wallet: widget.wallet,
            repository: widget.repository,
          ),
          const SizedBox(height: 12),
          const Text('Начальный остаток'),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(
                semanticsLabel: 'Загрузка начального остатка',
              ),
            ),
          if (_loaded)
            Text(
              _amount == null
                  ? 'Не задан'
                  : '${formatMoney(_amount!, scale: widget.wallet.currencyScale)} ${widget.wallet.currency}',
            ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Semantics(
              liveRegion: true,
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
            TextButton(
              onPressed: _saving ? null : _load,
              child: const Text('Обновить остаток'),
            ),
          ],
          if (_loaded && supported && !_editing)
            TextButton(
              onPressed: () => setState(() {
                _input.text = _amount == null ? '' : formatMoney(_amount!);
                _error = null;
                _editing = true;
              }),
              child: Text(
                _amount == null
                    ? 'Задать начальный остаток'
                    : 'Изменить начальный остаток',
              ),
            ),
          if (_loaded && !supported)
            const Text(
              'Изменение доступно для поддерживаемых валют с двумя знаками после разделителя.',
            ),
          if (_editing)
            Form(
              key: _form,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _input,
                    enabled: !_saving,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                      signed: true,
                    ),
                    textInputAction: TextInputAction.done,
                    decoration: InputDecoration(
                      labelText: 'Сумма (${widget.wallet.currency})',
                      border: const OutlineInputBorder(),
                      errorMaxLines: 4,
                    ),
                    onFieldSubmitted: (_) => _save(),
                    validator: (value) {
                      try {
                        parseMoney(value ?? '');
                        return null;
                      } on FormatException catch (error) {
                        return error.message;
                      }
                    },
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton(
                        onPressed: _saving ? null : _save,
                        child: Text(
                          _saving ? 'Сохраняем…' : 'Сохранить остаток',
                        ),
                      ),
                      TextButton(
                        onPressed: _saving
                            ? null
                            : () => setState(() {
                                _editing = false;
                                _input.clear();
                                _error = null;
                              }),
                        child: const Text('Отмена'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
