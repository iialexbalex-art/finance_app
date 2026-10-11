import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:finance_app/wallet_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (const bool.fromEnvironment('CAPTURE_QA')) {
      await (FontLoader('Roboto')..addFont(
            File('C:/Windows/Fonts/arial.ttf')
                .readAsBytes()
                .then(ByteData.sublistView),
          ))
          .load();
    }
  });
  test(
    '100 distinct local illustrations, stable IDs, bank sources and aliases',
    () async {
      final all = [
        ...categoryIconCatalog,
        ...financialIconCatalog,
        ...bankIconCatalog,
      ];
      expect(categoryIconCatalog.length, 80);
      expect(financialIconCatalog.length, 20);
      expect(all.map((c) => c.id).toSet().length, 109);
      expect(all.map((c) => c.asset).toSet().length, 109);
      final signatures = <String>{};
      for (final c in all) {
        expect(c.id, matches(RegExp(r'^[a-z][a-z0-9_]{0,47}$')));
        final data = await rootBundle.load(c.asset);
        expect(data.lengthInBytes, greaterThan(100), reason: c.id);
        signatures.add(base64Encode(data.buffer.asUint8List()));
        if (c.asset.endsWith('.svg')) {
          final svg = utf8.decode(data.buffer.asUint8List());
          expect(svg, isNot(contains('<script')), reason: c.id);
          expect(
            svg,
            isNot(matches(RegExp(r'''(?:href|src)=["']https?://'''))),
            reason: c.id,
          );
        }
      }
      expect(signatures.length, 109);
      for (final id in [
        'bank_sber',
        'bank_alfa',
        'bank_t',
        'bank_bakai',
        'bank_kaspi',
        'cash',
        'banknote',
        'coins',
        'wallet',
        'purse',
        'pocket',
        'cashbox',
        'atm',
        'gift',
        'travel',
        'envelope',
        'card',
        'cards',
        'bank',
        'safe',
        'piggy',
        'deposit',
        'business',
        'home',
        'car',
        'education',
        'health',
        'reserve',
        'investment',
        'retirement',
        'family',
        'phone',
        'globe',
        'goal',
        'shop',
      ]) {
        expect(resolveWalletIcon(id).id, id);
      }
      expect(resolveCategoryIcon('unknown').id, 'category');
      expect(resolveWalletIcon('unknown').id, 'wallet');
      expect(
        matchesIcon(
          categoryIconCatalog.firstWhere((c) => c.id == 'fuel'),
          'АЗС',
        ),
        isTrue,
      );
      expect(
        matchesIcon(
          bankIconCatalog.firstWhere((c) => c.id == 'bank_t'),
          'тиньков',
        ),
        isTrue,
      );
    },
  );

  testWidgets('Every SVG/PNG renders at list and picker sizes, contact sheet', (
    t,
  ) async {
    await t.binding.setSurfaceSize(const Size(1200, 1600));
    addTearDown(() => t.binding.setSurfaceSize(null));
    final all = [
      ...categoryIconCatalog,
      ...financialIconCatalog,
      ...bankIconCatalog,
    ];
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RepaintBoundary(
            key: const ValueKey('sheet'),
            child: ColoredBox(
              color: Colors.white,
              child: GridView.count(
                crossAxisCount: 8,
                childAspectRatio: 1.4,
                children: [
                  for (final c in all)
                    Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            for (final size in [24.0, 32.0, 40.0])
                              CatalogMark(c, size: size),
                          ],
                        ),
                        Text(
                          c.label,
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    // Real IO raster/SVG decoding must finish before the screenshot assertion.
    await t.runAsync(() async {
      for (final c in all) {
        await rootBundle.load(c.asset);
        if (!c.asset.endsWith('.svg')) {
          await precacheImage(
            AssetImage(c.asset),
            t.element(find.byType(Scaffold)),
          );
        }
      }
      // SVG embedded raster decoding completes on the real event loop too.
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    final boundary = t.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('sheet')),
    );
    // Assert painted pixels, not just successful parsing: an unsupported SVG
    // pattern can otherwise silently produce a blank picture.
    final pixels = await t.runAsync(() async {
      final picture = await boundary.toImage(pixelRatio: 1);
      final bytes = await picture.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      picture.dispose();
      return bytes!;
    });
    for (final c in all) {
      final rect = t.getRect(
        find.byWidgetPredicate(
          (w) => w is CatalogMark && w.choice.id == c.id && w.size == 40,
        ),
      );
      var painted = 0;
      for (var y = rect.top.ceil(); y < rect.bottom.floor(); y++) {
        for (var x = rect.left.ceil(); x < rect.right.floor(); x++) {
          final offset = (y * 1200 + x) * 4;
          if (pixels!.getUint8(offset) < 245 ||
              pixels.getUint8(offset + 1) < 245 ||
              pixels.getUint8(offset + 2) < 245) {
            painted++;
          }
        }
      }
      expect(painted, greaterThan(20), reason: '${c.id} must actually paint');
    }
    if (const bool.fromEnvironment('CAPTURE_QA')) {
      await t.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1.5);
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await Directory('build/qa').create(recursive: true);
        await File('build/qa/color-catalog.png')
            .writeAsBytes(bytes.buffer.asUint8List());
        image.dispose();
      });
    }
  });

  for (final width in [320.0, 1440.0]) {
    testWidgets(
      'Category picker search, selection and empty result at $width',
      (t) async {
        await t.binding.setSurfaceSize(Size(width, width == 320 ? 568 : 900));
        addTearDown(() => t.binding.setSurfaceSize(null));
        String? selected;
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CategoryIconField(
                value: 'cat_exp_fuel',
                onChanged: (id) => selected = id,
              ),
            ),
          ),
        );
        await t.tap(find.byType(OutlinedButton));
        await t.pumpAndSettle();
        expect(find.text('Выбран: Бензин'), findsOneWidget);
        await t.enterText(find.byType(TextField), 'азс');
        await t.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('choose-icon:cat_exp_fuel')),
          findsOneWidget,
        );
        await t.enterText(find.byType(TextField), 'несуществующий значок');
        await t.pumpAndSettle();
        expect(find.text('Значки не найдены'), findsOneWidget);
        await t.enterText(find.byType(TextField), 'кафе');
        await t.pumpAndSettle();
        await t.tap(
          find.byKey(const ValueKey('choose-icon:cat_exp_cafe_restaurant')),
        );
        await t.pumpAndSettle();
        expect(selected, 'cat_exp_cafe_restaurant');
        expect(t.takeException(), isNull);
      },
    );
  }
}
