# macOS 编译与运行

macOS 桌面版使用与 Windows / Linux 相同的 Flutter 界面和同一个 Gopeed 下载内核，构建产物是 `build/macos/Build/Products/Release/文析助手.app`（bundle id `com.asterlink.app`）。当前状态：Dart 层已放行 macOS（`isDesktopPlatform` 含 `Platform.isMacOS`），下载内核可原生编译为 Mach-O，`flutter analyze` 无 error/warning；**最终 App 必须在装有完整 Xcode 的 Mac 上构建**（仅 Command Line Tools 无法用 `xcodebuild` 构建 Flutter macOS App）。

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

Runner 工程（`macos/Runner/Configs/AppInfo.xcconfig` 的 `PRODUCT_NAME = 文析助手`）没有负责拷贝下载内核的构建阶段，所以内核由 `tool/build-macos.sh` 在 `flutter build macos` 之后复制到 `文析助手.app/Contents/MacOS/asterlink_gopeed`（与主可执行文件同目录，Dart 侧 `desktopHelperName()` 在非 Windows 平台即按此名称查找）。直接 `flutter run -d macos` 不会带上内核，App 仍可启动，只是下载组件不可用。

产物说明：

| 文件 | 说明 |
| --- | --- |
| `文析助手.app/Contents/MacOS/文析助手` | 主程序（可执行文件名取自 `PRODUCT_NAME`） |
| `文析助手.app/Contents/MacOS/asterlink_gopeed` | 下载 / BT 内核（Darwin 独立进程，JSON over stdio） |
| `文析助手.app/Contents/Frameworks/App.framework/Resources/flutter_assets/` | Flutter 资源 |
| `文析助手.app/Contents/Frameworks/` | Flutter 引擎与插件框架，含 `media_kit_libs_macos_video` 提供的 libmpv |

打包分发：

```bash
ditto -c -k --keepParent "build/macos/Build/Products/Release/文析助手.app" AsterLink-macos.zip
# 或用 hdiutil 打成 DMG：
hdiutil create -volname "文析助手" -srcfolder "build/macos/Build/Products/Release/文析助手.app" -ov -format UDZO AsterLink.dmg
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

## 持续集成（GitHub Actions）

`.github/workflows/packages.yml` 的 `macos` job 在 `macos-14`（Apple Silicon）runner 上运行 `./tool/build-macos.sh --build-config config/build.community.json`：脚本会编译 Darwin/arm64 下载内核、`flutter build macos`，并用 ad-hoc 签名产出 `文析助手.app`。随后 job 校验 `Contents/MacOS/文析助手`、`Contents/MacOS/asterlink_gopeed`（须为 Mach-O）、`codesign --verify --deep --strict`，再 `python3 tool/package-release.py --platform macos` 打成 `asterlink-<版本>-macos-arm64.zip`（`ditto -c -k --keepParent`，保留可执行位与符号链接），上传为 `package-macos` artifact。该 job 触发条件与 linux/windows 一致（push 到 `feat/**`、`main`、`master`，PR 到 `main`/`master`，或手动）。

CI 产物只是**未公证**的 ad-hoc 签名包，用于验证「能编译、能打包」，不能直接分发（Gatekeeper 会拦截）。正式分发的签名 + 公证在下面「发布」说明。

## 发布（签名 + 公证）

`.github/workflows/release.yml` 的 `package` job 用 matrix 在 `windows-2022` 上构建 android/windows、在 `macos-14` 上构建 macOS（tag `v*` 触发）。macOS 那一步在存在证书密钥时完成 Developer ID 签名：

| Secret | 说明 |
| --- | --- |
| `MACOS_CERTIFICATE_P12_BASE64` | Developer ID Application 证书导出为 .p12 后 base64（单行） |
| `MACOS_CERTIFICATE_PASSWORD` | 上述 .p12 的密码 |
| `MACOS_KEYCHAIN_PASSWORD` | 临时 keychain 的解锁密码，可任意 |
| `MACOS_CODESIGN_IDENTITY` | 形如 `Developer ID Application: Your Name (TEAMID)` |

未配置 `MACOS_CERTIFICATE_P12_BASE64` 时，release job 仍会 ad-hoc 签名并产出 zip（等同 packages.yml 的产物），只是不能分发。配置后 `tool/build-macos.sh` 会读取 `CODESIGN_IDENTITY` 用 Developer ID 签名。

**公证仍需手动一次**（CI 的公证凭据差异较大，未固化到脚本）：`xcrun notarytool submit <zip> --apple-id ... --team-id ... --password <app 专用密码> --wait`，成功后 `xcrun stapler staple <zip 或 .app>`。凭据可放 Apple Developer Program 的 app-specific password 或 App Store Connect API Key。

## 本地密钥与签名

本地状态密钥（用于解密 `state-v1.enc`）在 macOS 上与 Android 一样存放在应用私有目录
`AsterLink/state-keys-private-v1/<namespace>/{primary,copy}.bin`，指针写入
`state-key-location.json`（`backend: "android-private-files-v1"`），**不再使用系统钥匙串**。

这样做是因为登录钥匙串的 ACL 只信任创建该条目的那份代码签名：ad-hoc 签名每次构建的
cdhash 都会变化，于是新构建读取上一版写入的条目时 macOS 会弹出「允许访问钥匙串」对话框。
无人应答时每次读取约 9 s 超时、`LocalStateKey._read` 会重试 3 次，启动因此卡顿 20–28 s；
若最终被拒绝，新版本就无法再打开旧数据。

历史背景（仍适用于迁移路径）：插件默认使用 *data protection keychain*
（`kSecUseDataProtectionKeychain`），该钥匙串要求应用带有 `keychain-access-groups` 授权，
只有通过 provisioning profile 签名的构建才有。ad-hoc 与 Developer ID 构建写入时返回
`errSecMissingEntitlement (-34018)`，表现为启动即停在「启动恢复 / 应用暂时无法启动」。
`lib/data/state_store.dart` 因此显式设置 `MacOsOptions(usesDataProtectionKeychain: false)`，
旧版安装遗留的钥匙串条目仍能被读出来并迁移到私有目录（`state_key.storage_migrated` 事件）。

**不要**给 `macos/Runner/*.entitlements` 添加 `keychain-access-groups`：缺少匹配的
provisioning profile 时，内核会因该授权不合法直接以 SIGKILL 终止进程（实测 `Killed: 9`，
同时 `codesign -v` 仍然通过）。

## 已知限制

- 本机若仅有 Command Line Tools 而无完整 Xcode，`flutter build macos` 会在 `xcodebuild` 阶段失败；CI 已用 `macos-14` runner 覆盖正式构建。
- CI 的 macOS 产物是 ad-hoc 签名、未公证的 zip，仅供验证与内部测试；对外分发需配置 `MACOS_*` secrets 走 `release.yml` 并用 `notarytool` 公证。
- 未实现 macOS 内嵌浏览器，需要网页登录的平台（115、百度、夸克、UC、移动、微云、联通等）走「系统浏览器 + 手动粘贴凭据」。
- 首次写入 `~/Downloads/AsterLink` 时 macOS 可能弹出「访问下载文件夹」的隐私授权；拒绝后下载会失败，需在「系统设置 → 隐私与安全性 → 文件与文件夹」中放开。
