import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class WindowsTitleBar extends StatefulWidget {
  const WindowsTitleBar({super.key});

  @override
  State<WindowsTitleBar> createState() => _WindowsTitleBarState();
}

class _WindowsTitleBarState extends State<WindowsTitleBar>
    with WidgetsBindingObserver {
  static const _window = MethodChannel('pocket_motion/window');
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_syncMaximized('isMaximized'));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() => unawaited(_syncMaximized('isMaximized'));

  Future<void> _syncMaximized(String method) async {
    final maximized = await _window.invokeMethod<bool>(method);
    if (mounted && maximized != null && maximized != _maximized) {
      setState(() => _maximized = maximized);
    }
  }

  void _toggleMaximize() => unawaited(_syncMaximized('toggleMaximize'));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Material(
      color: theme.scaffoldBackgroundColor,
      child: SizedBox(
        height: 40,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onDoubleTap: _toggleMaximize,
                onPanStart: (_) =>
                    unawaited(_window.invokeMethod<void>('drag')),
                child: Padding(
                  padding: const EdgeInsets.only(left: 14),
                  child: Row(
                    children: [
                      Image.asset(
                        'assets/pocket_motion.png',
                        width: 22,
                        height: 22,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          'Pocket Motion View',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelLarge,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            _WindowButton(
              label: '最小化',
              icon: Icons.remove,
              onPressed: () =>
                  unawaited(_window.invokeMethod<void>('minimize')),
            ),
            _WindowButton(
              label: _maximized ? '还原窗口' : '最大化',
              icon: _maximized ? Icons.filter_none : Icons.crop_square,
              onPressed: _toggleMaximize,
            ),
            _WindowButton(
              label: '关闭窗口',
              icon: Icons.close,
              hoverColor: colors.errorContainer,
              onPressed: () => unawaited(_window.invokeMethod<void>('close')),
            ),
          ],
        ),
      ),
    );
  }
}

class _WindowButton extends StatelessWidget {
  const _WindowButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.hoverColor,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final Color? hoverColor;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 46,
      child: IconButton(
        onPressed: onPressed,
        tooltip: label,
        icon: Icon(icon, size: 17),
        style: IconButton.styleFrom(
          hoverColor: hoverColor,
          shape: const RoundedRectangleBorder(),
        ),
      ),
    );
  }
}
