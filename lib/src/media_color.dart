import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Samples a single small image so the palette stays stable during playback.
Future<ui.Color?> sampleMediaColor(String path, Uint8List? frame) async {
  final buffer = frame == null
      ? await ui.ImmutableBuffer.fromFilePath(path)
      : await ui.ImmutableBuffer.fromUint8List(frame);
  try {
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    try {
      const sampleSize = 40;
      final codec = await descriptor.instantiateCodec(
        targetWidth: descriptor.width >= descriptor.height
            ? math.min(sampleSize, descriptor.width)
            : null,
        targetHeight: descriptor.width < descriptor.height
            ? math.min(sampleSize, descriptor.height)
            : null,
      );
      try {
        final image = (await codec.getNextFrame()).image;
        try {
          final bytes = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          return bytes == null ? null : _dominantColor(bytes);
        } finally {
          image.dispose();
        }
      } finally {
        codec.dispose();
      }
    } finally {
      descriptor.dispose();
    }
  } finally {
    buffer.dispose();
  }
}

ui.Color? _dominantColor(ByteData pixels) {
  final groups = <int, ({int count, int red, int green, int blue})>{};
  for (var i = 0; i < pixels.lengthInBytes; i += 4) {
    if (pixels.getUint8(i + 3) < 128) continue;
    final r = pixels.getUint8(i);
    final g = pixels.getUint8(i + 1);
    final b = pixels.getUint8(i + 2);
    final bucket = ((r >> 5) << 6) | ((g >> 5) << 3) | (b >> 5);
    final current = groups[bucket] ?? (count: 0, red: 0, green: 0, blue: 0);
    groups[bucket] = (
      count: current.count + 1,
      red: current.red + r,
      green: current.green + g,
      blue: current.blue + b,
    );
  }

  var bestScore = 0.0;
  ui.Color? dominant;
  for (final group in groups.values) {
    final r = group.red ~/ group.count;
    final g = group.green ~/ group.count;
    final b = group.blue ~/ group.count;
    final high = math.max(r, math.max(g, b));
    final low = math.min(r, math.min(g, b));
    final chroma = (high - low) / 255;
    // Preserve the most common hue while giving shadows and highlights less weight.
    final brightness = (high + low) / 510;
    final weight = 0.55 + (1 - (2 * brightness - 1).abs()) * 0.45 + chroma;
    final score = group.count * weight;
    if (score > bestScore) {
      bestScore = score;
      dominant = ui.Color.fromARGB(255, r, g, b);
    }
  }
  return dominant;
}
