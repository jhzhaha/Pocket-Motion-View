import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Keeps each tile's image ratio while filling complete rows edge to edge.
class MediaGrid extends StatelessWidget {
  const MediaGrid({
    super.key,
    required this.padding,
    required this.aspectRatios,
    required this.itemBuilder,
  });

  final EdgeInsets padding;
  final List<double> aspectRatios;
  final IndexedWidgetBuilder itemBuilder;
  static const gap = 6.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = math.max(1.0, constraints.maxWidth - padding.horizontal);
        final target = (width / 4.2).clamp(155.0, 250.0);
        final rows = <({int start, int end, double height})>[];
        var start = 0;
        while (start < aspectRatios.length) {
          var end = start;
          var total = 0.0;
          while (end < aspectRatios.length) {
            final next = total + aspectRatios[end];
            final occupied = next * target + (end - start) * gap;
            if (end > start && occupied > width) {
              final previous = total * target + (end - start - 1) * gap;
              if (occupied - width > width - previous) break;
            }
            total = next;
            end++;
            if (occupied >= width) break;
          }
          final height = (width - (end - start - 1) * gap) / total;
          rows.add((
            start: start,
            end: end,
            height: end == aspectRatios.length
                ? math.min(height, target)
                : height,
          ));
          start = end;
        }
        return ListView.separated(
          padding: padding,
          itemCount: rows.length,
          separatorBuilder: (_, _) => const SizedBox(height: gap),
          itemBuilder: (context, rowIndex) {
            final row = rows[rowIndex];
            return SizedBox(
              height: row.height,
              child: Row(
                children: [
                  for (var index = row.start; index < row.end; index++) ...[
                    if (index > row.start) const SizedBox(width: gap),
                    SizedBox(
                      width: row.height * aspectRatios[index],
                      height: row.height,
                      child: itemBuilder(context, index),
                    ),
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }
}
