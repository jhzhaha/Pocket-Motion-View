import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'tool_path.dart';

typedef PreviewFrame = ({Duration position, Uint8List image});

/// Uses the same FFmpeg decoder as export, including for Pocket HEVC footage.
class VideoPreview {
  static const previewFps = 12;
  static const _playbackDimension = 1280;
  static final _jpegHeader = RegExp(r'Content-length: (\d+)\r\n\r\n');
  final String path;

  VideoPreview(this.path);

  static String _scale(int limit) =>
      "scale=w='min($limit,iw)':h='min($limit,ih)':"
      'force_original_aspect_ratio=decrease:flags=lanczos';

  Future<Duration> duration() async {
    final result = await Process.run(ToolPath.find('ffmpeg'), [
      '-hide_banner',
      '-nostdin',
      '-i',
      path,
      '-map',
      '0:v:0',
      '-c',
      'copy',
      '-frames:v',
      '1',
      '-f',
      'null',
      '-',
    ]);
    final match = RegExp(r'Duration: (\d+):(\d+):(\d+(?:\.\d+)?)')
        .firstMatch(result.stderr as String);
    if (result.exitCode != 0 || match == null) {
      throw const FormatException('无法读取视频时长');
    }
    return Duration(
      hours: int.parse(match[1]!),
      minutes: int.parse(match[2]!),
      microseconds: (double.parse(match[3]!) * 1000000).round(),
    );
  }

  Future<List<PreviewFrame>> liveFrames({
    void Function(Process)? onStart,
  }) async {
    final process = await Process.start(ToolPath.find('ffmpeg'), [
      '-hide_banner',
      '-nostdin',
      '-nostats',
      '-filter_threads',
      '2',
      '-i',
      path,
      '-map',
      '0:v:0',
      '-vf',
      'showinfo,${_scale(_playbackDimension)}',
      '-fps_mode',
      'passthrough',
      ..._jpegOutput,
    ]);
    final output = (
      jpegStream(process.stdout).toList(),
      process.stderr.transform(const Utf8Decoder(allowMalformed: true)).join(),
      process.exitCode,
    ).wait;
    onStart?.call(process);
    final (images, log, exitCode) = await output;
    final positions = <Duration>[];
    final timing = RegExp(
      r'config in time_base: (\d+)/(\d+)|\bn:\s*\d+\s+pts:\s*(-?\d+)',
    );
    var numerator = 0;
    var denominator = 1;
    for (final match in timing.allMatches(log)) {
      if (match[1] != null) {
        numerator = int.parse(match[1]!);
        denominator = int.parse(match[2]!);
      } else {
        final micros =
            int.parse(match[3]!) * numerator * 1000000 ~/ denominator;
        positions.add(Duration(microseconds: micros < 0 ? 0 : micros));
      }
    }
    if (exitCode != 0 || images.isEmpty || images.length != positions.length) {
      throw const FormatException('无法解码实况');
    }
    return [
      for (var i = 0; i < images.length; i++)
        (position: positions[i], image: images[i]),
    ];
  }

  Future<Uint8List?> still(Duration position, {int maxDimension = 1920}) async {
    final result = await Process.run(ToolPath.find('ffmpeg'), [
      '-hide_banner',
      '-v',
      'error',
      '-nostdin',
      '-filter_threads',
      '2',
      '-ss',
      seconds(position),
      '-i',
      path,
      '-map',
      '0:v:0',
      '-vf',
      _scale(maxDimension),
      '-frames:v',
      '1',
      ..._jpegOutput,
    ], stdoutEncoding: null);
    if (result.exitCode != 0) throw const FormatException('无法读取视频帧');
    final frames = jpegStream(Stream.value(result.stdout as Uint8List));
    await for (final frame in frames) {
      return frame;
    }
    return null;
  }

  Future<Process> play(Duration position) =>
      Process.start(ToolPath.find('ffmpeg'), [
        '-hide_banner',
        '-v',
        'error',
        '-nostdin',
        '-filter_threads',
        '2',
        '-ss',
        seconds(position),
        '-re',
        '-threads',
        '2',
        '-i',
        path,
        '-map',
        '0:v:0',
        '-vf',
        'fps=$previewFps,${_scale(_playbackDimension)}',
        ..._jpegOutput,
      ]);

  Future<Process> playAudio(Duration position) =>
      Process.start(ToolPath.find('ffplay'), [
        '-hide_banner',
        '-loglevel',
        'error',
        '-autoexit',
        '-nodisp',
        '-vn',
        '-ss',
        seconds(position),
        '-i',
        p.absolute(path),
      ]);

  static String seconds(Duration position) =>
      (position.inMicroseconds / 1000000).toStringAsFixed(6);

  static const _jpegOutput = [
    '-an',
    '-c:v',
    'mjpeg',
    '-q:v',
    '3',
    '-threads',
    '1',
    '-flush_packets',
    '1',
    '-f',
    'mpjpeg',
    'pipe:1',
  ];

  static Stream<Uint8List> jpegStream(Stream<List<int>> chunks) async* {
    // FFmpeg emits one fixed multipart header with Content-length per frame.
    var pending = Uint8List(0);
    var length = 0;
    await for (final chunk in chunks) {
      pending = pending.isEmpty && chunk is Uint8List
          ? chunk
          : Uint8List.fromList([...pending, ...chunk]);
      var offset = 0;
      while (offset < pending.length) {
        if (length == 0) {
          final end = (offset + 128).clamp(offset, pending.length);
          final header = _jpegHeader.firstMatch(
            latin1.decode(Uint8List.sublistView(pending, offset, end)),
          );
          if (header == null) break;
          length = int.parse(header[1]!);
          offset += header.end;
        }
        if (pending.length - offset < length) break;
        yield Uint8List.fromList(
          Uint8List.sublistView(pending, offset, offset + length),
        );
        offset += length;
        length = 0;
      }
      pending = Uint8List.sublistView(pending, offset);
    }
  }
}
