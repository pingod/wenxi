# 编译

工具：Flutter 3.41.4 / Dart 3.11.1、Go 1.24.7。Android 需要 JDK 21、SDK 36 和 NDK 28.2.13676358；Windows 需要 Visual Studio 2022 C++ 桌面开发工具链；Linux 使用 GTK 3、clang、cmake 和 ninja，详见 [Linux 编译说明](BUILDING-LINUX.md)。安装器使用 Inno Setup 6.7.3。

在项目根目录执行：

```powershell
flutter pub get
# Android 无签名构建检查
.\tool\build-android.ps1 -BuildConfig config/build.community.json -Unsigned
# Windows 完整运行目录
.\tool\build-windows.ps1 -BuildConfig config/build.community.json
# Windows 安装器
.\tool\build-windows-installer.ps1
```

Linux 使用对应的 shell 入口，产物是完整的运行目录：

```bash
./tool/build-linux.sh
```



缺少原生库时脚本会自动从源码构建。Android 可安装的正式包需要自己的签名，格式参考 `keystore.properties.example`。

## 本机正式版

正式配置放在 `.local/build-config.json`，原签名配置放在 `.local/keystore.properties`。使用原包名与原签名才能覆盖已有安卓正式版。

```powershell
.\tool\build-official.ps1 -Platform all -Force
```

该入口固定读取本机正式配置，不会回退公开模板。配置与签名、账号备份和日志不上传 GitHub。

百度下载与播放需要配置取链服务：复制 `config/baidu-api.example.json` 到 `.local/baidu-api.defines.json`，填写服务地址、服务端 RSA 公钥模数（十六进制）和客户端访问码。构建脚本自动加载该文件；直接使用 Flutter 编译时加上 `--dart-define-from-file=.local/baidu-api.defines.json`。未配置时会明确提示百度取链服务未配置。服务端私钥和私有实现不随 App 发布。

## 输出位置

| 产物 | 路径 |
| --- | --- |
| Android APK | `build/app/outputs/flutter-apk/app-release.apk` |
| Windows 运行目录 | `build/windows/x64/runner/Release/` |
| Windows 安装器 | `build/windows/installer/` |
| Linux 运行目录 | `build/linux/x64/release/bundle/` |

便携使用时保留完整运行目录，不能只复制 EXE。

更新链接的配置与安装行为见 [App 内更新](IN-APP-UPDATE.md)。
