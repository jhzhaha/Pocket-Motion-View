import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

import 'src/models.dart';
import 'src/media_grid.dart';
import 'src/media_scanner.dart';
import 'src/live_photo_exporter.dart';
import 'src/motion_photo_exporter.dart';
import 'src/preview_dialog.dart';
import 'src/thumbnail_image.dart';
import 'src/tool_path.dart';
import 'src/windows_title_bar.dart';

void main() => runApp(const DjiLiveApp());

class DjiLiveApp extends StatefulWidget {
  const DjiLiveApp({super.key, this.configFile});

  final File? configFile;

  @override
  State<DjiLiveApp> createState() => _DjiLiveAppState();
}

class _DjiLiveAppState extends State<DjiLiveApp> {
  Color _seed = const Color(0xFFC7AC8A);

  void _applyPalette(Color dominant) {
    final hsl = HSLColor.fromColor(dominant);
    final seed = hsl
        .withSaturation(hsl.saturation * 0.52)
        .withLightness(hsl.lightness.clamp(0.34, 0.66))
        .toColor();
    if (seed != _seed) setState(() => _seed = seed);
  }

  @override
  Widget build(BuildContext context) {
    final palette = ColorScheme.fromSeed(
      seedColor: _seed,
      dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
    );
    final colors = palette.primaryContainer.computeLuminance() < 0.18
        ? palette.copyWith(onPrimaryContainer: Colors.white)
        : palette;
    return MaterialApp(
      title: 'Pocket Motion View',
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: Platform.isWindows ? 'Microsoft YaHei UI' : null,
        fontFamilyFallback: const [
          'Microsoft YaHei',
          'PingFang SC',
          'Noto Sans CJK SC',
        ],
        colorScheme: colors,
        scaffoldBackgroundColor: colors.surfaceContainer,
      ),
      home: HomePage(
        configFile: widget.configFile,
        onMediaColor: _applyPalette,
      ),
      debugShowCheckedModeBanner: false,
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.configFile, this.onMediaColor});

  final File? configFile;
  final ValueChanged<Color>? onMediaColor;
  @override
  State<HomePage> createState() => _HomePageState();
}

enum _LiveExportFormat {
  apple('Apple 实况'),
  google('Android 动态照片'),
  huawei('华为动态照片');

  const _LiveExportFormat(this.label);
  final String label;
}

class _HomePageState extends State<HomePage> {
  static const _mediaTabs = {
    MediaKind.livePhoto: (label: '实况', icon: Icons.motion_photos_on),
    MediaKind.video: (label: '视频', icon: Icons.movie_outlined),
    MediaKind.photo: (label: '照片', icon: Icons.photo_outlined),
  };

  final _scanner = MediaScanner();
  late String _cameraDir = _defaultCameraDir();
  late String _outDir = _defaultOutDir();

  List<MediaAsset> _assets = [];
  final Map<String, double> _thumbnailRatios = {};
  MediaKind _filter = MediaKind.livePhoto; // 默认只显示实况
  bool _scanning = false;
  bool _hasScanned = false;
  String? _scanError;
  final Set<String> _selected = {};
  final Map<String, CoverFrame> _covers = {};
  final Set<String> _muted = {};
  MediaAsset? _previewAsset;
  static const _previewTileWidth = 108.0;
  final _previewScroll = ScrollController();
  String? _anchorPath; // Shift 连选起点
  final List<String> _logs = [];
  bool _exporting = false;
  int _doneCount = 0;
  int _totalCount = 0;
  int _success = 0;
  int _fail = 0;
  _LiveExportFormat _liveExportFormat = _LiveExportFormat.apple;
  Future<void> _configWrites = Future.value();
  bool _settingsOpen = false;
  bool _settingsPinned = false;
  Timer? _settingsTimer;
  final _settingsGroup = Object();

  @override
  void initState() {
    super.initState();
    _loadSavedDirs();
  }

  @override
  void dispose() {
    _settingsTimer?.cancel();
    _previewScroll.dispose();
    super.dispose();
  }

  void _openSettings() {
    _settingsTimer?.cancel();
    if (!_settingsOpen) setState(() => _settingsOpen = true);
  }

  void _scheduleSettingsClose() {
    _settingsTimer?.cancel();
    if (!_settingsPinned) {
      _settingsTimer = Timer(const Duration(milliseconds: 180), _closeSettings);
    }
  }

  void _closeSettings() {
    _settingsTimer?.cancel();
    if (_settingsOpen) {
      setState(() {
        _settingsOpen = false;
        _settingsPinned = false;
      });
    }
  }

