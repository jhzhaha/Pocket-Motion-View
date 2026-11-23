import 'dart:convert';
import 'dart:io';

import 'package:dji_live_gallery/src/media_metadata.dart';
import 'package:dji_live_gallery/src/models.dart';
import 'package:dji_live_gallery/src/motion_photo_exporter.dart';
import 'package:dji_live_gallery/src/tool_path.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('Huawei export keeps source dimensions in the JPEG and video', () async {
    final ffmpeg = ToolPath.find('ffmpeg');
    final ffprobe = ToolPath.find('ffprobe');
    for (final tool in [ffmpeg, ffprobe]) {
      try {
        await Process.run(tool, ['-version']);
      } on ProcessException {
        markTestSkipped('$tool is required to verify media dimensions');
        return;
      }
    }

    final work = await Directory.systemTemp.createTemp('pocket-export-');
    addTearDown(() => work.delete(recursive: true));
    const width = 2160;
    const height = 1216;
    final source = File(p.join(work.path, 'source.mp4'));
    final generated = await Process.run(ffmpeg, [
      '-hide_banner',
      '-loglevel',
      'error',
      '-f',
      'lavfi',
      '-i',
      'color=s=${width}x$height:r=30',
      '-frames:v',
      '3',
      '-c:v',
      'libx264',
      '-threads',
      '2',
      source.path,
    ]);
    expect(generated.exitCode, 0, reason: '${generated.stderr}');

    final result = await MotionPhotoExporter().export(
      asset: MediaAsset(
        path: source.path,
        filename: 'source.mp4',
        kind: MediaKind.livePhoto,
        shotAt: null,
        sizeBytes: await source.length(),
      ),
      outDir: work.path,
      format: MotionPhotoFormat.huawei,
    );
    final jpg = await File(result).readAsBytes();
    expect(MediaMetadata.extractJpegDimensions(jpg), (width, height));

    const tagWidth = 20;
    final tag = ascii.decode(jpg.sublist(jpg.length - tagWidth)).trimRight();
    expect(tag, startsWith('LIVE_'));
    final videoLength = int.parse(tag.substring('LIVE_'.length)) - tagWidth;
    final videoEnd = jpg.length - 3 * tagWidth;
    final video = File(p.join(work.path, 'embedded.mp4'));
    await video.writeAsBytes(jpg.sublist(videoEnd - videoLength, videoEnd));
    final probed = await Process.run(ffprobe, [
      '-v',
      'error',
      '-select_streams',
      'v:0',
      '-show_entries',
      'stream=width,height',
      '-of',
      'csv=p=0',
      video.path,
    ]);
    expect(probed.exitCode, 0, reason: '${probed.stderr}');
    expect((probed.stdout as String).trim(), '$width,$height');
  });
}
