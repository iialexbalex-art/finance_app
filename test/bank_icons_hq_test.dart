import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:finance_app/wallet_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('all 15 HQ bank images are registered byte-identically', () async {
    final manifest = jsonDecode(
      File('design/bank_icons_hq/asset_manifest.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final sourceRows = manifest['assets'] as List<dynamic>;
    expect(sourceRows, hasLength(15));
    expect(bankIconsHqCatalog, hasLength(15));
    expect(bankIconsHqCatalog.where((c) => c.kind == 'Карта'), hasLength(12));
    expect(
      bankIconsHqCatalog.where((c) => c.kind == 'Копилка'),
      hasLength(3),
    );
    expect(
      bankIconsHqCatalog.where((c) => c.group == 'Банковские карты'),
      hasLength(12),
    );
    expect(
      bankIconsHqCatalog.where((c) => c.group == 'Копилки / Накопления'),
      hasLength(3),
    );
    expect(
      bankIconsHqCatalog.map((c) => c.id).toSet(),
      hasLength(bankIconsHqCatalog.length),
    );
    expect(
      walletPhotoCatalog.map((c) => c.id).toSet(),
      hasLength(walletPhotoCatalog.length),
    );

    for (final row in sourceRows.cast<Map<String, dynamic>>()) {
      final id = row['suggested_icon_id'] as String;
      final choice = bankIconsHqCatalog.singleWhere((c) => c.id == id);
      final source = File('design/bank_icons_hq/${row['relative_path']}');
      final runtime = File(choice.asset);
      expect(runtime.readAsBytesSync(), source.readAsBytesSync(), reason: id);
      final bytes = (await rootBundle.load(choice.asset)).buffer.asUint8List();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, row['width_px'], reason: id);
      expect(frame.image.height, row['height_px'], reason: id);
      frame.image.dispose();
      codec.dispose();
    }
  });

  testWidgets('picker exposes independent cards and all three savings images', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: WalletIconPicker(selected: 'card_sber_green_hq_v1'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ChoiceChip, 'Банковские карты'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('choose-icon:card_sber_green_hq_v1')),
      findsOneWidget,
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Поиск значка'),
      'фиолетовая',
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('choose-icon:card_sber_purple_hq_v1')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('choosing one image returns only its stable ID', (tester) async {
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              selected = await showDialog<String>(
                context: context,
                builder: (_) => const WalletIconPicker(
                  selected: 'savings_sber_piggy_bank_hq_v1',
                ),
              );
            },
            child: const Text('Открыть'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Открыть'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Поиск значка'),
      'Kaspi красная копилка',
    );
    await tester.pumpAndSettle();
    final target = find.byKey(
      const ValueKey('choose-icon:savings_kaspi_piggy_bank_hq_v1'),
    );
    await tester.ensureVisible(target);
    await tester.tap(target);
    await tester.pumpAndSettle();
    expect(selected, 'savings_kaspi_piggy_bank_hq_v1');
  });
}
