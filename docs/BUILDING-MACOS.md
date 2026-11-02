# macOS 编译与运行

macOS 桌面版使用与 Windows / Linux 相同的 Flutter 界面和同一个 Gopeed 下载内核，构建产物是 `build/macos/Build/Products/Release/asterlink.app`。当前状态：Dart 层已放行 macOS（`isDesktopPlatform` 含 `Platform.isMacOS`），下载内核可原生编译为 Mach-O，`flutter analyze` 无 error/warning；**最终 App 必须在装有完整 Xcode 的 Mac 上构建**（仅 Command Line Tools 无法用 `xcodebuild` 构建 Flutter macOS App）。

## 依赖

| 项目 | 版本 / 说明 |
| --- | --- |
| Flutter | 3.41.4 及以上（需开启 macOS 桌面支持） |
| Xcode | 完整安装（App Store 或 developer.apple.com），`xcode-select -p` 应指向 Xcode |
| Go | 1.24.7 及以上（编译下载内核） |
| Python | 3.x（构建脚本解析 `config/*.json`） |

首次构建前：

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
flutter config --enable-macos-desktop
flutter doctor            # 确认 Xcode 一项通过
```

## 编译

```bash
./tool/build-macos.sh                        # 使用 config/build.community.json
./tool/build-macos.sh --offline              # 不配置在线公告、更新和远程控制地址
./tool/build-macos.sh --build-config .local/build-config.json
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./tool/build-macos.sh
```

脚本依次执行版本检查、`flutter pub get --enforce-lockfile`、`tool/build-native-darwin.sh` 和 `flutter build macos --release`，最后把下载内核复制进 `.app` 并按需签名（未设置 `CODESIGN_IDENTITY` 时仅 ad-hoc 签名，供本机测试）。

只重新编译下载内核：

```bash
./tool/build-native-darwin.sh            # 输出 native/bin/asterlink_gopeed（Darwin/arm64）
GOARCH=amd64 ./tool/build-native-darwin.sh
```

Xcode 工程里有一个 **Copy Gopeed Helper** 构建阶段，会在 `flutter run -d macos` / `flutter build macos` 时把 `native/bin/asterlink_gopeed` 复制到 `asterlink.app/Contents/MacOS/asterlink_gopeed`（与主可执行文件同目录，Dart 侧 `desktopHelperName()` 在非 Windows 平台即按此名称查找）。若未先编译内核，该阶段会自动跳过，App 仍可启动，只是下载组件不可用。

产物说明：

| 文件 | 说明 |
| --- | --- |
| `asterlink.app/Contents/MacOS/asterlink` | 主程序 |
| `asterlink.app/Contents/MacOS/asterlink_gopeed` | 下载 / BT 内核（Darwin 独立进程，JSON over stdio） |
| `asterlink.app/Contents/Frameworks/App.framework/Resources/flutter_assets/` | Flutter 资源 |
| `asterlink.app/Contents/Frameworks/` | Flutter 引擎与插件框架，含 `media_kit_libs_macos_video` 提供的 libmpv |

打包分发：

```bash
ditto -c -k --keepParent "build/macos/Build/Products/Release/asterlink.app" AsterLink-macos.zip
# 或用 hdiutil 打成 DMG：
hdiutil create -volname "文析助手" -srcfolder "build/macos/Build/Products/Release/asterlink.app" -ov -format UDZO AsterLink.dmg
```

## 签名与公证

- 直接分发（非 App Store）必须用 Developer ID Application 证书签名，并 `xcrun notarytool submit <zip> --wait` 公证，否则 Gatekeeper 会拦截。
- 未沙盒化：`macos/Runner/Release.entitlements` 关闭了 App Sandbox（下载内核需要写入用户选择的下载目录、以子进程运行），同时声明 `network.client/server`、`files.user-selected.read-write`、`files.downloads.read-write`。若未来上架 Mac App Store，需要重新开启沙盒并逐一申请对应 entitlement。
- `com.apple.security.cs.disable-library-validation` 是为了加载 media_kit 未用同一团队证书签名的 libmpv 动态库；开启 Hardened Runtime 时保留该键。

## 平台差异

macOS 端沿用桌面分支，以下能力因缺少对应原生实现而做了降级处理，界面上相应入口会隐藏或给出说明：

| 能力 | Windows / Android | macOS |
| --- | --- | --- |
| 网页登录（内嵌浏览器） | WebView2 / 系统 WebView | 暂无内嵌浏览器，改为「系统浏览器登录 + 手动粘贴凭据」，与 Linux 一致（`supportsWebLoginUi` 为 false） |
| 定位下载文件 | 资源管理器 `/select,` | `open -R`，在访达中选中文件 |
| 下载完成后关机 / 休眠 | `shutdown.exe` | `osascript ... shut down` / `pmset sleepnow` |
| 自动更新 | APK / EXE / ZIP | 接受 DMG / ZIP，远程配置需新增 `updates.macos` 段，否则仅提示浏览器更新 |
| 托盘图标 | `.ico` | 用资源包里的 `app.png` 复制到临时目录后加载 |
| 窗口标题栏主题 | Win32 标题栏重绘 | 使用系统外观，不做自定义重绘 |
| 系统代理 | 读取系统代理 | Dart 直连（不注入系统代理适配器） |
| 存储卷枚举 | 磁盘卷 | 不提供（`WindowsStorage` 在非 Windows 返回 null） |

托盘缺失或初始化失败时程序仍可正常使用：`main.dart` 的 `_desktop()` 已用 try/catch 包裹，失败只记录日志不崩溃。

## 测试

```bash
flutter test --no-pub
flutter test --no-pub test/native_integration_test.dart   # 需要 native/bin/asterlink_gopeed
```

需要 helper 的测试会读取 `native/bin/asterlink_gopeed`，可用 `ASTERLINK_GOPEED_TEST_EXE` 指定其它路径。请先执行 `./tool/build-native-darwin.sh`。

原生播放测试在 macOS 上依赖 media_kit 提供的 libmpv；部分 golden / 平台差异测试在 macOS 开发机上会与 Windows CI runner 结果不同（像素、`Platform.operatingSystem`、`.exe` 探针等），属环境差异，以 Windows CI（`windows-2022`）为准。

## 已知限制

- 本机若仅有 Command Line Tools 而无完整 Xcode，`flutter build macos` 会在 `xcodebuild` 阶段失败；需在装有 Xcode 的 Mac 上完成最终构建、签名与公证。
- 目前未提供 `.github/workflows` 的 macOS 构建任务；如需 CI 产物，可在 `macos-14` runner 上复用 `tool/build-macos.sh`。
- 未实现 macOS 内嵌浏览器，需要网页登录的平台（115、百度、夸克、UC、移动、微云、联通等）走「系统浏览器 + 手动粘贴凭据」。
