import 'package:flutter/material.dart';

import 'finance_repository.dart';
import 'catalog_marks.dart';
export 'catalog_marks.dart';

class WalletLabel extends StatelessWidget {
  const WalletLabel(
    this.wallet, {
    this.currency = false,
    this.size = 32,
    super.key,
  });
  final Wallet? wallet;
  final bool currency;
  final double size;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      WalletMark(wallet?.displayIconId, size: size),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          wallet == null
              ? 'Кошелёк недоступен'
              : '${wallet!.name}${currency ? ' (${wallet!.currency})' : ''}',
          overflow: currency ? TextOverflow.ellipsis : null,
        ),
      ),
    ],
  );
}

class WalletIconField extends StatelessWidget {
  const WalletIconField({
    required this.value,
    required this.onChanged,
    this.category = false,
    super.key,
  });
  final String value;
  final bool category;
  final ValueChanged<String>? onChanged;
  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    icon: CatalogMark(
      category ? resolveCategoryIcon(value) : resolveWalletIcon(value),
    ),
    label: Text(
      'Значок: ${(category ? resolveCategoryIcon(value) : resolveWalletIcon(value)).label}',
    ),
    onPressed: onChanged == null
        ? null
        : () async {
            final result = await showDialog<String>(
              context: context,
              builder: (_) =>
                  WalletIconPicker(selected: value, category: category),
            );
            if (result != null && context.mounted) onChanged?.call(result);
          },
  );
}

class CategoryIconField extends WalletIconField {
  const CategoryIconField({
    required super.value,
    required super.onChanged,
    super.key,
  }) : super(category: true);
}

class WalletIconPicker extends StatefulWidget {
  const WalletIconPicker({
    required this.selected,
    this.category = false,
    super.key,
  });
  final String selected;
  final bool category;
  @override
  State<WalletIconPicker> createState() => _WalletIconPickerState();
}

class _WalletIconPickerState extends State<WalletIconPicker> {
  String _search = '', _group = 'Все';
  String _bank = 'Все банки', _kind = 'Все виды';
  // Legacy category IDs still resolve in existing records, while the picker
  // offers the current curated set only.
  List<WalletIconChoice> get _catalog =>
      widget.category ? photorealCategoryIconCatalog : walletPhotoCatalog;
  WalletIconChoice get _selected => widget.category
      ? resolveCategoryIcon(widget.selected)
      : resolveWalletIcon(widget.selected);
  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(12),
    child: SizedBox(
      width: 640,
      height: (MediaQuery.sizeOf(context).height - 24)
          .clamp(520.0, 760.0)
          .toDouble(),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.category ? 'Значок категории' : 'Значок кошелька',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
                IconButton(
                  tooltip: 'Отмена',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                CatalogMark(_selected, size: widget.category ? 72 : 80),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Выбран: ${_selected.label}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              decoration: const InputDecoration(
                labelText: 'Поиск значка',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (v) =>
                  setState(() => _search = v.toLowerCase().trim()),
            ),
            const SizedBox(height: 8),
            if (!widget.category) ...[
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _bank,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Банк'),
                      items:
                          [
                                'Все банки',
                                ..._catalog
                                    .map((c) => c.bank)
                                    .where((bank) => bank.isNotEmpty)
                                    .toSet(),
                              ]
                              .map(
                                (bank) => DropdownMenuItem(
                                  value: bank,
                                  child: Text(
                                    bank,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              )
                              .toList(),
                      onChanged: (value) =>
                          setState(() => _bank = value ?? 'Все банки'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _kind,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Вид'),
                      items:
                          [
                                'Все виды',
                                ..._catalog
                                    .map((c) => c.kind)
                                    .where((kind) => kind.isNotEmpty)
                                    .toSet(),
                              ]
                              .map(
                                (kind) => DropdownMenuItem(
                                  value: kind,
                                  child: Text(
                                    kind,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              )
                              .toList(),
                      onChanged: (value) =>
                          setState(() => _kind = value ?? 'Все виды'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                spacing: 6,
                children: [
                  for (final group in [
                    'Все',
                    ..._catalog.map((c) => c.group).toSet(),
                  ])
                    ChoiceChip(
                      label: Text(group),
                      selected: _group == group,
                      onSelected: (_) => setState(() => _group = group),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) {
                  final columns = box.maxWidth < 350 ? 2 : 4;
                  final tileWidth =
                      (box.maxWidth - (columns - 1) * 6) / columns;
                  final markSize = widget.category
                      ? 72.0
                      : (tileWidth - 12).clamp(80.0, 128.0).toDouble();
                  final choices = _catalog
                      .where(
                        (c) =>
                            (_group == 'Все' || c.group == _group) &&
                            (widget.category ||
                                _bank == 'Все банки' ||
                                c.bank == _bank) &&
                            (widget.category ||
                                _kind == 'Все виды' ||
                                c.kind == _kind) &&
                            matchesIcon(c, _search),
                      )
                      .toList();
                  if (choices.isEmpty) {
                    return const Center(child: Text('Значки не найдены'));
                  }
                  return GridView.builder(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      mainAxisExtent: widget.category ? 148 : 194,
                      crossAxisSpacing: 6,
                      mainAxisSpacing: 6,
                    ),
                    itemCount: choices.length,
                    itemBuilder: (context, index) {
                      final c = choices[index];
                      return Semantics(
                        selected: c.id == widget.selected,
                        child: InkWell(
                          key: ValueKey('choose-icon:${c.id}'),
                          onTap: () => Navigator.pop(context, c.id),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: c.id == widget.selected
                                  ? Theme.of(context)
                                        .colorScheme
                                        .primaryContainer
                                  : Colors.white,
                              border: Border.all(
                                color: c.id == widget.selected
                                    ? Theme.of(context).colorScheme.primary
                                    : Colors.black12,
                              ),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  CatalogMark(c, size: markSize),
                                  const SizedBox(height: 4),
                                  Text(
                                    c.label,
                                    textAlign: TextAlign.center,
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
