# Pocket Motion

Pocket Motion 从 DJI Osmo Pocket 4 和 Pocket 4P 的相机素材恢复实况照片，并提供桌面预览和批量导出。此项目源自 [MicageEritc/Pocket-Motion](https://github.com/MicageEritc/Pocket-Motion)。

## 此 fork 新增

- 识别 Pocket 4 原始 MP4 中的实况模板，兼容横拍和竖拍，也支持上游已有的 Pocket 4P 素材。
- 在电脑上预览实况、视频和照片。实况胶片可以拖动逐帧选封面，也可以恢复默认封面。
- 实况与视频支持有声预览。可按素材设置静音，导出沿用各自的静音设置。
- 新增华为动态照片导出。Apple 实况、Android 动态照片和华为动态照片都使用所选封面。
- 素材库用紧凑的 Bento 卡片完整显示横竖素材。预览会从画面提取低饱和度主题色，取色时跳过近黑区域。Windows 版使用自定义标题栏，可拖动、最大化和从边缘缩放。

## Windows 便携版

支持 Windows 10 和 11。下载 Windows x64 ZIP，完整解压后运行 `PocketMotion.exe`。[下载页面](https://github.com/jhzhaha/Pocket-Motion/releases/latest)

1. 悬停或点击左下角的齿轮，设置素材目录和「导出位置」。素材目录选择存放原始 MP4 的那一层，例如存储卡上的 `DCIM/DJI_001`。左栏可切换实况、视频和照片。
2. 点击卡片打开预览。在底栏用滚轮或拖动横向滚动条浏览素材，点击缩略图切换。按 Esc 或右上角关闭按钮返回素材库。
3. 预览实况时拖动胶片上的播放头，找到想用的帧后点击「设为封面」。用旁边的恢复按钮回到默认封面。需要静音导出时，点预览顶部的喇叭图标。
4. 勾选卡片右上角可批量选择，支持 Shift 连选和「全选」。预览时未勾选任何素材，导出按钮会处理当前素材。
5. 导出实况前，用主按钮旁的箭头选择 Apple、Android 或华为格式。点击主按钮按上次选定的格式导出。导出完成后，齿轮菜单里的「导出日志」可查看失败详情。

| 导出格式 | 文件 | 目录 |
| --- | --- | --- |
| Apple 实况 | 配对的 HEIC 和 MOV | `live/` |
| Android 动态照片 | 带内嵌视频的 JPG | `live/` |
| 华为动态照片 | 带内嵌视频的 JPG | `live/huawei/` |
| 视频 | MP4 | `movie/` |
| 照片 | 原文件 | `photo/` |

将 Apple 实况的 HEIC 和 MOV 配对文件一起导入 Apple 照片。Android 动态照片可用 Google 相册打开。华为动态照片可通过 USB 或华为分享把 JPG 原文件传到手机，在图库中打开并长按播放。

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
