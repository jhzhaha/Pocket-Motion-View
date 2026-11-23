import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'media_color.dart';
import 'media_metadata.dart';
import 'models.dart';
import 'video_preview.dart';

class PreviewPane extends StatefulWidget {
  final MediaAsset asset;
  final CoverFrame? cover;
  final bool muted;
  final ValueChanged<bool> onMutedChanged;
  final ValueChanged<CoverFrame?> onCoverChanged;
  final VoidCallback onClose;
  final ValueChanged<Color>? onMediaColor;
  @visibleForTesting
  final VideoPreview? decoder;

  const PreviewPane({
    super.key,
    required this.asset,
    required this.cover,
    required this.muted,
    required this.onMutedChanged,
    required this.onCoverChanged,
    required this.onClose,
    this.onMediaColor,
    this.decoder,
  });

  @override
  State<PreviewPane> createState() => _PreviewPaneState();
}

class _PreviewPaneState extends State<PreviewPane> {
  static const _timelineHeight = 76.0;
  late final _decoder = widget.decoder ?? VideoPreview(widget.asset.path);
  bool get _isLive => widget.asset.kind == MediaKind.livePhoto;
  bool get _isPhoto => widget.asset.kind == MediaKind.photo;
  final _clock = Stopwatch();
  List<PreviewFrame> _frames = [];
  double _filmAspectRatio = 16 / 9;
  Uint8List? _videoFrame;
  Process? _player;
  Process? _liveLoader;
  Process? _audioPlayer;
  int _audioRequest = 0;
  Timer? _timer;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  int _liveIndex = 0;
  int _request = 0;
  bool _loading = true;
  bool _playing = false;
  bool _resumeAfterSeek = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _stop();
    _liveLoader?.kill();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      if (_isPhoto) {
        final image = widget.asset.isRawPhoto
            ? await _decoder.still(Duration.zero, maxDimension: 4096)
            : null;
        if (!mounted) return;
        setState(() {
          _videoFrame = image;
          _loading = false;
          if (widget.asset.isRawPhoto && image == null) _error = '无法解码 RAW 照片';
        });
        if (_error == null) unawaited(_sampleColor(image));
      } else if (_isLive) {
        final frames = await _decoder.liveFrames(
          onStart: (process) {
            if (mounted) {
              _liveLoader = process;
            } else {
              process.kill();
            }
          },
        );
        _liveLoader = null;
        final preferred = widget.cover?.position ?? defaultCoverPosition;
        final nearest = frames.indexWhere(
          (frame) => frame.position >= preferred,
        );
        final dimensions = MediaMetadata.extractJpegDimensions(
          frames.first.image,
        );
        if (!mounted) return;
        setState(() {
          _frames = frames;
          _filmAspectRatio = dimensions == null
              ? widget.asset.aspectRatio ?? 16 / 9
              : dimensions.$1 / dimensions.$2;
          _liveIndex =
              widget.cover?.index.clamp(0, frames.length - 1) ??
              (nearest < 0 ? frames.length ~/ 2 : nearest);
          _loading = false;
        });
        unawaited(_sampleColor(frames[_liveIndex].image));
      } else {
        final (duration, frame) = await (
          _decoder.duration(),
          _decoder.still(Duration.zero),
        ).wait;
        if (!mounted) return;
        setState(() {
          _duration = duration;
          _videoFrame = frame;
          _loading = false;
        });
        if (frame != null) unawaited(_sampleColor(frame));
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '无法预览此文件';
      });
    }
  }

  Future<void> _sampleColor(Uint8List? frame) async {
    if (widget.onMediaColor == null) return;
    try {
      final color = await sampleMediaColor(widget.asset.path, frame);
      if (color != null && mounted) widget.onMediaColor?.call(color);
    } catch (_) {
      // A color sample is optional even when the main decoder can display the asset.
    }
  }

  void _stop() {
    _request++;
    _timer?.cancel();
    _clock.stop();
    _player?.kill();
    _player = null;
    _stopAudio();
    _playing = false;
  }

  void _stopAudio() {
    _audioRequest++;
    _audioPlayer?.kill();
    _audioPlayer = null;
  }

  Future<void> _startAudio(Duration position) async {
    final request = ++_audioRequest;
    try {
      final process = await _decoder.playAudio(position);
      unawaited(process.stdout.drain<void>());
      unawaited(process.stderr.drain<void>());
      if (!mounted || request != _audioRequest) {
        process.kill();
        return;
      }
      _audioPlayer = process;
      await process.exitCode;
      if (identical(_audioPlayer, process)) _audioPlayer = null;
    } on ProcessException {
      if (mounted && request == _audioRequest) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法启动预览音频')));
      }
    }
  }

  void _toggleMute() {
    final mute = !widget.muted;
    widget.onMutedChanged(mute);
    if (mute) {
      _stopAudio();
    } else if (_playing) {
      unawaited(
        _startAudio(_isLive ? _frames[_liveIndex].position : _position),
      );
    }
  }

  void _togglePlayback() {
    if (_isPhoto || _loading || _error != null) return;
    if (_playing) {
      setState(_stop);
      return;
    }
    if (_isLive) {
      if (_liveIndex >= _frames.length - 1) _liveIndex = 0;
      final start = _frames[_liveIndex].position;
      if (!widget.muted) unawaited(_startAudio(start));
      _clock
        ..reset()
        ..start();
      _timer = Timer.periodic(const Duration(milliseconds: 15), (_) {
        final target = start + _clock.elapsed;
        var next = _liveIndex;
        while (next + 1 < _frames.length &&
            _frames[next + 1].position <= target) {
          next++;
        }
        if (next != _liveIndex || next == _frames.length - 1) {
          setState(() {
            _liveIndex = next;
            if (next == _frames.length - 1) _stop();
          });
        }
      });
      setState(() => _playing = true);
    } else {
      if (_duration - _position <= const Duration(milliseconds: 120)) {
        _position = Duration.zero;
      }
      unawaited(_playVideo());
    }
  }

  Future<void> _playVideo() async {
    final request = ++_request;
    final start = _position;
    setState(() => _playing = true);
    try {
      final playback = _decoder.play(start);
      if (!widget.muted) unawaited(_startAudio(start));
      final process = await playback;
      final errors = process.stderr.drain<void>();
      if (!mounted || request != _request) {
        process.kill();
        unawaited(process.stdout.drain<void>());
        return;
      }
      _player = process;
      var frameIndex = 0;
      await for (final frame in VideoPreview.jpegStream(process.stdout)) {
        if (!mounted || request != _request) break;
        final offset = Duration(
          microseconds: frameIndex++ * 1000000 ~/ VideoPreview.previewFps,
        );
        setState(() {
          _videoFrame = frame;
          final position = start + offset;
          _position = position > _duration ? _duration : position;
        });
      }
      final exit = await process.exitCode;
      await errors;
      if (!mounted || request != _request) return;
      setState(() {
        _stop();
        if (exit == 0) {
          _position = _duration;
        } else {
          _error = '无法播放此视频';
        }
      });
    } catch (_) {
      if (!mounted || request != _request) return;
      setState(() {
        _stop();
        _error = '无法播放此视频';
      });
    }
  }

  void _seekLive(int index) {
    setState(() {
      _stop();
      _liveIndex = index.clamp(0, _frames.length - 1);
    });
  }

  Future<void> _seekVideo() async {
    final request = ++_request;
    try {
      final frame = await _decoder.still(_position);
      if (!mounted || request != _request) return;
      if (frame != null) setState(() => _videoFrame = frame);
    } catch (_) {
      if (mounted && request == _request) {
        setState(() => _error = '无法定位此视频');
      }
    }
  }

  Future<void> _openExternal() async {
    setState(_stop);
    final opener = Platform.isWindows
        ? 'explorer.exe'
        : (Platform.isMacOS ? 'open' : 'xdg-open');
    try {
      await Process.start(opener, [
        widget.asset.path,
      ], mode: ProcessStartMode.detached);
    } on ProcessException {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法打开系统播放器')));
      }
    }
  }

  static String _time(Duration time, {required bool precise}) {
    final minutes = time.inMinutes;
    final seconds = (time.inSeconds % 60).toString().padLeft(2, '0');
    final fraction = (time.inMilliseconds % 1000 ~/ 10).toString().padLeft(
      2,
      '0',
    );
    return precise ? '$minutes:$seconds.$fraction' : '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final ready = !_loading && _error == null;
    final liveReady = ready && _isLive;
    final position = liveReady ? _frames[_liveIndex].position : _position;
    final duration = liveReady ? _frames.last.position : _duration;
    final image = liveReady ? _frames[_liveIndex].image : _videoFrame;
    final max = liveReady
        ? (_frames.length - 1).clamp(1, _frames.length).toDouble()
        : _duration.inMicroseconds.clamp(1, 1 << 53).toDouble();

    final selected =
        liveReady &&
        widget.cover?.index == _liveIndex &&
        widget.cover?.position == position;

    return CallbackShortcuts(
      bindings: {
        if (!_isPhoto)
          const SingleActivator(LogicalKeyboardKey.space): _togglePlayback,
        if (liveReady)
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
              _seekLive(_liveIndex - 1),
        if (liveReady)
          const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
              _seekLive(_liveIndex + 1),
      },
      child: Focus(
        autofocus: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 14, right: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.asset.filename,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  if (!_isPhoto)
                    IconButton(
                      onPressed: _toggleMute,
                      icon: Icon(
                        widget.muted
                            ? Icons.volume_off_outlined
                            : Icons.volume_up_outlined,
                      ),
                      isSelected: widget.muted,
                      tooltip: widget.muted ? '取消静音' : '静音',
                    ),
                  IconButton(
                    onPressed: _openExternal,
                    icon: const Icon(Icons.open_in_new, size: 20),
                    tooltip: _isPhoto ? '打开原图' : '在系统播放器打开原片',
                  ),
                  IconButton(
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.close),
                    tooltip: '关闭预览',
                  ),
                ],
              ),
            ),
            Expanded(
              child: ColoredBox(
                key: const ValueKey('preview-stage'),
                color: colors.primaryContainer,
                child: _isPhoto && ready
                    ? _buildPhoto(image)
                    : image != null && _error == null
                    ? GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _togglePlayback,
                        child: Image.memory(
                          image,
                          fit: BoxFit.contain,
                          filterQuality: FilterQuality.medium,
                          gaplessPlayback: true,
                        ),
                      )
                    : Center(
                        child: _loading
                            ? const CircularProgressIndicator(strokeWidth: 2)
                            : Text(
                                _error ?? '',
                                style: TextStyle(
                                  color: colors.onPrimaryContainer,
                                ),
                              ),
                      ),
              ),
            ),
            if (_isLive || (ready && !_isPhoto))
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 5, 8, 5),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: ready ? _togglePlayback : null,
                      tooltip: _playing ? '暂停' : '播放',
                      icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                    ),
                    Expanded(
                      child: _isLive
                          ? liveReady
                                ? _buildTimeline(max)
                                : const SizedBox(height: _timelineHeight)
                          : Slider(
                              value: _position.inMicroseconds.toDouble(),
                              max: max,
                              semanticFormatterCallback: (value) => _time(
                                Duration(microseconds: value.round()),
                                precise: false,
                              ),
                              onChangeStart: (_) {
                                _resumeAfterSeek = _playing;
                                setState(_stop);
                              },
                              onChanged: (value) => setState(() {
                                _position = Duration(
                                  microseconds: value.round(),
                                );
                              }),
                              onChangeEnd: (_) {
                                if (_resumeAfterSeek) {
                                  _resumeAfterSeek = false;
                                  _togglePlayback();
                                } else {
                                  unawaited(_seekVideo());
                                }
                              },
                            ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _isLive
                          ? _time(position, precise: true)
                          : '${_time(position, precise: false)} / ${_time(duration, precise: false)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFeatures: [const FontFeature.tabularFigures()],
                      ),
                    ),
                    if (_isLive) ...[
                      IconButton(
                        key: const ValueKey('reset-cover'),
                        onPressed: !liveReady || widget.cover == null
                            ? null
                            : () {
                                widget.onCoverChanged(null);
                                final nearest = _frames.indexWhere(
                                  (frame) =>
                                      frame.position >= defaultCoverPosition,
                                );
                                _seekLive(
                                  nearest < 0 ? _frames.length ~/ 2 : nearest,
                                );
                              },
                        icon: const Icon(Icons.restore, size: 18),
                        tooltip: '恢复默认封面',
                      ),
                      const SizedBox(width: 4),
                      FilledButton(
                        onPressed: !liveReady || selected
                            ? null
                            : () {
                                _seekLive(_liveIndex);
                                widget.onCoverChanged((
                                  position: position,
                                  index: _liveIndex,
                                ));
                              },
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                        ),
                        child: Text(selected ? '已设封面' : '设为封面'),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPhoto(Uint8List? bytes) {
    final ImageProvider source = bytes == null
        ? FileImage(File(widget.asset.path))
        : MemoryImage(bytes);
    return InteractiveViewer(
      maxScale: 4,
      child: Image(
        image: ResizeImage(
          source,
          width: 4096,
          height: 4096,
          policy: ResizeImagePolicy.fit,
        ),
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
        errorBuilder: (_, _, _) => const Center(child: Text('无法打开照片')),
      ),
    );
  }

  Widget _buildTimeline(double max) {
    final colors = Theme.of(context).colorScheme;
    final last = _frames.length - 1;
    const inset = 10.0;
    final cover = widget.cover;
    final coverIndex =
        cover?.index ??
        _frames.indexWhere((frame) => frame.position >= defaultCoverPosition);

    return SizedBox(
      height: _timelineHeight,
      child: LayoutBuilder(
        builder: (context, bounds) {
          const maxFrameHeight = _timelineHeight - 8;
          final count = (bounds.maxWidth / (maxFrameHeight * _filmAspectRatio))
              .ceil()
              .clamp(1, 120);
          final tileWidth = bounds.maxWidth / count;
          final stripHeight = (tileWidth / _filmAspectRatio).clamp(
            0.0,
            maxFrameHeight,
          );
          final pixelRatio = MediaQuery.devicePixelRatioOf(context);
          final frameWidth = (tileWidth * pixelRatio).ceil().clamp(1, 720);
          final frameHeight = (stripHeight * pixelRatio).ceil().clamp(1, 720);
          final fraction =
              (coverIndex < 0 ? last ~/ 2 : coverIndex).clamp(0, last) / max;
          return Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                height: stripHeight,
                width: bounds.maxWidth,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: ColoredBox(
                    color: colors.surfaceContainerHighest,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = 0; i < count; i++)
                          Expanded(
                            child: Image(
                              image: ResizeImage(
                                MemoryImage(
                                  _frames[count == 1
                                          ? last ~/ 2
                                          : (i * last / (count - 1)).round()]
                                      .image,
                                ),
                                width: frameWidth,
                                height: frameHeight,
                                policy: ResizeImagePolicy.fit,
                              ),
                              fit: BoxFit.contain,
                              filterQuality: FilterQuality.medium,
                              excludeFromSemantics: true,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(
                left:
                    inset +
                    (bounds.maxWidth - inset * 2).clamp(0.0, bounds.maxWidth) *
                        fraction -
                    4,
                top: 1,
                child: IgnorePointer(
                  child: Tooltip(
                    message: '封面帧',
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: colors.tertiary,
                        borderRadius: BorderRadius.circular(2),
                      ),
                      child: const SizedBox(width: 8, height: 7),
                    ),
                  ),
                ),
              ),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 0,
                  overlayShape: SliderComponentShape.noOverlay,
                  tickMarkShape: SliderTickMarkShape.noTickMark,
                  thumbShape: const _Playhead(),
                ),
                child: Slider(
                  padding: const EdgeInsets.symmetric(horizontal: inset),
                  value: _liveIndex.toDouble(),
                  max: max,
                  divisions: last > 0 ? last : null,
                  activeColor: colors.onPrimary,
                  inactiveColor: Colors.transparent,
                  thumbColor: Colors.white,
                  semanticFormatterCallback: (value) =>
                      '第 ${value.round() + 1} 帧',
                  onChanged: last > 0
                      ? (value) => _seekLive(value.round())
                      : null,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Playhead extends SliderComponentShape {
  const _Playhead();

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => const Size(5, 66);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final edge = RRect.fromRectAndRadius(
      Rect.fromCenter(center: center, width: 5, height: 66),
      const Radius.circular(2),
    );
    context.canvas.drawRRect(edge, Paint()..color = const Color(0xD015253E));
    context.canvas.drawRRect(
      edge.deflate(1),
      Paint()..color = sliderTheme.thumbColor ?? Colors.white,
    );
  }
}
