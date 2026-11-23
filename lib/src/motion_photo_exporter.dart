import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'media_metadata.dart';
import 'models.dart';
import 'tool_path.dart';

enum MotionPhotoFormat { google, huawei }

/// 将实况导出为包含封面和视频的单个 JPEG 文件。
class MotionPhotoExporter {
  static const _huaweiFps = 30;
  static const _huaweiTagWidth = 20;

  final void Function(String log)? onLog;
  MotionPhotoExporter({this.onLog});
  void _log(String s) {
    onLog?.call(s);
  }

  Future<String> export({
    required MediaAsset asset,
    required String outDir,
    MotionPhotoFormat format = MotionPhotoFormat.google,
    CoverFrame? cover,
    bool mute = false,
  }) async {
    final directory = await Directory(outDir).create(recursive: true);
    final base = "${asset.filename.replaceAll(RegExp(r'\.[^.]+$'), '')}A";
    final outPath = p.join(outDir, '$base.jpg');

    final mp4Info = await MediaMetadata.extractFromMp4(asset.path);
    final shotAt = asset.shotAt ?? mp4Info.creationTime;
    final deviceLabel =
        mp4Info.model.toUpperCase().startsWith(mp4Info.make.toUpperCase())
        ? mp4Info.model
        : '${mp4Info.make} ${mp4Info.model}';

    final scratch = await directory.createTemp('.motion-');
    try {
      var videoPath = asset.path;
      var position = cover?.position ?? defaultCoverPosition;
      final selectedIndex = cover?.index;
      Uint8List? huaweiTail;
      if (format == MotionPhotoFormat.huawei) {
        final encoded = p.join(scratch.path, 'encoded.mp4');
        videoPath = p.join(scratch.path, 'huawei.mp4');
        _log('编码华为动态视频: $base');
        final progress = await _ffmpeg('编码华为动态视频', [
          '-progress',
          'pipe:1',
          '-i',
          asset.path,
          '-map',
          '0:v:0',
          if (!mute) ...['-map', '0:a:0?'],
          '-map_metadata',
          '-1',
          '-map_chapters',
          '-1',
          '-vf',
          '${selectedIndex == null ? 'fps=$_huaweiFps,' : ''}setsar=1',
          if (selectedIndex != null) ...[
            '-fps_mode',
            'passthrough',
            '-enc_time_base:v',
            'demux',
          ],
          '-c:v',
          'libx264',
          '-pix_fmt',
          'yuv420p',
          '-preset',
          'fast',
          '-crf',
          '18',
          if (!mute) ...['-c:a', 'aac', '-ac', '2', '-b:a', '160k'],
          encoded,
        ]);
        final frames = RegExp(
          r'^frame=\s*(\d+)',
          multiLine: true,
        ).allMatches(progress).lastOrNull?.group(1);
        final frameCount = int.tryParse(frames ?? '') ?? 0;
        if (frameCount == 0) throw StateError('动态视频没有可用帧');
        final preferredFrame =
            (defaultCoverPosition.inMilliseconds * _huaweiFps / 1000).round();
        final coverFrame =
            selectedIndex ??
            (frameCount > preferredFrame ? preferredFrame : frameCount ~/ 2);
        if (coverFrame >= frameCount) throw StateError('所选封面超出视频范围');
        if (selectedIndex == null) {
          position = Duration(microseconds: coverFrame * 1000000 ~/ _huaweiFps);
        }

        await _ffmpeg('写入华为封面时间', [
          '-i',
          encoded,
          '-map',
          '0',
          '-c',
          'copy',
          '-brand',
          'mp42',
          '-movflags',
          '+faststart+use_metadata_tags',
          '-metadata',
          'com.openharmony.covertime=${(position.inMicroseconds / 1000).toStringAsFixed(3)}',
          videoPath,
        ]);
        // 华为 v6 格式的 60 字节尾标有三个等宽字段，长度包含首个字段。
        huaweiTail = Uint8List.fromList(
          ascii.encode(
            [
              'v6_f$coverFrame',
              '$coverFrame:$frameCount',
              'LIVE_${await File(videoPath).length() + _huaweiTagWidth}',
            ].map((tag) => tag.padRight(_huaweiTagWidth)).join(),
          ),
        );
      } else if (mute) {
        videoPath = p.join(scratch.path, 'silent.mp4');
        await _ffmpeg('移除音轨', [
          '-i',
          asset.path,
          '-map',
          '0:v:0',
          '-c',
          'copy',
          '-movflags',
          '+faststart',
          videoPath,
        ]);
      }

      final tmpJpg = p.join(scratch.path, 'still.jpg');
      _log('抽帧: $base ($deviceLabel)');
      await _ffmpeg('抽帧', [
        if (selectedIndex == null) ...[
          '-ss',
          (position.inMicroseconds / 1000000).toStringAsFixed(6),
        ],
        '-i',
        videoPath,
        '-map',
        '0:v:0',
        if (selectedIndex != null) ...['-vf', 'select=eq(n\\,$selectedIndex)'],
        '-frames:v',
        '1',
        '-q:v',
        '2',
        '-update',
        '1',
        tmpJpg,
      ]);
      var jpg = await File(tmpJpg).readAsBytes();
      final mp4 = File(videoPath);
      final dims = MediaMetadata.extractJpegDimensions(jpg);

      final exifApp1 = MediaMetadata.buildExifApp1Segment(
        make: mp4Info.make,
        model: mp4Info.model,
        software: 'Pocket Motion',
        shotAt: shotAt,
        imageWidth: dims?.$1,
        imageHeight: dims?.$2,
      );
      jpg = MediaMetadata.injectIntoJpeg(jpg, [
        exifApp1,
        if (format == MotionPhotoFormat.google)
          _buildXmpSegment(
            mp4Length: await mp4.length(),
            presentationUs: position.inMicroseconds,
          ),
      ]);

      final staged = File(p.join(scratch.path, 'export.jpg'));
      final out = staged.openWrite();
      try {
        out.add(jpg);
        await out.addStream(mp4.openRead());
        if (huaweiTail != null) out.add(huaweiTail);
      } finally {
        await out.close();
      }
      await staged.rename(outPath);
    } finally {
      try {
        await scratch.delete(recursive: true);
      } on FileSystemException catch (_) {}
    }

    if (shotAt != null) {
      try {
        await File(outPath).setLastModified(shotAt);
      } catch (_) {}
    }

    final formatLabel = switch (format) {
      MotionPhotoFormat.google => 'Google Motion Photo',
      MotionPhotoFormat.huawei => '华为动态照片',
    };
    _log('完成: $base.jpg ($formatLabel)');
    return outPath;
  }

