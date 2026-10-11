import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:finance_app/wallet_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'expense_filters_test.dart' show capture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'wallet photo registry has exact groups, unique IDs and local assets',
    () async {
      expect(walletPhotoCatalog.length, 113);
      expect(bankIconCatalog.length, 9);
      expect(
        walletPhotoGeneratedCatalog.where((c) => c.kind == 'Карта').length,
        37,
      );
      expect(
        walletPhotoGeneratedCatalog.where((c) => c.kind == 'Портмоне').length,
        12,
      );
      expect(
        walletPhotoGeneratedCatalog
            .where((c) => c.group == 'Счета и депозиты')
            .length,
        28,
      );
      expect(
        walletPhotoGeneratedCatalog
            .where((c) => c.group == 'Сейфы и наличные')
            .length,
        12,
      );
      expect(walletPhotoCatalog.map((c) => c.id).toSet().length, 113);
      expect(walletPhotoCatalog.map((c) => c.asset).toSet().length, 113);

      for (final choice in walletPhotoGeneratedCatalog) {
        expect(choice.id, matches(RegExp(r'^[a-z][a-z0-9_]{0,47}$')));
        expect(choice.asset, startsWith('assets/wallet_photoreal/'));
        final bytes = (await rootBundle.load(choice.asset)).buffer
            .asUint8List();
        expect(bytes.length, greaterThan(1000), reason: choice.id);
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        expect(
          frame.image.width,
          greaterThanOrEqualTo(1254),
          reason: choice.id,
        );
        expect(
          frame.image.height,
          greaterThanOrEqualTo(992),
          reason: choice.id,
        );
        frame.image.dispose();
        codec.dispose();

        final master = File(
          'source_assets/wallet_photoreal/master/${choice.id}.png',
        );
        expect(master.existsSync(), isTrue, reason: choice.id);
        final masterCodec = await ui.instantiateImageCodec(
          master.readAsBytesSync(),
        );
        final masterFrame = await masterCodec.getNextFrame();
        expect(masterFrame.image.width, 2400, reason: choice.id);
        expect(masterFrame.image.height, 2400, reason: choice.id);
        masterFrame.image.dispose();
        masterCodec.dispose();
      }

      final registry = jsonDecode(
        File('assets/wallet_photoreal/registry.json').readAsStringSync(),
      ) as List<dynamic>;
      expect(registry.length, 98);
      expect(registry.map((e) => e['icon_id']).toSet().length, 98);
      expect(registry.map((e) => e['sha256']).toSet().length, 98);
      expect(
        matchesIcon(
          walletPhotoCatalog.firstWhere((c) => c.id == 'card_kaspi_gold'),
          'Kaspi золотистая карта',
        ),
        isTrue,
      );
      expect(resolveWalletIcon('cash').id, 'cash');
      expect(resolveWalletIcon('unknown').id, 'wallet');
    },
  );

  testWidgets('narrow picker filters by bank and type without overflow', (
    t,
  ) async {
    t.view.physicalSize = const Size(320, 568);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: RepaintBoundary(
            key: ValueKey('capture'),
            child: WalletIconPicker(selected: 'bank_sber'),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.byType(GridView), findsOneWidget);
    expect(t.takeException(), isNull);

    final dropdowns = find.byType(DropdownButtonFormField<String>);
    expect(dropdowns, findsNWidgets(2));
    await t.tap(dropdowns.first);
    await t.pumpAndSettle();
    await t.tap(find.text('Сбер').last);
    await t.pumpAndSettle();
    await t.tap(dropdowns.last);
    await t.pumpAndSettle();
    await t.tap(find.text('Карта').last);
    await t.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('choose-icon:card_sber_green')),
      findsWidgets,
    );
    expect(find.textContaining('Альфа-Банк —'), findsNothing);
    await capture(t, 'wallet-card-picker-320');
    expect(t.takeException(), isNull);
  });

  testWidgets('desktop card picker uses large card thumbnails', (t) async {
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: RepaintBoundary(
            key: ValueKey('capture'),
            child: WalletIconPicker(selected: 'card_sber_green'),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(ChoiceChip, 'Банковские карты'));
    await t.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('choose-icon:card_sber_green_hq_v1')),
      findsWidgets,
    );
    await capture(t, 'wallet-card-picker-1440');
    expect(t.takeException(), isNull);
  });

  testWidgets('mark always decodes the full original resource', (t) async {
    final choice = walletPhotoCatalog.firstWhere(
      (c) => c.id == 'card_sber_green',
    );
    await t.pumpWidget(
      MaterialApp(
        home: Row(
          children: [
            CatalogMark(choice, size: 32),
            CatalogMark(choice, size: 64),
            CatalogMark(choice, size: 80),
          ],
        ),
      ),
    );
    await t.pumpAndSettle();
    final assets = t.widgetList<Image>(find.byType(Image)).map((image) {
      final provider = image.image;
      return switch (provider) {
        AssetImage(:final assetName) => assetName,
        ResizeImage(:final imageProvider) =>
          (imageProvider as AssetImage).assetName,
        _ => throw StateError('Unexpected provider: $provider'),
      };
    }).toList();
    expect(assets, [
      'assets/wallet_photoreal/card_sber_green.png',
      'assets/wallet_photoreal/card_sber_green.png',
      'assets/wallet_photoreal/card_sber_green.png',
    ]);
  });
}
