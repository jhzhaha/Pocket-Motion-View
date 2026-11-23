import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'media_metadata.dart';
import 'tool_path.dart';
import 'video_preview.dart';

/// 懒加载缩略图：首次构建时用 ffmpeg 从 MP4 抽一帧，缓存到临时目录。
class ThumbnailImage extends StatefulWidget {
  final String videoPath;
  final Duration position;
  final BoxFit fit;
  final ValueChanged<double>? onAspectRatio;
  const ThumbnailImage({
    super.key,
    required this.videoPath,
    required this.position,
    this.fit = BoxFit.cover,
    this.onAspectRatio,
  });

  @override
  State<ThumbnailImage> createState() => _ThumbnailImageState();
}

class _ThumbnailImageState extends State<ThumbnailImage> {
  static const _decoderLimit = 3;
  static final _waiting = Queue<Completer<void>>();
  static int _decoders = 0;

  String? _cachePath;

  static Future<void> _reserveDecoder() async {
    if (_decoders < _decoderLimit) {
      _decoders++;
      return;
    }
    final next = Completer<void>();
    _waiting.addLast(next);
    await next.future;
  }

  static void _releaseDecoder() {
    if (_waiting.isEmpty) {
      _decoders--;
    } else {
      // Prefer the thumbnails the user scrolled to most recently.
      _waiting.removeLast().complete();
    }
  }

  Future<String> _cacheDir() async {
    final tmp = Directory.systemTemp;
    final dir = Directory(p.join(tmp.path, 'dji_live_thumbs'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  @override
  void initState() {
    super.initState();
    _ensureThumb();
  }

  Future<void> _ensureThumb() async {
    String? path;
    try {
      final stat = await File(widget.videoPath).stat();
      final dir = await _cacheDir();
      if (!mounted) return;
      final key =
          'grid_${widget.videoPath.hashCode}_${stat.modified.millisecondsSinceEpoch}'
          '_${widget.position.inMicroseconds}';
      final cache = File(p.join(dir, '$key.jpg'));
      if (!await cache.exists()) {
        await _reserveDecoder();
        try {
          if (!mounted) return;
          if (!await cache.exists()) {
            final scratch = await Directory(dir).createTemp('render-');
            try {
              final staged = File(p.join(scratch.path, 'thumb.jpg'));
              final result = await Process.run(ToolPath.find('ffmpeg'), [
                '-v',
                'error',
                '-nostdin',
                '-filter_threads',
                '1',
                '-y',
                '-ss',
                VideoPreview.seconds(widget.position),
                '-threads',
                '2',
                '-i',
                widget.videoPath,
                '-map',
                '0:v:0',
                '-frames:v',
                '1',
                '-vf',
                'scale=480:480:force_original_aspect_ratio=decrease',
                '-q:v',
                '5',
                '-update',
                '1',
                staged.path,
              ]);
              if (result.exitCode == 0 &&
                  await staged.exists() &&
                  !await cache.exists()) {
                await staged.rename(cache.path);
              }
            } finally {
              await scratch.delete(recursive: true);
            }
          }
        } finally {
          _releaseDecoder();
        }
      }
      if (await cache.exists()) {
        path = cache.path;
        final reportRatio = widget.onAspectRatio;
        if (reportRatio != null) {
          final size = MediaMetadata.extractJpegDimensions(
            await cache.readAsBytes(),
          );
          if (mounted && size != null) reportRatio(size.$1 / size.$2);
        }
      }
    } on FileSystemException {
      // A moved source is represented by the placeholder.
    } on ProcessException {
      // FFmpeg may be unavailable in a source checkout.
    } finally {
      if (mounted) {
        setState(() => _cachePath = path);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: _cachePath != null
          ? Image.file(
              File(_cachePath!),
              fit: widget.fit,
              errorBuilder: (_, _, _) => const Icon(Icons.movie_outlined),
            )
          : const Icon(Icons.movie, color: Colors.grey),
    );
  }
}