  void _toggleSettings() {
    if (_settingsPinned) {
      _closeSettings();
    } else {
      _openSettings();
      _settingsPinned = true;
    }
  }

  static String _defaultCameraDir() {
    if (Platform.isWindows) {
      return r'D:\DCIM\DJI_001';
    }
    return '/Volumes/Pocket4P/DCIM/DJI_001';
  }

  static String _defaultOutDir() {
    if (Platform.isWindows) {
      final userProfile =
          Platform.environment['USERPROFILE'] ?? r'C:\Users\Public';
      return p.join(userProfile, 'Downloads', 'PocketMotion_Out');
    }
    final home = Platform.environment['HOME'] ?? '/Users/Shared';
    return p.join(home, 'Downloads', 'live_out');
  }

  File _configFile() {
    final override = widget.configFile;
    if (override != null) return override;
    if (Platform.isWindows) {
      final appData =
          Platform.environment['APPDATA'] ??
          Platform.environment['USERPROFILE'] ??
          Directory.systemTemp.path;
      return File(p.join(appData, 'PocketMotion', 'config.json'));
    }
    final home = Platform.environment['HOME'] ?? Directory.systemTemp.path;
    return File(
      p.join(
        home,
        'Library',
        'Application Support',
        'PocketMotion',
        'config.json',
      ),
    );
  }

