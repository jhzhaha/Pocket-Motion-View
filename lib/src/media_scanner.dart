import 'dart:io';

import 'package:path/path.dart' as p;

import 'media_metadata.dart';
import 'models.dart';

/// 媒体扫描器：从相机 DCIM 目录识别 照片/视频/实况。
///
/// 关键判据（已逆向验证）：相机在 MP4 的 dbgi 数据轨写入拍摄配置模板串，
/// Pocket 4P 写入 `TPLG_VIDEO_LIVEPHOTO_*`；Pocket 4 在 VIDEO 前加上
/// 传感器前缀，例如 `TPLG_IMX06A_VIDEO_LIVEPHOTO_*`。
class MediaScanner {
  /// 只扫文件前部即可，TPLG 位于 mdat 开头（偏移 ~10KB），
  /// 避免读整个 GB 级文件，保证扫描速度。
  static const _scanHeadBytes = 512 * 1024;

  static final _tplgRegex = RegExp(r'TPLG_[A-Z0-9_]+');
  static final _liveTemplate = RegExp(
    r'^TPLG_(?:IMX[A-Z0-9]+_)?VIDEO_LIVEPHOTO(?:_|$)',
  );

  /// 扫描目录，返回识别出的媒体列表。
  Future<List<MediaAsset>> scan(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return [];

    final entities = dir.listSync();
    final List<MediaAsset> assets = [];

    for (final e in entities) {
      if (e is! File) continue;
      final name = p.basename(e.path);
      final ext = name.split('.').last.toLowerCase();
      final stat = await e.stat();

      // 从文件名解析拍摄时间：DJI_20261022215019_0170_D.MP4
      final shotAt = _parseFileNameTime(name);

      if (ext == 'mp4') {
        final kind = await _classifyVideo(e.path);
        final tplg = kind.$2;
        assets.add(
          MediaAsset(
            path: e.path,
            filename: name,
            kind: kind.$1,
            shotAt: shotAt,
            sizeBytes: stat.size,
            template: tplg,
            aspectRatio: tplg?.contains('_9X16_') == true
                ? 9 / 16
                : tplg?.contains('_16X9_') == true
                ? 16 / 9
                : null,
          ),
        );
      } else if (ext == 'jpg' || ext == 'jpeg' || ext == 'dng') {
        assets.add(
          MediaAsset(
            path: e.path,
            filename: name,
            kind: MediaKind.photo,
            shotAt: shotAt,
            sizeBytes: stat.size,
            aspectRatio: ext == 'dng' ? null : await _jpegAspectRatio(e),
          ),
        );
      }
      // LRF 是低码率代理文件，跳过
    }

    assets.sort((a, b) => b.shotAt?.compareTo(a.shotAt ?? DateTime(0)) ?? 0);
    return assets;
  }

  static Future<double?> _jpegAspectRatio(File file) async {
    try {
      final reader = await file.open();
      try {
        final header = await reader.read(256 * 1024);
        final dimensions = MediaMetadata.extractJpegDimensions(
          header,
          applyOrientation: true,
        );
        return dimensions == null ? null : dimensions.$1 / dimensions.$2;
      } finally {
        await reader.close();
      }
    } on FileSystemException {
      return null;
    }
  }

  /// 返回 (类型, TPLG模板串)
  Future<(MediaKind, String?)> _classifyVideo(String path) async {
    final f = File(path);
    final raf = await f.open();
    try {
      final len = await raf.length();
      final readLen = len < _scanHeadBytes ? len : _scanHeadBytes;
      final buf = await raf.read(readLen);
      final data = String.fromCharCodes(buf);
      String? firstTemplate;
      for (final match in _tplgRegex.allMatches(data)) {
        final template = match.group(0)!;
        if (_liveTemplate.hasMatch(template)) {
          return (MediaKind.livePhoto, template);
        }
        firstTemplate ??= template;
      }
      return (MediaKind.video, firstTemplate);
    } finally {
      await raf.close();
    }
  }

  /// DJI_20261022215019_... -> 2026-10-22 21:50:19 (本地/北京时间)
  static DateTime? _parseFileNameTime(String name) {
    final m = RegExp(r'(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})')
        .firstMatch(name);
    if (m == null) return null;
    return DateTime(
      int.parse(m[1]!),
      int.parse(m[2]!),
      int.parse(m[3]!),
      int.parse(m[4]!),
      int.parse(m[5]!),
      int.parse(m[6]!),
    );
  }
}
