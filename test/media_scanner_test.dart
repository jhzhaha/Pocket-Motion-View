import 'dart:io';

import 'package:dji_live_gallery/src/media_scanner.dart';
import 'package:dji_live_gallery/src/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'classifies Pocket 4 and Pocket 4P by their capture templates',
    () async {
      final dir = await Directory.systemTemp.createTemp('pocket-motion-test-');
      addTearDown(() => dir.delete(recursive: true));
      final templates = {
        'pocket4p.MP4': 'TPLG_VIDEO_LIVEPHOTO_4K_16X9_2997',
        'pocket4-horizontal.MP4': 'TPLG_IMX06A_VIDEO_LIVEPHOTO_4K_16X9_2997',
        'pocket4-vertical.MP4': 'TPLG_IMX06A_VIDEO_LIVEPHOTO_3K_9X16_2997',
        'pocket4-video.MP4': 'TPLG_IMX06A_VIDEO_4K_16X9_2997',
        'similar-name.MP4': 'TPLG_IMX06A_VIDEO_LIVEPHOTOTEST_4K',
        'proxy.LRF': 'TPLG_IMX06A_VIDEO_LIVEPHOTO_4K_16X9_2997',
      };
      for (final entry in templates.entries) {
        await File(p.join(dir.path, entry.key))
            .writeAsString('\x00\x01${entry.value}\x00');
      }
      await File(p.join(dir.path, 'unmarked.MP4')).writeAsBytes([0]);

      final assets = {
        for (final asset in await MediaScanner().scan(dir.path))
          asset.filename: asset,
      };
      expect(
        assets.values
            .where((asset) => asset.kind == MediaKind.livePhoto)
            .map((asset) => asset.filename),
        unorderedEquals([
          'pocket4p.MP4',
          'pocket4-horizontal.MP4',
          'pocket4-vertical.MP4',
        ]),
      );
      expect(
        assets['pocket4-vertical.MP4']?.template,
        templates['pocket4-vertical.MP4'],
      );
      expect(assets['pocket4-video.MP4']?.kind, MediaKind.video);
      expect(assets['similar-name.MP4']?.kind, MediaKind.video);
      expect(assets['unmarked.MP4']?.kind, MediaKind.video);
      expect(assets, isNot(contains('proxy.LRF')));
    },
  );
}
