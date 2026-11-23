import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dji_live_gallery/main.dart';
import 'package:dji_live_gallery/src/media_color.dart';
import 'package:dji_live_gallery/src/models.dart';
import 'package:dji_live_gallery/src/preview_dialog.dart';
import 'package:dji_live_gallery/src/video_preview.dart';
import 'package:dji_live_gallery/src/windows_title_bar.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory work;
  final galleryPreview = find.byKey(const ValueKey('media-preview'));

  setUp(() => work = Directory.systemTemp.createTempSync('pocket-widget-'));
  tearDown(() => work.deleteSync(recursive: true));

  Widget gallery() =>
      MaterialApp(home: HomePage(configFile: File('${work.path}/config.json')));

  testWidgets('window caption maps its buttons to Windows commands', (
    tester,
  ) async {
    const channel = MethodChannel('pocket_motion/window');
    final messenger = tester.binding.defaultBinaryMessenger;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return call.method == 'toggleMaximize';
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: WindowsTitleBar())),
    );
    await tester.pumpAndSettle();
    expect(find.text('Pocket Motion View'), findsOneWidget);
    await tester.tap(find.byTooltip('最大化'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('还原窗口'), findsOneWidget);
    await tester.tap(find.byTooltip('最小化'));
    await tester.tap(find.byTooltip('关闭窗口'));
    expect(calls, ['isMaximized', 'toggleMaximize', 'minimize', 'close']);
  });

  testWidgets('media filters are spaced and centered in the rail', (
    tester,
  ) async {
    await tester.pumpWidget(gallery());
    final panel = tester.getRect(find.byKey(const ValueKey('media-filters')));
    final first = tester.getRect(find.byTooltip('实况'));
    final second = tester.getRect(find.byTooltip('视频'));
    final third = tester.getRect(find.byTooltip('照片'));
    expect(second.top - first.bottom, 11);
    expect(third.top - second.bottom, 11);
    expect((first.top + third.bottom) / 2, closeTo(panel.center.dy, 0.5));
    for (final filter in [first, second, third]) {
      expect(filter.size, const Size.square(76));
    }
    await tester.binding.setSurfaceSize(const Size(535, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byTooltip('实况')), first.size);
  });

  testWidgets('selected media filter uses light ink on a dark fill', (
    tester,
  ) async {
    final colors =
        ColorScheme.fromSeed(
          seedColor: Colors.brown,
          brightness: Brightness.dark,
        ).copyWith(
          primaryContainer: const Color(0xFF282322),
          onPrimaryContainer: Colors.white,
        );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(colorScheme: colors),
        home: HomePage(configFile: File('${work.path}/config.json')),
      ),
    );
    final selected = find.byTooltip('实况');
    final icon = find.descendant(of: selected, matching: find.byType(Icon));
    final count = find.descendant(of: selected, matching: find.text('0'));
    expect(tester.widget<Icon>(icon).color, Colors.white);
    expect(tester.widget<Icon>(icon).size, 36);
    expect(tester.widget<Text>(count).style?.color, Colors.white);
    expect(tester.widget<Text>(count).style?.fontSize, 17);
  });

  test('palette samples ignore near-black pixels', () async {
    Future<Color?> sample({required bool paintAccent}) async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final paint = Paint()..color = const Color(0xFF1E191B);
      canvas.drawRect(const Rect.fromLTWH(0, 0, 40, 12), paint);
      if (paintAccent) {
        paint.color = const Color(0xFFC7AC8A);
        canvas.drawRect(const Rect.fromLTWH(32, 0, 8, 12), paint);
      }
      final picture = recorder.endRecording();
      final image = await picture.toImage(40, 12);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      return sampleMediaColor('', bytes!.buffer.asUint8List());
    }

    expect(await sample(paintAccent: true), const Color(0xFFC7AC8A));
    expect(await sample(paintAccent: false), isNull);
  });

  testWidgets('format arrow updates the primary action without exporting', (
    tester,
  ) async {
    await tester.pumpWidget(gallery());
    expect(find.text('实况'), findsNothing);
    expect(find.text('导出 Apple 实况'), findsOneWidget);
    expect(find.text('华为动态照片'), findsNothing);
    final primaryKey = find.byKey(const ValueKey('export-primary'));
    final arrow = find.byKey(const ValueKey('export-format'));
    final primaryRect = tester.getRect(primaryKey);
    final arrowRect = tester.getRect(arrow);
    expect(primaryRect.height, arrowRect.height);
    expect(primaryRect.top, arrowRect.top);
    expect(arrowRect.right, closeTo(800 - 22 - 12, 0.5));
    expect(find.byTooltip('导出 Apple 实况'), findsNothing);
    await tester.tap(arrow);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('huawei')));
    await tester.pumpAndSettle();
    final primary = find.widgetWithText(TextButton, '导出 华为动态照片');
    expect(primary, findsOneWidget);
    expect(tester.widget<TextButton>(primary).onPressed, isNull);
    expect(find.textContaining('导出完成'), findsNothing);

    await tester.tap(find.byTooltip('视频'));
    await tester.pumpAndSettle();
    expect(find.text('导出 视频'), findsOneWidget);
    expect(arrow, findsNothing);

    await tester.tap(find.byTooltip('照片'));
    await tester.pumpAndSettle();
    expect(find.text('导出 照片'), findsOneWidget);

    await tester.tap(find.byTooltip('实况'));
    await tester.pumpAndSettle();
    expect(primary, findsOneWidget);
  });

  testWidgets('settings stay open across the hover gap and close on exit', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(480, 420));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(gallery());
    final gear = find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == '目录设置',
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);

    await mouse.moveTo(tester.getCenter(gear));
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(gear).isSelected, isTrue);
    await mouse.moveTo(const Offset(81, 377));
    await tester.pump(const Duration(milliseconds: 100));
    await mouse.moveTo(tester.getCenter(find.text('导出位置')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.widget<IconButton>(gear).isSelected, isTrue);

    await mouse.moveTo(const Offset(400, 60));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(gear).isSelected, isFalse);

    await tester.tap(gear);
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(gear).isSelected, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(gear).isSelected, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('export result is centered without moving the preview', (
    tester,
  ) async {
    const name = 'DJI_20260101000000.jpg';
    final out = Directory('${work.path}/exports');
    File('${work.path}/$name').writeAsBytesSync(_landscape);
    File('${work.path}/config.json').writeAsStringSync(
      jsonEncode({'cameraDir': work.path, 'outDir': out.path}),
    );
    await tester.runAsync(() async {
      await tester.pumpWidget(gallery());
      await tester.tap(find.byTooltip('照片'));
      await _pumpUntil(tester, () => galleryPreview.evaluate().length == 1);
    });
    await tester.tap(galleryPreview);
    await tester.pumpAndSettle();

    final toolbar = find.byKey(const ValueKey('library-toolbar'));
    final preview = find.byType(PreviewPane);
    final filmstrip = find.byKey(const ValueKey('preview-library-scrollbar'));
    final toolbarBefore = tester.getRect(toolbar);
    final previewBefore = tester.getRect(preview);
    final filmstripBefore = tester.getRect(filmstrip);
    final summary = find.text('导出完成 · 成功 1 · 失败 0');

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('export-primary')));
      await _pumpUntil(tester, () => summary.evaluate().isNotEmpty);
    });
    await tester.pumpAndSettle();
    expect(File('${out.path}/photo/$name').readAsBytesSync(), _landscape);
    expect(tester.getRect(toolbar), toolbarBefore);
    expect(tester.getRect(preview), previewBefore);
    expect(tester.getRect(filmstrip), filmstripBefore);
    expect(tester.getCenter(summary), toolbarBefore.center);

    await tester.binding.setSurfaceSize(const Size(465, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpAndSettle();
    final title = tester.getRect(find.text('素材库'));
    final actions = tester.getRect(
      find.byKey(const ValueKey('library-actions')),
    );
    final summaryBounds = tester.getRect(summary);
    expect(summaryBounds.left, greaterThan(title.right));
    expect(summaryBounds.right, lessThan(actions.left));
    await tester.tap(summary);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AlertDialog, '导出日志'), findsOneWidget);
  });

  testWidgets('live timeline selects an exact cover and mute is independent', (
    tester,
  ) async {
    const asset = MediaAsset(
      path: 'test.mp4',
      filename: 'test.mp4',
      kind: MediaKind.livePhoto,
      shotAt: null,
      sizeBytes: 0,
    );
    final decoder = _FrameDecoder();
    CoverFrame? cover;
    var muted = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => PreviewPane(
              asset: asset,
              decoder: decoder,
              cover: cover,
              muted: muted,
              onMutedChanged: (value) => setState(() => muted = value),
              onCoverChanged: (value) => setState(() => cover = value),
              onClose: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final slider = find.byType(Slider);
    expect(slider, findsOneWidget);
    final track = tester.getRect(slider);
    final reset = find.byKey(const ValueKey('reset-cover'));
    final resetRect = tester.getRect(reset);
    expect(tester.widget<IconButton>(reset).onPressed, isNull);
    await tester.tapAt(Offset(track.right - 12, track.center.dy));
    await tester.pump();
    await tester.tap(find.text('设为封面'));
    await tester.pump();
    expect(cover, (position: const Duration(seconds: 2), index: 2));
    expect(find.text('已设封面'), findsOneWidget);
    expect(tester.getRect(reset), resetRect);
    expect(tester.getRect(slider), track);
    expect(tester.widget<IconButton>(reset).onPressed, isNotNull);
    await tester.tap(find.byTooltip('静音'));
    await tester.pump();
    expect(muted, isTrue);
    expect(find.byTooltip('取消静音'), findsOneWidget);
    await tester.tap(reset);
    await tester.pump();
    expect(cover, isNull);
    expect(tester.getRect(reset), resetRect);
    expect(tester.widget<IconButton>(reset).onPressed, isNull);
    expect(muted, isTrue);
  });

  testWidgets('wide preview fits full frames in more timeline cells', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1800, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PreviewPane(
            asset: const MediaAsset(
              path: 'wide.mp4',
              filename: 'wide.mp4',
              kind: MediaKind.livePhoto,
              shotAt: null,
              sizeBytes: 0,
            ),
            cover: null,
            decoder: _FrameDecoder(40),
            muted: false,
            onMutedChanged: (_) {},
            onCoverChanged: (_) {},
            onClose: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final frames = find.byWidgetPredicate(
      (widget) =>
          widget is Image &&
          widget.excludeFromSemantics &&
          widget.fit == BoxFit.contain,
    );
    expect(frames.evaluate().length, greaterThan(10));
    expect(tester.getSize(frames.first).height, greaterThan(60));
    expect(tester.takeException(), isNull);
  });

  testWidgets('portrait filmstrip keeps full frames next to each other', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PreviewPane(
            asset: const MediaAsset(
              path: 'portrait.mp4',
              filename: 'portrait.mp4',
              kind: MediaKind.livePhoto,
              shotAt: null,
              sizeBytes: 0,
            ),
            cover: null,
            decoder: _FrameDecoder(60, _portrait),
            muted: true,
            onMutedChanged: (_) {},
            onCoverChanged: (_) {},
            onClose: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final frames = find.byWidgetPredicate(
      (widget) => widget is Image && widget.excludeFromSemantics,
    );
    expect(frames.evaluate().length, greaterThan(30));
    final first = tester.getRect(frames.at(0));
    final next = tester.getRect(frames.at(1));
    expect(first.right, closeTo(next.left, 0.01));
    expect(first.width / first.height, closeTo(24 / 40, 0.01));
  });

  testWidgets(
    'gallery fits both photo ratios and uses the preview color globally',
    (tester) async {
      const portraitName = 'DJI_20260101000002.jpg';
      const landscapeName = 'DJI_20260101000001.jpg';
      final portrait = File('${work.path}/$portraitName')
        ..writeAsBytesSync(_portrait);
      final landscape = File('${work.path}/$landscapeName')
        ..writeAsBytesSync(_landscape);
      final config = File('${work.path}/config.json')
        ..writeAsStringSync(jsonEncode({'cameraDir': work.path}));
      await tester.runAsync(() async {
        await tester.pumpWidget(DjiLiveApp(configFile: config));
        await tester.tap(find.byTooltip('照片'));
        await _pumpUntil(tester, () => galleryPreview.evaluate().length == 2);
      });
      await tester.pumpAndSettle();
      expect(find.text(portraitName), findsNothing);
      expect(find.text(landscapeName), findsNothing);
      final portraitCard = tester.getRect(find.byKey(ValueKey(portrait.path)));
      final landscapeCard = tester.getRect(
        find.byKey(ValueKey(landscape.path)),
      );
      expect(portraitCard.width / portraitCard.height, closeTo(24 / 40, 0.01));
      expect(
        landscapeCard.width / landscapeCard.height,
        closeTo(40 / 24, 0.01),
      );
      expect(landscapeCard.left - portraitCard.right, closeTo(6, 0.01));

      ColorScheme appColors() => tester
          .widget<MaterialApp>(find.byType(MaterialApp))
          .theme!
          .colorScheme;
      final initialColors = appColors();
      await tester.runAsync(() async {
        await tester.tap(galleryPreview.first);
        await _pumpUntil(tester, () => appColors() != initialColors);
      });
      await tester.pumpAndSettle();
      final warm = appColors();
      final stage = find.byKey(const ValueKey('preview-stage'));
      expect(tester.widget<ColoredBox>(stage).color, warm.primaryContainer);
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
        isNull,
      );
      expect(
        Theme.of(tester.element(find.byType(Scaffold))).scaffoldBackgroundColor,
        warm.surfaceContainer,
      );
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip(landscapeName));
        await _pumpUntil(tester, () => appColors() != warm);
      });
      await tester.pumpAndSettle();
      final cool = appColors();
      expect(tester.widget<ColoredBox>(stage).color, cool.primaryContainer);
      await tester.tap(find.byTooltip('关闭预览'));
      await tester.pumpAndSettle();
      expect(appColors(), cool);
    },
  );

  testWidgets('photo preview opens an image without video controls', (
    tester,
  ) async {
    final file = File('${work.path}/photo.jpg')
      ..writeAsBytesSync(_FrameDecoder.image);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PreviewPane(
            asset: MediaAsset(
              path: file.path,
              filename: 'photo.jpg',
              kind: MediaKind.photo,
              shotAt: null,
              sizeBytes: file.lengthSync(),
            ),
            cover: null,
            muted: false,
            onMutedChanged: (_) {},
            onCoverChanged: (_) {},
            onClose: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.byTooltip('打开原图'), findsOneWidget);
    expect(find.byTooltip('静音'), findsNothing);
    expect(find.byType(Slider), findsNothing);
  });

  testWidgets('dragging the preview library scrollbar reveals more photos', (
    tester,
  ) async {
    for (var index = 0; index < 20; index++) {
      File(
        '${work.path}/DJI_202601010000${index.toString().padLeft(2, '0')}.jpg',
      ).writeAsBytesSync(_FrameDecoder.image);
    }
    File('${work.path}/config.json')
        .writeAsStringSync(jsonEncode({'cameraDir': work.path}));
    await tester.runAsync(() async {
      await tester.pumpWidget(gallery());
      await tester.tap(find.byTooltip('照片'));
      for (var attempt = 0; attempt < 100; attempt++) {
        await tester.pump();
        if (galleryPreview.evaluate().isNotEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    final toolbar = find.byKey(const ValueKey('library-toolbar'));
    final toolbarBounds = tester.getRect(toolbar);
    final firstCard = find.byKey(
      ValueKey(File('${work.path}/DJI_20260101000019.jpg').path),
    );
    expect(find.byTooltip('预览'), findsNothing);
    expect(tester.getRect(firstCard).top, greaterThan(toolbarBounds.bottom));
    final backdrop = find.descendant(
      of: toolbar,
      matching: find.byType(BackdropFilter),
    );
    expect(tester.widget<BackdropFilter>(backdrop).enabled, isTrue);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(firstCard),
        scrollDelta: const Offset(0, 55),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.getRect(toolbar), toolbarBounds);
    expect(tester.getRect(firstCard).overlaps(toolbarBounds), isTrue);
    await tester.tap(galleryPreview.first.hitTestable());
    await tester.pumpAndSettle();
    final bar = find.byKey(const ValueKey('preview-library-scrollbar'));
    final bounds = tester.getRect(bar);
    final controller = tester.widget<RawScrollbar>(bar).controller!;
    expect(controller.offset, 0);
    await tester.dragFrom(
      bounds.bottomLeft + const Offset(36, -6),
      const Offset(300, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(400));
    final dragged = controller.offset;
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: bounds.center,
        scrollDelta: const Offset(0, 125),
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(dragged + 125, 0.5));
    final tiles = find.descendant(of: bar, matching: find.byType(InkWell));
    await tester.tap(tiles.hitTestable().first);
    await tester.pumpAndSettle();
    expect(
      tester.widget<PreviewPane>(find.byType(PreviewPane)).asset.filename,
      isNot('DJI_20260101000019.jpg'),
    );
  });
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.pump();
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

final _portrait = base64Decode(
  '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAAoABgDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAX/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFgEBAQEAAAAAAAAAAAAAAAAAAAYH/8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAwDAQACEQMRAD8AmAJhoAAAAAAAAAAD/9k=',
);

final _landscape = base64Decode(
  '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAAYACgDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAb/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAAAAAAAAAAAAAAAAb/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIRAxEAPwCXAXybAAAAAAAAAAf/2Q==',
);

class _FrameDecoder extends VideoPreview {
  _FrameDecoder([this.frameCount = 3, this.bytes]) : super('test.mp4');
  final int frameCount;
  final Uint8List? bytes;

  static final image = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l3sAAAAASUVORK5CYII=',
  );

  @override
  Future<List<PreviewFrame>> liveFrames({
    void Function(Process)? onStart,
  }) async => [
    for (var index = 0; index < frameCount; index++)
      (position: Duration(seconds: index), image: bytes ?? image),
  ];
}
