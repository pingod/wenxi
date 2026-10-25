# Linux 编译与运行

Linux 桌面版使用与 Windows 相同的 Flutter 界面和同一个 Gopeed 下载内核，构建产物是 `build/linux/x64/release/bundle/` 目录。当前状态：编译、启动、下载内核与单元测试通过；网页登录等少数能力仍只存在于 Windows / Android，原因见下方「平台差异」。

## 依赖

| 项目 | 版本 / 说明 |
| --- | --- |
| Flutter | 3.41.4（Dart 3.11.1） |
| Go | 1.24.7 |
| 系统库 | GTK 3、clang、cmake ≥ 3.13、ninja、pkg-config |
| 可选 | `libayatana-appindicator3` / `libappindicator3`（托盘图标）、`xdg-utils`（打开文件管理器）、`systemd`（下载完成后关机） |

Arch：

```bash
sudo pacman -S clang cmake ninja pkg-config gtk3 libayatana-appindicator xdg-utils
```

Debian / Ubuntu：

```bash
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev \
  libayatana-appindicator3-dev libsecret-1-dev xdg-utils
```

`flutter doctor` 的 Linux toolchain 一项应全部通过后再编译。

## 编译

```bash
./tool/build-linux.sh                     # 使用 config/build.community.json
./tool/build-linux.sh --offline           # 不配置在线公告、更新和远程控制地址
./tool/build-linux.sh --build-config .local/build-config.json
```

脚本依次执行版本检查、`flutter pub get --enforce-lockfile`、`tool/build-native-linux.sh` 和 `flutter build linux --release`。默认使用 `PUB_HOSTED_URL=https://pub.flutter-io.cn`，与仓库中的 `pubspec.lock` 保持一致；切换镜像会重写锁文件里的每个托管地址。

只重新编译下载内核：

```bash
./tool/build-native-linux.sh              # 输出 native/bin/asterlink_gopeed
```

产物说明：

| 文件 | 说明 |
| --- | --- |
| `build/linux/x64/release/bundle/asterlink` | 主程序 |
| `build/linux/x64/release/bundle/asterlink_gopeed` | 下载 / BT 内核，必须与主程序放在同一目录 |
| `build/linux/x64/release/bundle/data/` | Flutter 资源与 `libapp.so` |
| `build/linux/x64/release/bundle/lib/` | Flutter 引擎与插件动态库 |

便携使用时必须保留整个目录，不能只复制 `asterlink`。`linux/CMakeLists.txt` 会在缺少 helper 时直接报错，避免产出无法下载的运行目录。

运行：

```bash
./build/linux/x64/release/bundle/asterlink
```

## 平台差异

Linux 端沿用 Windows 的桌面分支（帮助进程、窗口、托盘、全屏播放），以下能力因为缺少对应原生实现而做了降级处理，界面上相应入口会隐藏或给出说明：

| 能力 | Windows / Android | Linux |
| --- | --- | --- |
| 网页登录（内嵌浏览器） | WebView2 / 系统 WebView | 暂无内嵌浏览器：需要网页登录的平台改为「系统浏览器登录 + 手动引导」，见下节 |
| 定位下载文件 | 资源管理器 `/select,` | 优先 `FileManager1.ShowItems`（D-Bus），否则 `xdg-open` 打开所在目录 |
| 分享下载文件 | 系统分享 / 分享面板 | 打开文件所在位置，由用户在文件管理器中处理 |
| 下载完成后关机 | `shutdown.exe` | `systemctl poweroff`，由 polkit 决定是否需要授权 |
| 播放器画中画 | 独立置顶窗口 | 不支持，全屏与窗口操作正常 |
| 自动更新 | APK / EXE / ZIP | 仅浏览器更新，远程配置暂无 `updates.linux` 段 |
| 托盘图标 | `.ico` | 使用资源包中的 `app.png`，需要 AppIndicator 支持 |
| 窗口标题栏 | Win32 标题栏随主题重绘 | GTK header bar 由 runner 从应用配色重绘，明暗主题都会跟随 |

托盘缺失时程序仍可正常使用：关闭窗口走「还有传输任务」对话框，可暂停并退出。

各网盘的登录方式沿用 Android / Windows 的实现，没有因为 Linux 而减少。这里有两类入口，容易混淆：