  Future<void> _loadSavedDirs() async {
    try {
      final file = _configFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        final data = jsonDecode(content);
        if (data is Map && mounted) {
          final savedCamera = data['cameraDir'];
          final savedOut = data['outDir'];
          final savedCovers = data['covers'];
          final savedFormat = data['liveExportFormat'];
          final savedMuted = data['mutedPaths'];
          setState(() {
            if (savedCamera is String && savedCamera.trim().isNotEmpty) {
              _cameraDir = savedCamera.trim();
            }
            if (savedOut is String && savedOut.trim().isNotEmpty) {
              _outDir = savedOut.trim();
            }
            for (final format in _LiveExportFormat.values) {
              if (format.name == savedFormat) _liveExportFormat = format;
            }
            if (savedMuted is List) {
              _muted.addAll(savedMuted.whereType<String>());
            }
            if (savedCovers is Map) {
              for (final entry in savedCovers.entries) {
                final value = entry.value;
                if (entry.key is String && value is List && value.length == 2) {
                  final position = value[0];
                  final index = value[1];
                  if (position is int &&
                      position >= 0 &&
                      index is int &&
                      index >= 0) {
                    _covers[entry.key as String] = (
                      position: Duration(microseconds: position),
                      index: index,
                    );
                  }
                }
              }
            }
          });
        }
      }
    } catch (_) {}
    final sourceExists = await Directory(_cameraDir).exists();
    if (sourceExists && mounted) {
      await _scan();
    }
  }

  Future<void> _saveDirs() {
    final content = jsonEncode({
      'cameraDir': _cameraDir,
      'outDir': _outDir,
      'liveExportFormat': _liveExportFormat.name,
      'mutedPaths': _muted.toList(),
      'covers': {
        for (final entry in _covers.entries)
          entry.key: [entry.value.position.inMicroseconds, entry.value.index],
      },
    });
    return _configWrites = _configWrites.then((_) async {
      try {
        final file = _configFile();
        await file.parent.create(recursive: true);
        await file.writeAsString(content);
      } on FileSystemException catch (_) {}
    });
  }

  List<MediaAsset> get _visible =>
      _assets.where((a) => a.kind == _filter).toList();

  Future<void> _scan() async {
    if (_scanning || _exporting) return;
    setState(() {
      _scanning = true;
      _scanError = null;
      _assets = [];
      _thumbnailRatios.clear();
      _selected.clear();
      _anchorPath = null;
      _previewAsset = null;
    });
    try {
      if (!await Directory(_cameraDir).exists()) {
        if (mounted) setState(() => _scanError = '找不到素材目录，请重新选择。');
        return;
      }
      final list = await _scanner.scan(_cameraDir);
      if (mounted) setState(() => _assets = list);
    } catch (_) {
      if (mounted) setState(() => _scanError = '无法读取素材目录，请检查访问权限。');
    } finally {
      if (mounted) {
        setState(() {
          _scanning = false;
          _hasScanned = true;
        });
      }
    }
  }

  void _log(String s) {
    if (mounted) setState(() => _logs.add(s));
  }

  Future<void> _pickCameraDir() async {
    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择相机素材目录',
    );
    if (dir != null && mounted) {
      setState(() {
        _cameraDir = dir;
        _selected.clear();
        _anchorPath = null;
      });
      await _saveDirs();
      if (mounted) await _scan();
    }
  }

  Future<void> _pickOutDir() async {
    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择导出目录',
    );
    if (dir != null && mounted) {
      setState(() => _outDir = dir);
      await _saveDirs();
    }
  }

  List<MediaAsset> get _picked =>
      _visible.where((a) => _selected.contains(a.path)).toList();

  void _preview(MediaAsset asset, int index) {
    _closeSettings();
    final wasClosed = _previewAsset == null;
    if (_previewAsset?.path == asset.path) return;
    setState(() => _previewAsset = asset);
    if (wasClosed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_previewScroll.hasClients) return;
        final scroll = _previewScroll.position;
        final center =
            (index + 0.5) * _previewTileWidth - scroll.viewportDimension / 2;
        scroll.jumpTo(center.clamp(0.0, scroll.maxScrollExtent));
      });
    }
  }

  void _closePreview() => setState(() => _previewAsset = null);

  void _scrollPreviewLibrary(PointerSignalEvent signal) {
    if (signal is! PointerScrollEvent ||
        signal.scrollDelta.dx != 0 ||
        signal.scrollDelta.dy == 0 ||
        !_previewScroll.hasClients) {
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(signal, (_) {
      if (_previewScroll.hasClients) {
        _previewScroll.position.pointerScroll(signal.scrollDelta.dy);
      }
    });
  }

  Future<void> _saveCover(MediaAsset asset, CoverFrame? cover) async {
    setState(() {
      if (cover == null) {
        _covers.remove(asset.path);
      } else {
        _covers[asset.path] = cover;
      }
    });
    await _saveDirs();
  }

  void _setMuted(MediaAsset asset, bool mute) {
    setState(() {
      if (mute) {
        _muted.add(asset.path);
      } else {
        _muted.remove(asset.path);
      }
    });
    _saveDirs();
  }

  void _onItemTap(int index, MediaAsset asset) {
    final visible = _visible;
    final isShift = HardwareKeyboard.instance.isShiftPressed;
    final anchorIdx = _anchorPath == null
        ? -1
        : visible.indexWhere((a) => a.path == _anchorPath);

    setState(() {
      if (isShift && anchorIdx != -1) {
        final start = anchorIdx < index ? anchorIdx : index;
        final end = anchorIdx < index ? index : anchorIdx;
        for (var i = start; i <= end; i++) {
          _selected.add(visible[i].path);
        }
        _anchorPath = asset.path;
      } else {
        if (_selected.contains(asset.path)) {
          _selected.remove(asset.path);
        } else {
          _selected.add(asset.path);
        }
        _anchorPath = asset.path;
      }
    });
  }

  List<MediaAsset> get _exportAssets {
    final picks = _picked;
    final preview = _previewAsset;
    return picks.isEmpty && preview != null ? [preview] : picks;
  }

  Future<void> _runExport(Future<void> Function(MediaAsset a) task) async {
    final picks = _exportAssets;
    if (picks.isEmpty || _exporting || _scanning) return;
    setState(() {
      _logs.clear();
      _exporting = true;
      _doneCount = 0;
      _totalCount = picks.length;
      _success = 0;
      _fail = 0;
    });
    for (final a in picks) {
      try {
        await task(a);
        _success++;
      } catch (e) {
        _fail++;
        _log('失败: ${a.filename} ($e)');
      }
      if (mounted) setState(() => _doneCount++);
    }
    _log('完成：成功 $_success，失败 $_fail');
    if (mounted) setState(() => _exporting = false);
  }

  void _exportApple() {
    final liveOutDir = p.join(_outDir, 'live');
    final covers = Map.of(_covers);
    final muted = Set.of(_muted);
    _runExport(
      (a) => LivePhotoExporter(onLog: _log).export(
        asset: a,
        outDir: liveOutDir,
        cover: covers[a.path],
        mute: muted.contains(a.path),
      ),
    );
  }

  void _exportMotion(MotionPhotoFormat format) {
    final liveOutDir = format == MotionPhotoFormat.huawei
        ? p.join(_outDir, 'live', 'huawei')
        : p.join(_outDir, 'live');
    final covers = Map.of(_covers);
    final muted = Set.of(_muted);
    _runExport(
      (a) => MotionPhotoExporter(onLog: _log).export(
        asset: a,
        outDir: liveOutDir,
        format: format,
        cover: covers[a.path],
        mute: muted.contains(a.path),
      ),
    );
  }

  void _exportVideos() {
    final movieOutDir = p.join(_outDir, 'movie');
    final muted = Set.of(_muted);
    _runExport(
      (a) =>
          _copyMediaFile(a, movieOutDir, 'movie', mute: muted.contains(a.path)),
    );
  }

  void _exportPhotos() {
    final photoOutDir = p.join(_outDir, 'photo');
    _runExport((a) => _copyMediaFile(a, photoOutDir, 'photo'));
  }

  Future<void> _copyMediaFile(
    MediaAsset asset,
    String targetDir,
    String folderLabel, {
    bool mute = false,
  }) async {
    final directory = await Directory(targetDir).create(recursive: true);
    final destPath = p.join(targetDir, asset.filename);
    _log('导出: ${asset.filename} -> $folderLabel/');
    if (mute) {
      final scratch = await directory.createTemp('.video-');
      try {
        final silent = p.join(scratch.path, asset.filename);
        final result = await Process.run(ToolPath.find('ffmpeg'), [
          '-hide_banner',
          '-loglevel',
          'error',
          '-nostdin',
          '-i',
          asset.path,
          '-map',
          '0:v',
          '-c',
          'copy',
          silent,
        ]);
        if (result.exitCode != 0) throw StateError('移除音轨失败：${result.stderr}');
        await File(silent).rename(destPath);
      } finally {
        await scratch.delete(recursive: true);
      }
    } else {
      await File(asset.path).copy(destPath);
    }

    DateTime? shotAt = asset.shotAt;
    if (shotAt == null) {
      try {
        shotAt = await File(asset.path).lastModified();
      } catch (_) {}
    }

    if (shotAt != null) {
      if (Platform.isMacOS) {
        try {
          await Process.run(ToolPath.find('SetFile'), [
            '-d',
            _macTime(shotAt),
            destPath,
          ]);
        } catch (_) {}
      }
      try {
        await File(destPath).setLastModified(shotAt);
      } catch (_) {}
    }
    _log('完成: $folderLabel/${asset.filename}');
  }

  static String _macTime(DateTime dt) =>
      '${dt.month.toString().padLeft(2, '0')}/'
      '${dt.day.toString().padLeft(2, '0')}/'
      '${dt.year} '
      '${dt.hour.toString().padLeft(2, '0')}:'
      '${dt.minute.toString().padLeft(2, '0')}:'
      '${dt.second.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 580;
        const railWidth = 76.0;
        final leftInset = compact ? 8.0 : 14.0;
        final counts = {for (final kind in MediaKind.values) kind: 0};
        for (final asset in _assets) {
          counts.update(asset.kind, (count) => count + 1);
        }
        final motion = MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 180);
        return Scaffold(
          body: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): _onEscape,
            },
            child: Focus(
              autofocus: true,
              child: Column(
                children: [
                  if (Platform.isWindows) const WindowsTitleBar(),
                  Expanded(
                    child: Stack(
                      children: [
                        Row(
                          children: [
                            Padding(
                              padding: EdgeInsets.fromLTRB(
                                leftInset,
                                14,
                                0,
                                14,
                              ),
                              child: _buildNavigation(
                                counts,
                                railWidth,
                                motion,
                              ),
                            ),
                            Expanded(child: _buildLibrary(compact, motion)),
                          ],
                        ),
                        Positioned(
                          left: leftInset + railWidth + 4,
                          bottom: 14,
                          width:
                              (constraints.maxWidth -
                                      leftInset -
                                      railWidth -
                                      14)
                                  .clamp(0.0, 330.0),
                          child: IgnorePointer(
                            ignoring: !_settingsOpen,
                            child: ExcludeFocus(
                              excluding: !_settingsOpen,
                              child: ExcludeSemantics(
                                excluding: !_settingsOpen,
                                child: AnimatedSlide(
                                  offset: _settingsOpen
                                      ? Offset.zero
                                      : const Offset(-0.025, 0.04),
                                  duration: motion,
                                  curve: Curves.easeOutCubic,
                                  child: AnimatedOpacity(
                                    opacity: _settingsOpen ? 1 : 0,
                                    duration: motion,
                                    child: _buildSettings(),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _onEscape() {
    if (_settingsOpen) {
      _closeSettings();
    } else if (_previewAsset != null) {
      _closePreview();
    }
  }

  Widget _buildNavigation(
    Map<MediaKind, int> counts,
    double width,
    Duration motion,
  ) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!Platform.isWindows)
            _SurfacePanel(
              radius: 16,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(9),
                  child: Tooltip(
                    message: 'Pocket Motion View',
                    child: Image.asset(
                      'assets/pocket_motion.png',
                      width: 40,
                      height: 40,
                    ),
                  ),
                ),
              ),
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, bounds) => SingleChildScrollView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: (bounds.maxHeight - 16).clamp(
                      0,
                      double.infinity,
                    ),
                  ),
                  child: Column(
                    key: const ValueKey('media-filters'),
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisAlignment: MainAxisAlignment.center,
                    spacing: 11,
                    children: [
                      for (final entry in _mediaTabs.entries)
                        Tooltip(
                          message: entry.value.label,
                          child: Semantics(
                            selected: _filter == entry.key,
                            button: true,
                            child: AnimatedContainer(
                              duration: motion,
                              curve: Curves.easeOutCubic,
                              decoration: BoxDecoration(
                                color: _filter == entry.key
                                    ? colors.primaryContainer
                                    : colors.surface,
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Material(
                                type: MaterialType.transparency,
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(14),
                                  onTap: () => _switchFilter(entry.key),
                                  child: AspectRatio(
                                    aspectRatio: 1,
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                      ),
                                      child: Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Icon(
                                            entry.value.icon,
                                            size: 36,
                                            color: _filter == entry.key
                                                ? colors.onPrimaryContainer
                                                : colors.onSurfaceVariant,
                                          ),
                                          const SizedBox(height: 3),
                                          FittedBox(
                                            fit: BoxFit.scaleDown,
                                            child: Text(
                                              '${counts[entry.key]}',
                                              style: TextStyle(
                                                fontSize: 17,
                                                height: 1.1,
                                                fontWeight: FontWeight.w500,
                                                fontFeatures: const [
                                                  FontFeature.tabularFigures(),
                                                ],
                                                color: _filter == entry.key
                                                    ? colors.onPrimaryContainer
                                                    : colors.onSurfaceVariant,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          TapRegion(
            groupId: _settingsGroup,
            onTapOutside: _settingsOpen ? (_) => _closeSettings() : null,
            child: MouseRegion(
              onEnter: (_) => _openSettings(),
              onExit: (_) => _scheduleSettingsClose(),
              child: _SurfacePanel(
                radius: 14,
                highlight: _settingsOpen,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: IconButton(
                    isSelected: _settingsOpen,
                    color: _settingsOpen
                        ? colors.onPrimaryContainer
                        : colors.onSurfaceVariant,
                    tooltip: '目录设置',
                    icon: const Icon(Icons.settings_outlined),
                    selectedIcon: const Icon(Icons.settings),
                    onPressed: _toggleSettings,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSettings() {
    final canChangeSource = !_scanning && !_exporting;
    final colors = Theme.of(context).colorScheme;
    return TapRegion(
      groupId: _settingsGroup,
      child: MouseRegion(
        onEnter: (_) => _settingsTimer?.cancel(),
        onExit: (_) => _scheduleSettingsClose(),
        child: Card(
          margin: EdgeInsets.zero,
          color: colors.surfaceContainerLowest,
          elevation: 6,
          shadowColor: colors.shadow.withValues(alpha: 0.18),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('素材来源'),
                const SizedBox(height: 5),
                _PathCard(
                  path: _cameraDir,
                  icon: Icons.folder_open_outlined,
                  onChange: canChangeSource
                      ? () {
                          _closeSettings();
                          _pickCameraDir();
                        }
                      : null,
                ),
                const SizedBox(height: 10),
                const Text('导出位置'),
                const SizedBox(height: 5),
                _PathCard(
                  path: _outDir,
                  icon: Icons.folder_outlined,
                  onChange: !_exporting
                      ? () {
                          _closeSettings();
                          _pickOutDir();
                        }
                      : null,
                ),
                const SizedBox(height: 6),
                Wrap(
                  children: [
                    TextButton.icon(
                      onPressed: canChangeSource
                          ? () {
                              _closeSettings();
                              _scan();
                            }
                          : null,
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('重新扫描'),
                    ),
                    TextButton.icon(
                      onPressed: _logs.isEmpty ? null : _showLogs,
                      icon: const Icon(Icons.receipt_long_outlined, size: 18),
                      label: const Text('导出日志'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showLogs() {
    _closeSettings();
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导出日志'),
        content: SizedBox(
          width: 480,
          height: 300,
          child: ListView.builder(
            itemCount: _logs.length,
            itemBuilder: (context, index) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: SelectableText(_logs[_logs.length - 1 - index]),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Widget _buildExport() {
    final disabled = _exportAssets.isEmpty || _exporting || _scanning;
    final (label, action) = switch (_filter) {
      MediaKind.livePhoto => (
        _liveExportFormat.label,
        switch (_liveExportFormat) {
          _LiveExportFormat.apple => _exportApple,
          _LiveExportFormat.google => () => _exportMotion(
            MotionPhotoFormat.google,
          ),
          _LiveExportFormat.huawei => () => _exportMotion(
            MotionPhotoFormat.huawei,
          ),
        },
      ),
      MediaKind.video => ('视频', _exportVideos),
      MediaKind.photo => ('照片', _exportPhotos),
    };
    final split = _filter == MediaKind.livePhoto;
    final colors = Theme.of(context).colorScheme;
    final buttonLabel = _exporting
        ? '导出 $_doneCount/$_totalCount'
        : '导出 $label';
    final foreground = disabled ? colors.onSurfaceVariant : colors.onPrimary;
    return Material(
      color: disabled
          ? colors.onSurface.withValues(alpha: 0.09)
          : colors.primary,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: 40,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: TextButton(
                key: const ValueKey('export-primary'),
                onPressed: disabled ? null : action,
                style: TextButton.styleFrom(
                  foregroundColor: foreground,
                  disabledForegroundColor: foreground,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: const RoundedRectangleBorder(),
                ),
                child: Text(
                  buttonLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            if (split) ...[
              Center(
                child: SizedBox(
                  width: 1,
                  height: 22,
                  child: ColoredBox(color: foreground.withValues(alpha: 0.24)),
                ),
              ),
              MenuAnchor(
                style: const MenuStyle(
                  alignment: AlignmentDirectional.bottomEnd,
                ),
                menuChildren: [
                  for (final format in _LiveExportFormat.values)
                    MenuItemButton(
                      key: ValueKey(format.name),
                      leadingIcon: _liveExportFormat == format
                          ? const Icon(Icons.check, size: 16)
                          : const SizedBox(width: 16),
                      onPressed: () {
                        setState(() => _liveExportFormat = format);
                        _saveDirs();
                      },
                      child: Text(format.label),
                    ),
                ],
                builder: (context, controller, _) => Semantics(
                  label: '选择导出格式',
                  expanded: controller.isOpen,
                  child: InkWell(
                    key: const ValueKey('export-format'),
                    onTap: _exporting || _scanning
                        ? null
                        : () => controller.isOpen
                              ? controller.close()
                              : controller.open(),
                    child: SizedBox(
                      width: 39,
                      child: Icon(
                        Icons.expand_more,
                        color: foreground,
                        size: 20,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _switchFilter(MediaKind kind) {
    if (_filter == kind) return;
    setState(() {
      _filter = kind;
      _selected.clear();
      _anchorPath = null;
      _previewAsset = null;
    });
  }

  Widget _buildLibrary(bool compact, Duration motion) {
    final theme = Theme.of(context);
    final visible = _visible;
    final preview = _previewAsset;
    final allSelected =
        visible.isNotEmpty && _selected.length == visible.length;
    final inset = compact ? 12.0 : 22.0;
    const toolbarHeight = 58.0;
    const toolbarTop = 14.0;
    const toolbarBottom = 8.0;
    final overlayGallery = preview == null && visible.isNotEmpty;
    final showSummary = !_exporting && _totalCount > 0;
    final header = Padding(
      padding: EdgeInsets.fromLTRB(inset, toolbarTop, inset, toolbarBottom),
      child: ClipRRect(
        key: const ValueKey('library-toolbar'),
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          enabled: overlayGallery,
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Material(
            color: theme.colorScheme.surface.withValues(
              alpha: overlayGallery ? 0.76 : 1,
            ),
            child: SizedBox(
              height: toolbarHeight,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 12),
                    child: NavigationToolbar(
                      leading: Align(
                        alignment: AlignmentDirectional.centerStart,
                        widthFactor: 1,
                        child: Text(
                          '素材库',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleLarge?.copyWith(
                            locale: const Locale('zh', 'CN'),
                            fontWeight: FontWeight.w500,
                            letterSpacing: 0,
                            height: 1.25,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                      middle: showSummary
                          ? TextButton(
                              key: const ValueKey('export-summary'),
                              onPressed: _showLogs,
                              style: TextButton.styleFrom(
                                minimumSize: Size.zero,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 10,
                                ),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              child: Text(
                                '导出完成 · 成功 $_success · 失败 $_fail',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            )
                          : null,
                      trailing: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: compact ? 225 : 320,
                        ),
                        child: Row(
                          key: const ValueKey('library-actions'),
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            if (_selected.isNotEmpty)
                              Flexible(
                                child: Text(
                                  '已选 ${_selected.length} 项',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            if (visible.isNotEmpty && preview == null)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                                child: TextButton(
                                  style: TextButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                    ),
                                    minimumSize: const Size(0, 40),
                                    tapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  onPressed: () => setState(() {
                                    _selected.clear();
                                    _anchorPath = null;
                                    if (!allSelected) {
                                      _selected.addAll(
                                        visible.map((asset) => asset.path),
                                      );
                                    }
                                  }),
                                  child: Text(allSelected ? '取消全选' : '全选'),
                                ),
                              ),
                            Flexible(flex: 3, child: _buildExport()),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (_scanning || _exporting)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: LinearProgressIndicator(
                        value: _exporting ? _doneCount / _totalCount : null,
                        minHeight: 4,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final content = TweenAnimationBuilder<double>(
      key: ValueKey((preview != null, _filter)),
      tween: Tween(begin: 0, end: 1),
      duration: motion,
      curve: Curves.easeOutCubic,
      builder: (context, value, child) => Opacity(
        opacity: 0.55 + 0.45 * value,
        child: Transform.translate(
          offset: Offset(0, 6 * (1 - value)),
          child: child,
        ),
      ),
      child: preview != null
          ? _buildPreview(preview, visible, inset)
          : visible.isEmpty
          ? _buildEmptyState()
          : MediaGrid(
              key: PageStorageKey(_filter),
              padding: EdgeInsets.fromLTRB(
                inset,
                toolbarTop + toolbarHeight + toolbarBottom,
                inset,
                22,
              ),
              aspectRatios: [for (final asset in visible) _aspectRatio(asset)],
              itemBuilder: (context, index) =>
                  _buildAsset(visible[index], index),
            ),
    );
    if (overlayGallery) {
      return Stack(
        fit: StackFit.expand,
        children: [
          content,
          Align(alignment: Alignment.topCenter, child: header),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        Expanded(child: content),
      ],
    );
  }

  Widget _buildPreview(
    MediaAsset asset,
    List<MediaAsset> visible,
    double inset,
  ) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(inset, 0, inset, 14),
      child: LayoutBuilder(
        builder: (context, bounds) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _SurfacePanel(
                child: PreviewPane(
                  key: ValueKey(asset.path),
                  asset: asset,
                  cover: _covers[asset.path],
                  muted: _muted.contains(asset.path),
                  onMutedChanged: (mute) => _setMuted(asset, mute),
                  onCoverChanged: (cover) => _saveCover(asset, cover),
                  onMediaColor: widget.onMediaColor == null
                      ? null
                      : (color) {
                          if (_previewAsset?.path == asset.path) {
                            widget.onMediaColor?.call(color);
                          }
                        },
                  onClose: _closePreview,
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: bounds.maxHeight < 340 ? 60 : 86,
              child: RawScrollbar(
                key: const ValueKey('preview-library-scrollbar'),
                controller: _previewScroll,
                thumbVisibility: true,
                trackVisibility: true,
                interactive: true,
                scrollbarOrientation: ScrollbarOrientation.bottom,
                thickness: 8,
                radius: const Radius.circular(4),
                trackRadius: const Radius.circular(4),
                minThumbLength: 48,
                mainAxisMargin: 2,
                crossAxisMargin: 2,
                thumbColor: colors.primary.withValues(alpha: 0.64),
                trackColor: colors.primary.withValues(alpha: 0.10),
                child: ScrollConfiguration(
                  behavior: ScrollConfiguration.of(context)
                      .copyWith(scrollbars: false),
                  child: Listener(
                    onPointerSignal: _scrollPreviewLibrary,
                    child: ListView.builder(
                      controller: _previewScroll,
                      padding: const EdgeInsets.only(bottom: 16),
                      scrollDirection: Axis.horizontal,
                      itemExtent: _previewTileWidth,
                      itemCount: visible.length,
                      itemBuilder: (context, index) {
                        final item = visible[index];
                        final active = item.path == asset.path;
                        return Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Semantics(
                            selected: active,
                            button: true,
                            child: Tooltip(
                              message: item.filename,
                              child: _SurfacePanel(
                                highlight: active,
                                radius: 12,
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    Padding(
                                      padding: EdgeInsets.all(active ? 3 : 1),
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(9),
                                        child: _buildThumbnail(item),
                                      ),
                                    ),
                                    Material(
                                      type: MaterialType.transparency,
                                      child: InkWell(
                                        onTap: () => _preview(item, index),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  double _aspectRatio(MediaAsset asset) =>
      _thumbnailRatios[asset.path] ??
      asset.aspectRatio ??
      (asset.kind == MediaKind.photo ? 4 / 3 : 16 / 9);

  Widget _buildThumbnail(MediaAsset asset, {bool fitCard = false}) {
    final fit = fitCard ? BoxFit.contain : BoxFit.cover;
    if (asset.kind == MediaKind.photo && !asset.isRawPhoto) {
      return Image.file(
        File(asset.path),
        cacheWidth: 560,
        fit: fit,
        errorBuilder: (_, _, _) => const Icon(Icons.image_outlined),
      );
    }
    final cover = _covers[asset.path];
    return ThumbnailImage(
      key: ValueKey((asset.path, cover)),
      videoPath: asset.path,
      fit: fit,
      onAspectRatio: fitCard
          ? (ratio) {
              if ((ratio - _aspectRatio(asset)).abs() > 0.01) {
                setState(() => _thumbnailRatios[asset.path] = ratio);
              }
            }
          : null,
      position:
          cover?.position ??
          (asset.kind == MediaKind.livePhoto
              ? defaultCoverPosition
              : Duration.zero),
    );
  }

  Widget _buildEmptyState() {
    final color = Theme.of(context).colorScheme.primary;
    final status = _scanning
        ? '正在扫描素材…'
        : _scanError ?? (_hasScanned ? '这里还没有素材' : null);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_open_outlined, size: 38, color: color),
            if (status != null) ...[
              const SizedBox(height: 10),
              Text(status, textAlign: TextAlign.center),
            ],
            if (!_scanning &&
                !_exporting &&
                (!_hasScanned || _scanError != null)) ...[
              const SizedBox(height: 10),
              FilledButton.tonal(
                onPressed: _pickCameraDir,
                child: const Text('选择素材目录'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAsset(MediaAsset asset, int index) {
    final colors = Theme.of(context).colorScheme;
    final selected = _selected.contains(asset.path);
    final playable = asset.kind != MediaKind.photo;
    return _SurfacePanel(
      key: ValueKey(asset.path),
      radius: 12,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _buildThumbnail(asset, fitCard: true),
          Material(
            type: MaterialType.transparency,
            child: Semantics(
              label: asset.filename,
              button: true,
              child: InkWell(
                key: const ValueKey('media-preview'),
                onTap: () => _preview(asset, index),
                child: playable
                    ? const Align(
                        alignment: Alignment.bottomRight,
                        child: Padding(
                          padding: EdgeInsets.all(6),
                          child: CircleAvatar(
                            radius: 13,
                            backgroundColor: Color(0xBD182129),
                            foregroundColor: Colors.white,
                            child: Icon(Icons.play_arrow, size: 18),
                          ),
                        ),
                      )
                    : null,
              ),
            ),
          ),
          if (selected)
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: colors.primary, width: 3),
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          Positioned(
            top: 4,
            right: 4,
            child: Material(
              color: const Color(0x66182129),
              borderRadius: BorderRadius.circular(8),
              child: Checkbox(
                value: selected,
                side: const BorderSide(color: Colors.white, width: 1.6),
                activeColor: colors.primary.withValues(alpha: 0.85),
                checkColor: colors.onPrimary,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
                semanticLabel: asset.filename,
                onChanged: (_) => _onItemTap(index, asset),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SurfacePanel extends StatelessWidget {
  final Widget child;
  final double radius;
  final bool highlight;

  const _SurfacePanel({
    super.key,
    required this.child,
    this.radius = 20,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: highlight ? colors.primaryContainer : colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
        side: highlight
            ? BorderSide(color: colors.primary, width: 2)
            : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

class _PathCard extends StatelessWidget {
  final String path;
  final IconData icon;
  final VoidCallback? onChange;

  const _PathCard({
    required this.path,
    required this.icon,
    required this.onChange,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 5, 4, 5),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: colors.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Tooltip(
              message: path,
              child: Text(path, overflow: TextOverflow.ellipsis, maxLines: 1),
            ),
          ),
          TextButton(onPressed: onChange, child: const Text('更改')),
        ],
      ),
    );
  }
}
