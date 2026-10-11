import 'dart:io';
import 'dart:ui' as ui;
import 'dart:convert';

import 'package:finance_app/photoreal_icon_catalog.dart';
import 'package:finance_app/bank_icons_hq_catalog.dart';
import 'package:finance_app/wallet_photo_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'photoreal assets are high resolution PNGs with real transparency',
    () async {
      final assets = {
        for (final choice in photorealCategoryIconCatalog) choice.asset,
        for (final choice in walletPhotoGeneratedCatalog) choice.asset,
        for (final choice in bankIconsHqCatalog) choice.asset,
      };

      expect(assets.length, 401);
      final personal = (jsonDecode(
        File('assets/personal_expenses/asset_registry.json').readAsStringSync(),
      ) as Map).values.cast<Map>();
      final originalSizes = {
        for (final entry in personal)
          entry['runtime_asset']: entry['size_px'] as List,
      };
      for (final asset in assets) {
        expect(asset.endsWith('.png'), isTrue, reason: asset);
        final bytes = await File(asset).readAsBytes();
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        final image = frame.image;
        if (originalSizes.containsKey(asset)) {
          expect(image.width, originalSizes[asset]![0], reason: asset);
          expect(image.height, originalSizes[asset]![1], reason: asset);
        } else {
          expect(image.width, greaterThanOrEqualTo(1254), reason: asset);
          expect(image.height, greaterThanOrEqualTo(987), reason: asset);
        }
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        expect(data, isNotNull, reason: asset);
        var transparent = false;
        var visible = false;
        final rgba = data!.buffer.asUint8List();
        for (var offset = 3; offset < rgba.length; offset += 4) {
          final alpha = rgba[offset];
          transparent |= alpha == 0;
          visible |= alpha > 0;
          if (transparent && visible) break;
        }
        expect(transparent, isTrue, reason: '$asset has no transparent pixels');
        expect(visible, isTrue, reason: '$asset has no visible subject');
        image.dispose();
        codec.dispose();
      }

      for (final pair in {
        'design/approved_icon_quality/sber_emerald_approved.png':
            'assets/wallet_photoreal/card_sber_green.png',
        'design/approved_icon_quality/safe_approved.png':
            'assets/wallet_photoreal/safe_steel_photo.png',
        'design/approved_icon_quality/food_approved.png':
            'assets/category_photoreal/cat_exp_food.png',
      }.entries) {
        expect(
          await File(pair.key).readAsBytes(),
          await File(pair.value).readAsBytes(),
          reason:
              '${pair.value} must remain byte-identical to the approved file',
        );
      }
    },
  );
}
