import 'package:flutter/material.dart';

import 'backup_service.dart';
import 'expense.dart';

class BackupsScreen extends StatefulWidget {
  const BackupsScreen({
    required this.service,
    required this.onRestored,
    super.key,
  });
  final BackupService service;
  final VoidCallback onRestored;
  @override
  State<BackupsScreen> createState() => _BackupsScreenState();
}

class _BackupsScreenState extends State<BackupsScreen> {
  Map<String, dynamic>? _status;
  List<dynamic> _history = [];
  String? _error;
  bool _busy = false;
  final _comment = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!widget.service.configured) return;
    await _run(() async {
      final status = await widget.service.request('/status');
      final history = await widget.service.request('/history');
      if (mounted) {
        setState(() {
          _status = Map<String, dynamic>.from(status as Map);
          _history = history as List;
        });
      }
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error.toString().replaceFirst('Bad state: ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(
    String title,
    String description,
    String button,
  ) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(child: Text(description)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(button),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _restore(Map<String, dynamic> preview) async {
    final counts = (preview['counts'] as Map).entries
        .map((e) => '${e.key}: ${e.value}')
        .join('\n');
    if (!await _confirm(
      'Восстановить выбранную копию?',
      '${backupLocalTime(preview['captured_at'] as String)} · Asia/Qyzylorda\n'
          'Пространства: ${(preview['scope'] as List).join(', ')}\n$counts\n'
          'Оригиналов: ${preview['files']}\n${preview['warning']}\n'
          'Перед заменой сервер сохранит и проверит текущее состояние.',
      'Восстановить',
    )) {
      return;
    }
    await widget.service.restore(preview['id'] as String);
    if (!mounted) return;
    widget.onRestored();
  }

  Future<void> _refresh() async {
    final status = await widget.service.request('/status');
    final history = await widget.service.request('/history');
    if (mounted) {
      setState(() {
        _status = Map<String, dynamic>.from(status as Map);
        _history = history as List;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final jobs = (_status?['jobs'] as List?) ?? [];
    const types = {
      'manual': 'Ручная',
      'daily': 'Ежедневная',
      'before': 'Перед изменением',
      'restore': 'Перед восстановлением',
    };
    const states = {
      'queued': 'В очереди',
      'running': 'Создаётся',
      'ready': 'Готова',
      'failed': 'Ошибка',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Резервные копии',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        Text(
          widget.service.configured
              ? 'Ежедневное сохранение: 23:59 Asia/Qyzylorda. Хранилище: ${_status?['storage'] ?? 'проверяется'}.'
              : 'Сервер резервирования не подключён. Автоматические копии, экспорт и восстановление пока недоступны.',
        ),
        if (_status != null) ...[
          Text(
            'Последняя готовая: ${backupLocalTime((_status!['last_ready'] as Map?)?['captured_at'] as String?)}',
          ),
          Text(
            'Следующий запуск: ${backupLocalTime(_status!['next_run'] as String?)} · Asia/Qyzylorda',
          ),
          if (_status!['independent'] != true)
            const Text(
              'Независимое хранилище не подтверждено.',
              style: TextStyle(color: Colors.deepOrange),
            ),
          if (_status!['stale'] == true)
            const Text(
              'Успешная копия отсутствует или просрочена.',
              style: TextStyle(color: Colors.deepOrange),
            ),
          if (_status!['error'] != null) Text('${_status!['error']}'),
        ],
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (_busy) const LinearProgressIndicator(),
        const SizedBox(height: 12),
        TextField(
          controller: _comment,
          maxLength: 1000,
          decoration: const InputDecoration(
            labelText: 'Комментарий к ручной копии (необязательно)',
          ),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              icon: const Icon(Icons.save_outlined),
              label: const Text('Сохранить сейчас'),
              onPressed: _busy || !widget.service.configured
                  ? null
                  : () => _run(() async {
                      await widget.service.request(
                        '/capture',
                        body: {
                          'request_id': newExpenseRequestId(),
                          'kind': 'manual',
                          'comment': _comment.text.trim(),
                        },
                      );
                      _comment.clear();
                      await _refresh();
                    }),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.upload_file),
              label: const Text('Восстановить из файла'),
              onPressed: _busy || !widget.service.configured
                  ? null
                  : () => _run(() async {
                      final preview = await widget.service.importFile();
                      if (preview != null) await _restore(preview);
                      await _refresh();
                    }),
            ),
            TextButton(
              onPressed: _busy ? null : _load,
              child: const Text('Обновить'),
            ),
          ],
        ),
        const SizedBox(height: 20),
        for (final raw in jobs)
          Builder(
            builder: (context) {
              final job = Map<String, dynamic>.from(raw as Map);
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${backupLocalTime(job['captured_at'] as String)} · ${types[job['kind']] ?? job['kind']} · ${states[job['state']] ?? job['state']}',
                      ),
                      if (job['comment'] != '') Text('${job['comment']}'),
                      Text(
                        'Новые данные: ${backupSize(job['new_bytes'] as num?)} · Полный экспорт ≈ ${backupSize(job['export_bytes'] as num?)}',
                      ),
                      if (job['error'] != null) Text('${job['error']}'),
                      Wrap(
                        spacing: 8,
                        children: [
                          TextButton(
                            onPressed: _busy || job['state'] != 'ready'
                                ? null
                                : () =>
                                      _run(() => widget.service.download(job)),
                            child: const Text('Скачать'),
                          ),
                          TextButton(
                            onPressed: _busy || job['state'] != 'ready'
                                ? null
                                : () => _run(() async {
                                    final preview = await widget.service
                                        .request(
                                          '/backups/${job['id']}/preview',
                                        );
                                    await _restore(
                                      Map<String, dynamic>.from(preview as Map),
                                    );
                                    await _refresh();
                                  }),
                            child: const Text('Восстановить'),
                          ),
                          if (job['kind'] == 'manual')
                            TextButton(
                              onPressed: _busy
                                  ? null
                                  : () => _run(() async {
                                      if (!await _confirm(
                                        'Удалить ручную копию?',
                                        '${backupLocalTime(job['captured_at'] as String)}\nРабочие данные сохранятся. Последнюю готовую копию удалить нельзя.',
                                        'Удалить',
                                      )) {
                                        return;
                                      }
                                      await widget.service.request(
                                        '/backups/${job['id']}',
                                        delete: true,
                                      );
                                      await _refresh();
                                    }),
                              child: const Text('Удалить'),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        const SizedBox(height: 20),
        const Text(
          'История изменений · 30 дней',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        for (final raw in _history)
          Builder(
            builder: (context) {
              final entry = raw as Map;
              final changes = entry['changes'] as List;
              return Card(
                child: ExpansionTile(
                  title: Text(
                    '${backupLocalTime(entry['occurred_at'] as String)} · ${changes.length} изменений',
                  ),
                  children: [
                    for (final change in changes)
                      ListTile(
                        title: Text('${change['table']} · ${change['action']}'),
                        subtitle: Text(
                          '${(change['after'] ?? change['before'])?['name'] ?? change['object_id']}',
                        ),
                      ),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => _run(() async {
                              if (!await _confirm(
                                'Отменить действие?',
                                'Будут отменены все ${changes.length} изменений этого действия. Сервер проверит последующие изменения и зависимости. При конфликте данные сохранятся.',
                                'Отменить действие',
                              )) {
                                return;
                              }
                              await widget.service.undo(
                                entry['operation_id'] as String,
                              );
                              widget.onRestored();
                              await _refresh();
                            }),
                      child: const Text('Отменить действие'),
                    ),
                  ],
                ),
              );
            },
          ),
        const SizedBox(height: 16),
        const Text(
          'Версии программы сохраняются отдельно. Этот раздел восстанавливает финансовые данные и изображения; возврат версии программы выполняется администратором.',
        ),
      ],
    );
  }
}
