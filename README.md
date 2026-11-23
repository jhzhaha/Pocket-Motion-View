# Pocket Motion

Pocket Motion 从 DJI Osmo Pocket 4 和 Pocket 4P 的相机素材恢复实况照片，并提供桌面预览和批量导出。此项目源自 [MicageEritc/Pocket-Motion](https://github.com/MicageEritc/Pocket-Motion)。

## Windows 便携版

在 [Releases](../../releases) 下载 Windows x64 ZIP，解压整个文件夹后运行 `PocketMotion.exe`。支持 Windows 10 和 11。

1. 在左下角齿轮菜单里设置素材来源和导出位置。素材库按实况、视频、照片分类。
2. 点击卡片预览，勾选右上角复选框选中素材。可按住 Shift 连选，也可在右上角全选。
3. 实况胶片可以拖动逐帧定位，再点击「设为封面」。实况和普通视频的静音开关按素材设置，导出时同步应用。
4. 实况的格式通过导出按钮旁的箭头切换。点击主按钮会使用上次选定的格式。

| 导出格式 | 文件 | 目录 |
| --- | --- | --- |
| Apple 实况 | 配对的 HEIC 和 MOV | `live/` |
| Android 动态照片 | 带内嵌视频的 JPG | `live/` |
| 华为动态照片 | 带内嵌视频的 JPG | `live/huawei/` |
| 视频 | MP4 | `movie/` |
| 照片 | 原文件 | `photo/` |

将 Apple 实况的配对文件一起导入 Apple 照片。华为动态照片可通过 USB 或华为分享传原文件，在图库中长按试播。

## 兼容性

- Pocket 4 和 Pocket 4P 根据原视频中的 DJI 实况模板识别。Pocket 4 素材在 Windows 上验证过识别和导出。Pocket 4P 是上游项目的实机验证基准。
- 华为动态照片试播样本已在 Mate 60（HarmonyOS 7.0）图库确认播放。
- Windows 是此版本的验证平台。仓库也保留了上游的 macOS 工程。

## 本地构建

使用 Flutter 3.47.0。Windows 需要带「使用 C++ 的桌面开发」工作负载的 Visual Studio，macOS 需要 Xcode。

```bash
flutter pub get
flutter analyze
flutter test
flutter build windows --release
```

Windows 便携包使用独立的 FFmpeg 9.1 Essentials 工具。手动构建时可以将 `ffmpeg.exe` 和 `ffplay.exe` 放在应用旁，或通过 PATH 提供。构建配置、GPL v3 许可证和源码版本可在 Gyan 的发行包中找到。[Windows 工具发行包](https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-9.1-essentials_build.zip) · [FFmpeg 源码](https://github.com/FFmpeg/FFmpeg/tree/74e4393595)

Pocket Motion 依据上游声明使用 [MIT License](LICENSE)。
