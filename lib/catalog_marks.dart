import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'icon_catalog.dart';
import 'photoreal_icon_catalog.dart';
import 'wallet_photo_catalog.dart';
import 'bank_icons_hq_catalog.dart';
import 'restored_assets.dart';
export 'photoreal_icon_catalog.dart';
export 'wallet_photo_catalog.dart';
export 'bank_icons_hq_catalog.dart';
export 'icon_catalog.dart';

const bankIconCatalog = <WalletIconChoice>[
  WalletIconChoice(
    'bank_sber',
    'Сбербанк',
    'Банки',
    'assets/icons/banks/bank_sber.svg',
    'сбер sber',
    bank: 'Сбер',
    kind: 'Логотип',
  ),
  WalletIconChoice(
    'bank_alfa',
    'Альфа-Банк',
    'Банки',
    'assets/icons/banks/bank_alfa.svg',
    'альфа alfa alpha',
    bank: 'Альфа-Банк',
    kind: 'Логотип',
  ),
  WalletIconChoice(
    'bank_t',
    'Т-Банк / Тинькофф',
    'Банки',
    'assets/icons/banks/bank_t.png',
    'тиньков tinkoff tbank т банк',
    bank: 'Т-Банк / Тинькофф',
    kind: 'Логотип',
  ),
  WalletIconChoice(
    'bank_bakai',
    'Бакай Банк',
    'Банки',
    'assets/icons/banks/bank_bakai.png',
    'bakai бакай',
    bank: 'Бакай Банк',
    kind: 'Логотип',
  ),
  WalletIconChoice(
    'bank_kaspi',
    'Kaspi',
    'Банки',
    'assets/icons/banks/bank_kaspi.svg',
    'каспи каспий',
    bank: 'Kaspi',
    kind: 'Логотип',
  ),
  WalletIconChoice(
    'bank_gpb',
    'Газпромбанк',
    'Банки',
    'assets/icons/banks/bank_gpb.png',
    'гпб gazprombank',
    bank: 'Газпромбанк',
    kind: 'Логотип',
  ),
  WalletIconChoice(
    'bank_rshb',
    'Россельхозбанк',
    'Банки',
    'assets/icons/banks/bank_rshb.png',
    'рсхб rshb',
    bank: 'Россельхозбанк',
    kind: 'Логотип',
  ),
  WalletIconChoice(
    'bank_halyk',
    'Halyk',
    'Банки',
    'assets/icons/banks/bank_halyk.svg',
    'халык народный',
    bank: 'Halyk',
    kind: 'Логотип',
  ),
  WalletIconChoice(
    'bank_bcc',
    'Банк ЦентрКредит',
    'Банки',
    'assets/icons/banks/bank_bcc.png',
    'бцк bcc центр кредит',
    bank: 'Банк ЦентрКредит',
    kind: 'Логотип',
  ),
];
// Compatibility choices share artwork; they are not counted as new images.
final walletPhotoCatalog = <WalletIconChoice>[
  ...bankIconCatalog,
  ...bankIconsHqCatalog,
  ...walletPhotoGeneratedCatalog,
];

// The legacy catalog remains in the resolver so stored icon IDs keep working.
final walletIconCatalog = <WalletIconChoice>[
  ...walletPhotoCatalog,
  ...financialIconCatalog,
  ...categoryIconCatalog
      .where(
        (c) => const {
          'gift',
          'travel',
          'home',
          'car',
          'education',
          'health',
          'phone',
          'globe',
          'shop',
        }.contains(c.id),
      )
      .map((c) => WalletIconChoice(c.id, c.label, 'Цели', c.asset, c.synonyms)),
  const WalletIconChoice(
    'goal',
    'На мечту',
    'Цели',
    'assets/icons/travel.svg',
    'цель накопления',
  ),
];
WalletIconChoice resolveWalletIcon(String? id) =>
    walletIconCatalog.where((c) => c.id == id).firstOrNull ??
    financialIconCatalog.firstWhere((c) => c.id == 'wallet');
WalletIconChoice resolveCategoryIcon(String? id) =>
    photorealCategoryIconCatalog.where((c) => c.id == id).firstOrNull ??
    categoryIconCatalog.where((c) => c.id == id).firstOrNull ??
    categoryIconCatalog.first;
String _normalize(String s) => s.toLowerCase().replaceAll('ё', 'е').trim();
bool matchesIcon(WalletIconChoice c, String query) => _normalize(query)
    .split(RegExp(r'\s+'))
    .every(
      _normalize('${c.label} ${c.synonyms} ${c.group} ${c.bank} ${c.kind}')
          .contains,
    );

class CatalogMark extends StatelessWidget {
  const CatalogMark(this.choice, {this.size = 32, super.key});
  final WalletIconChoice choice;
  final double size;

  @override
  Widget build(BuildContext context) {
    final asset = choice.asset;
    final decodedWidth = (size * MediaQuery.devicePixelRatioOf(context)).ceil();
    return Semantics(
      label: 'Значок: ${choice.label}',
      image: true,
      child: SizedBox.square(
        dimension: size,
        child: ListenableBuilder(
          listenable: RestoredAssets.instance,
          builder: (context, _) {
            if (RestoredAssets.instance.contains(asset)) {
              return FutureBuilder(
                future: RestoredAssets.instance.bytes(asset),
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return const Icon(Icons.broken_image_outlined);
                  }
                  if (!snapshot.hasData) return const SizedBox.shrink();
                  return asset.endsWith('.svg')
                      ? SvgPicture.memory(snapshot.data!, fit: BoxFit.contain)
                      : Image.memory(
                          snapshot.data!,
                          fit: BoxFit.contain,
                          filterQuality: FilterQuality.high,
                          cacheWidth: decodedWidth,
                        );
                },
              );
            }
            return asset.endsWith('.svg')
                ? SvgPicture.asset(asset, fit: BoxFit.contain)
                : Image.asset(
                    asset,
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.high,
                    cacheWidth: decodedWidth,
                  );
          },
        ),
      ),
    );
  }
}

class WalletMark extends StatelessWidget {
  const WalletMark(this.id, {this.size = 32, super.key});
  final String? id;
  final double size;
  @override
  Widget build(BuildContext context) =>
      CatalogMark(resolveWalletIcon(id), size: size);
}

class CategoryMark extends StatelessWidget {
  const CategoryMark(this.id, {this.size = 32, super.key});
  final String? id;
  final double size;
  @override
  Widget build(BuildContext context) =>
      CatalogMark(resolveCategoryIcon(id), size: size);
}

class CategoryLabel extends StatelessWidget {
  const CategoryLabel(this.id, this.label, {super.key});
  final String? id;
  final String label;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      CategoryMark(id),
      const SizedBox(width: 8),
      Expanded(child: Text(label)),
    ],
  );
}