  Future<String> _ffmpeg(String action, List<String> args) async {
    final result = await Process.run(ToolPath.find('ffmpeg'), [
      '-hide_banner',
      '-loglevel',
      'error',
      '-nostdin',
      '-y',
      ...args,
    ]);
    if (result.exitCode != 0) {
      _log('  !! ffmpeg: ${result.stderr}');
      throw Exception('$action失败 (exit ${result.exitCode})');
    }
    return result.stdout as String;
  }

  Uint8List _buildXmpSegment({
    required int mp4Length,
    required int presentationUs,
  }) {
    final xml =
        '''<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Pocket Motion">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about=""
    xmlns:GCamera="http://ns.google.com/photos/1.0/camera/"
    xmlns:Container="http://ns.google.com/photos/1.0/container/"
    xmlns:Item="http://ns.google.com/photos/1.0/container/item/"
    GCamera:MotionPhoto="1"
    GCamera:MotionPhotoVersion="1"
    GCamera:MotionPhotoPresentationTimestampUs="$presentationUs">
   <Container:Directory>
    <rdf:Seq>
     <rdf:li rdf:parseType="Resource">
      <Container:Item
        Item:Mime="image/jpeg"
        Item:Semantic="Primary"
        Item:Length="0"
        Item:Padding="0"/>
     </rdf:li>
     <rdf:li rdf:parseType="Resource">
      <Container:Item
        Item:Mime="video/mp4"
        Item:Semantic="MotionPhoto"
        Item:Length="$mp4Length"/>
     </rdf:li>
    </rdf:Seq>
   </Container:Directory>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>''';

    final prefix = 'http://ns.adobe.com/xap/1.0/\x00';
    final content = Uint8List.fromList([...prefix.codeUnits, ...xml.codeUnits]);
    final segLen = content.length + 2;
    final b = BytesBuilder()
      ..add([0xFF, 0xE1])
      ..add([(segLen >> 8) & 0xFF, segLen & 0xFF])
      ..add(content);
    return b.toBytes();
  }
}
