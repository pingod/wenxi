# Windows 拖拽上传适配

来源：MixinNetwork/flutter-plugins 的 desktop_drop 0.8.4，2026-10-17 从官方 pub.dev 发布包取得，Apache-2.0，原始许可保留于 LICENSE。

发布包：https://pub.dev/api/archives/desktop_drop-0.8.4.tar.gz

保留上游 Dart 接口与 Windows 插件，只注册 Windows 平台；删除发布包的 workspace 声明以便作为本地依赖。其余平台未接入此插件的原生实现。

Windows 补丁：

- 使用 DragQueryFileW 查询实际路径长度，按 WCHAR 个数分配缓冲区，修正上游固定 MAX_PATH 缓冲区却按字节数传入容量的问题。
- UTF-16 到 UTF-8 转换检查返回长度，不对空字符串索引；不输出本地完整文件路径。
- 原生拖放只接受文件数据并返回 DROPEFFECT_COPY，避免 Explorer 将上传视为移动并删除原文件。
- 取松手坐标重新发送 updated，避免遗漏最后一次 DragOver 导致错误命中。
- 插件释放前主动 RevokeDragDrop，再释放自身引用；平衡 OleInitialize/OleUninitialize，清理过程可重复调用。

应用层仅在可上传且可见的网盘目录启用接收，分享、搜索和目标目录选择页面不触发上传。拖入的文件仍由原有上传队列校验和传输。