- **App 内实现的登录**：迅雷、城通、小飞机、PikPak、123、蓝奏、天翼、阿里、蓝奏优享、光鸭提供账号密码，光鸭另有短信验证码。这些不依赖浏览器，Linux 上照常可用。
- **网页登录**：在 App 内嵌的网盘官网页面里完成登录，完成后读取 Cookie。网页里出现扫码、短信、密码等多种方式，是网盘自己提供的，不是 App 的入口。115、百度、夸克、UC、移动、微云、联通在 App 内没有账号密码接口，只能走这一类。

夸克和光鸭各有一个登录步骤需要官方网页（夸克的安全验证滑块、光鸭的验证码页面），Linux 上没有内嵌浏览器就打不开这两个页面：

- 夸克：登录页默认进入扫码登录，手机号登录按钮置灰并说明原因。二维码有效期跟随服务端（约 175 秒），快到期时自动换发新码（最多 12 轮），不需要手点「重新获取二维码」。
- 光鸭：短信验证码登录在需要安全验证时会提示「没有内嵌浏览器」，账号密码登录不受影响；两者都可以改用网页登录或手动填写凭据。

Linux 目前没有内嵌浏览器，所以第二类改成「系统浏览器登录」：由 `xdg-open` 打开网盘官网，用户在系统浏览器里登录后，把 Cookie 或 Token 复制回 App；第一类不受影响。Linux 的手动登录页会多出一块引导面板（Windows / Android 有内嵌浏览器，不显示这块面板）：

1. 点「打开官网」，用系统默认浏览器打开该网盘的登录页（`url_launcher` → `xdg-open`）。
2. 面板按平台说明凭据放在哪里：115、百度、夸克、UC、移动、天翼、微云、蓝奏是 Cookie，迅雷、阿里、光鸭、小飞机、PikPak、蓝奏优享是网站 Local Storage 里的一段 JSON，123、城通是单个 Token，GitHub 是个人访问令牌。
3. 用户在浏览器里按 F12 复制对应值；面板在打开官网后每秒读一次剪贴板，识别到符合该平台规则的凭据就在面板里提示「已从剪贴板读取到…凭据」，点「填入」写进输入框，再点「验证并保存」交给原有登录流程校验。

剪贴板的读取只发生在用户点了「打开官网」之后，识别在本机完成、不会上传，识别到第一份凭据或用户点「停止读取剪贴板」就停止。除 GitHub 外，所有平台都能从官网走这条路；引导的步骤与校验规则来自 `lib/domain/login_guide.dart`，与手动粘贴共用同一套校验（`LoginCredentials`）。

## 测试

```bash
flutter test --no-pub
# 使用真实 Gopeed helper 的集成测试
flutter test --no-pub test/native_integration_test.dart
```

需要 helper 的测试会读取 `native/bin/asterlink_gopeed`（Windows 为 `.exe`），可用 `ASTERLINK_GOPEED_TEST_EXE` 指定其他路径。请先执行 `./tool/build-native-linux.sh`。

原生播放测试（`native_playback_test.dart`、`native_playback_recovery_test.dart`、`native_screenshot_test.dart`）在 Linux 上使用系统 `libmpv`（`mpv` 包提供），会自动探测 `/usr/lib/libmpv.so.2` 等常见路径，也可以用 `ASTERLINK_MPV_LIBRARY` 指定。`native_subtitle_render_test.dart` 的像素断言基于 Windows 固定版本的 libmpv，在其它 libmpv 版本上可能因渲染差异失败，仍在 Linux 上跳过。

## 发布打包

```bash
python tool/package-release.py --platform linux
python tool/package-release.py --checksums
```

生成 `.local/release-assets/asterlink-<版本>-linux-x64.tar.gz` 与 `SHA256SUMS.txt`。使用 tar.gz 而不是 zip，因为 zip 不保存 Unix 权限，解压后会丢失 `asterlink` 与 `asterlink_gopeed` 的可执行位。

## 已知限制

- 未提供 AppImage / Flatpak / deb 打包脚本；发布物是压缩后的完整运行目录。
- Linux 构建没有独立的 `APPLICATION_ID` 构建参数，桌面文件与 GApplication ID 固定为 `linux/CMakeLists.txt` 中的值。
- 百度取链服务同样是可选配置：复制 `config/baidu-api.example.json` 到 `.local/baidu-api.defines.json`，`tool/build-linux.sh` 会自动加载。
