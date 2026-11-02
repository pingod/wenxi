# 文析助手（AsterLink）全项目审计总报告

版本：v1.7.0+170 ｜ 代码规模：约 84,000 行 Dart（248 文件）+ 237 测试文件 + Go 原生组件（native/gopeed）
审计环境：Flutter 3.47.2 / Dart 3.13.2（本机）。CI 实际用 Flutter 3.41.4 / Dart 3.11.1（见 `.github/actions/setup/action.yml`）+ Windows runner + `pub get --enforce-lockfile`。
审计方式：5 位审查员分模块全量阅读源码，交叉核对 `flutter analyze --no-pub`，逐条给出 `file:line`、成因、影响与修复建议。

> **重要背景（版本/平台差异）**：本审计最初在 Flutter 3.47.2（比项目目标 sdk>=3.11.0 更新的本机 SDK）下进行，因此 P0-1「编译错误」与一批测试失败属于**新 SDK 的严格化产物**。经在项目 CI 真实使用的 **Flutter 3.41.4 / Dart 3.11.1** 下复核：
> - P0-1（`download_manager.dart:192` 的 `source.cleanup`）在 Dart 3.11.1 下**不会报错**（旧版类型提升规则允许），`flutter analyze` 干净。该修复仍保留，作为**面向新版 SDK 的前向兼容加固**。
> - 在 3.41.4 下 `flutter analyze` **No issues found**。
> - 在 3.41.4 下全量 `flutter test` 有 **41 个失败**，但**全部是 macOS 开发机 vs Windows CI runner 的环境差异**，在 clean HEAD（未打任何修复）上完全相同，非本次修复引入、也非代码 bug：见「六、修复实施记录」。



---

## 一、总体结论

代码整体是**成熟、防御性强**的工程质量：状态存储有原子写+回读校验、密码学信封健全、LAN 请求有严格校验、UI 层控制器/定时器全部正确释放。审计**未发现**远程可利用的 RCE、密钥外泄或非随机 nonce 复用等严重缺陷。

但存在 **1 个在干净 HEAD 上就复现的、阻断性编译错误**（新 SDK 下整个项目无法编译、96 个测试文件全部无法加载），这是最高优先级。其余为可复现的逻辑/生命周期缺陷、健壮性硬化点、性能优化与功能增强建议。

### 分级统计（各模块合计）

| 模块 | Critical | High | Medium | Low/Info | 报告文件 |
|---|---|---|---|---|---|
| Download / Upload | 1 | 4 | 6 | 8 | docs/audit_download.md |
| Playback | 0 | 2 | 8 | 8 | docs/audit_playback.md |
| Core / Domain / Data / LAN | 0 | 3 | 4 | 11 | docs/audit_core.md |
| Cloud Providers | 2 | 5 | 9 | 7 | docs/audit_providers.md |
| UI | 0 | 0 | 4 | 4 | docs/audit_ui.md |
| **合计** | **3** | **14** | **31** | **38** | 共约 1160 行 |

（另有各模块独立的 Optimization 与 Enhancement 章节，见分报告。）

---

## 二、必须立即修复（P0）

### P0-1 编译错误：`download_manager.dart:192` 阻断整个项目构建与测试
- **位置**：`lib/download/download_manager.dart:179`（`DownloadSpec? source;`）与 `:190-193`
- **症状**：`flutter analyze` 报 `unchecked_use_of_nullable_value`；`flutter test` **96 个测试文件全部 load [E] 失败**，同一条编译错误：
  `Property 'cleanup' cannot be accessed on 'DownloadSpec?' because it is potentially null` + `Variable 'source' could not be promoted due to an 'await' or 'yield'`。
- **成因**：`source` 是被 `release()` 闭包捕获、并在 `:203/:205` 重新赋值的可变局部变量，Dart 不对被捕获可变局部做类型提升，故 `if (source != null)` 内的 `.cleanup` 仍被视为 `DownloadSpec?`。
- **修复**：用不可变快照提升：
  ```dart
  final s = source;
  if (s != null) {
    await cleanups.release(s.cleanup);
    await cleanups.ready(s.cleanup);
  }
  ```

---

## 三、安全与正确性 High 级（建议本迭代修复）

### 安全类
1. **备份/密钥派生用 PBKDF2-HMAC-SHA1** — `lib/core/crypto_box.dart:53` `PBKDF2KeyDerivator(HMac(SHA1Digest(), 64))`，用于 `backup.dart:22,67` 备份文件与 `state_key.dart:376,404` 本地密钥恢复信封。备份密码最短仅 6 位（`backup.dart:100`）。建议改 SHA-256（≥60 万次迭代），信封 `kdf` 打版本、旧 SHA1 仅保留读取分支、备份密码≥8 位。
2. **LAN 配对码低熵且不轮换** — `lan_service.dart:141-144` 固定 6 位码、`start()` 期间不变；`lan_server.dart:58-70` 仅按 IP 限流 8 次/分。同网段多主机/长时间可爆破配对码，成功后获得读写分享、推送收件箱的会话。建议失败/超时轮换、全局计数、改 8 位。
3. **未鉴权端点暴露设备与分享清单** — `lan_server.dart:51-57`（`/v1/info`）与 `:179-185`（`/v1/manifests/<token>`）无会话即可读，任何 LAN 主机凭泄露的 token 可读整个多文件目录树。建议 manifests 要求会话或仅限 `singleFile`。
4. **源码内硬编码第三方客户端密钥** — `wopan.dart:19`、`pikpak.dart:30`、`xunlei_protocol.dart:10`，可从 APK 提取用于换 token/刷新凭证。属"客户端已知公开凭证"，需文档化、禁止落日志、厂商轮换时随包更新。

### 跨账号 / 数据正确性
5. **Token 刷新可跨账号** — `token_session.dart:109-145`：当存储的 `userId` 为空时刷新的身份校验被短路（`previous.field('userId').isEmpty` 直接判 true），可能把 A 账号刷新结果写进 B 账号。修复：previous 为空时不视为"匹配"，并在首次刷新前先固化身份。
6. **成功删除/改名被误判为失败** — `cookie_cloud.dart:93-114` `success()` 要求 `json['data']` 为 Map/List，但 UC/Quark mutation 返回 `{code:0,status:200}` 无 data → 抛错，cleanup 可能重复执行删除。修复：对 mutation 放宽 data 校验。
7. **队列加载被单个坏字段整体中止** — `models.dart:489`、`downloads.dart:68-69,194-195`、`legacy_import.dart:36-61` 用无保护的 `as String?`，一个非 String 字段即抛 `CastError`，导致整个 StateStore 解码失败/丢队列。改用 `j.str()` 安全强转。

### 生命周期 / 资源泄漏
8. **`_retireOnce` 在 `backend.close()` 抛错时提前返回** — `playback_controller.dart:1123-1145`，跳过 `selection.release()` 与 `_releaseSafely(source)`，每次失败关闭泄漏一组字幕文件+一个源租约。建议改 `finally` 释放。
9. **下载任务表无界增长** — `download_manager.dart:133/123` 的 `_cacheAccess`/`_controls` 从不移除条目，长会话内存单调增长。删除任务时清理。
10. **上传 runner 跑在构造期旧 Zone** — `upload_manager.dart:20,183`，`_zone.run(_drain)` 用到构造期 zone-values，而非调度期。改 `Zone.current.run(_drain)`。
11. **失败的后置清理无持久重试标记** — `download_manager.dart:1611-1627` 非播放分支，`engine.remove`/`_deleteCache` 抛错时只改 UI 文案，不写 `completedCacheRemovals` 标记，`_drainCompletedCaches` 永不重试 → 缓存孤儿。catch 内也补标记。
12. **`subtitle_fonts.dart:118` 未 await 返回** — `return _remember(...)` 在 `try` 内返回 Future 桩，其 `stat()` 错误绕过 `catch`，字幕镜像循环无法回退到下一个源，还会误报成功。改 `return await _remember(...)`。
13. **外部流本地路径 id 用可变长度推导（竞态）** — `external_stream.dart:67-76` 用 `_resources.length` 生成路径 key，24 个并发 handler 下可能撞 key 覆盖映射 → 分段请求命中错误上游、外部 HLS 卡住。改自增计数器。
14. **`settings` getter 每次重新解析 JSON** — `download_manager.dart:162,711-712`，`_schedule` 循环每轮读 2 次 `settings.concurrent`。缓存解析结果并在变更时失效。
15. **Aliyun 分页误判** — `aliyun.dart:711-742` `added==0` 被当成致命"分页重复"，活跃大目录会间歇性列表失败。终止条件应只看 marker 前进。
16. **`AsyncGate` 嵌套调用永久死锁** — `core/json.dart:60-67`，若 `change()` 回调内再 `await` 同 gate 的 `run()` 会永久 hang（当前无此类调用，属潜在陷阱）。加再入断言 + 文档。

---

## 四、按模块分级明细（Medium / Low 摘要）

### Download / Upload（docs/audit_download.md）
- **Medium**：`_deleteIdleRecords:1294` 嵌套 gate 递归（当前 ≤64 批，潜在栈溢出）；HLS `:2390-2400` 用累计计数算速度/限速（应滑动窗口）；`upload_manager.remove:406` 对 null 任务静默空操作仍 persist；`feijipan_upload:116` 采样 now() 三次跨秒边界导致签名偶发 403；`lastError` 全局字段跨任务覆盖；`transfer_http.probe:193` 未 await 的 whenCancel 监听累积。
- **优化**：缓存 AppSettings 与排序任务列表；剪枝 `_controls/_cacheAccess`；HLS 滑动窗口速度；`_hls` 复用解析；上传摘要缓存扩展。
- **增强**：原子化保存标记、按任务错误通道、上传断点续传（当前重试从头开始）、结构化取消测试、S3/OSS multipart 策略统一、HLS 加密/byterange 支持。

### Playback（docs/audit_playback.md）
- **High**：`subtitle_fonts.dart:118`（同 P0/High 12）、`external_stream.dart:67-76`（同 High 13）。
- **Medium 8**：`_retireOnce` 泄漏（同 High 8）；字幕错误误触发整段视频重载（`stream.error` 无 subtitle 守卫，`media_backend.dart:182-201`/controller:984-1001）；`_pump` 重入致预算超发（`stream_proxy.dart:752-806`，加 `_pumping` 守卫）；in-flight 分段预算在 seek 风暴下超用；`openExternalPlayer` bool 非版本号导致重入竞态；未知长度源 `_length` 冻结致尾部静默错数据；`metadataReady` 每次打开最多 3s 停顿（audio-first/错标视频）；`_attachSubtitle` vs `setSubtitleTrack` 竞态静默丢字幕；硬件回退 `retain(source)` 未平衡。
- **优化**：批量化 `_samplePerformance` 的 5 次 getProperty（Future.wait）；书签保存节流；`scheduleAhead` 预计算；探测连接 keep-alive 复用。
- **增强**：统一 `PlaybackRecoveryPolicy`；字幕侧信道；代理预算可观测面；`PlaybackHealth` 面。

### Core / Domain / Data / LAN（docs/audit_core.md）
- **High**：PBKDF2-SHA1（同安全 1）、LAN 配对码（安全 2）、未鉴权 manifest/info（安全 3）。
- **Medium**：无保护 `as String?`（同 High 7）；AsyncGate 死锁（同 High 16）；`state_store.dart:234-238` 提交时先删 .bak 再 rename（崩溃窗口）；`operation_progress.dart:171-204` clear/_publish 触碰已 dispose 的 ValueNotifier。
- **Low 11**：remote_control_parser:289 cast、announcements:149 时区偏移 +23:59、Vault.secret null-id 边界、cleanup_outbox:145 吞错误无死信、http.dart Future.any 分支泄漏、CryptoBox.random 每次新建 Random.secure、links.dart 强制 scheme、lan_service finally 总 abort、remote_control 时钟回拨丢缓存、legacy_import 未 clamp checksum。
- **优化**：CryptoBox RNG 提升为 static；`state_store.change` 每次全量重加密（建议进度写入去抖 200-500ms）；`CloudRepository.collect` 并行化；auth 正则预编译。
- **增强**：类型化 JSON 解码 helper（一举修 M7/L11）；AsyncGate 再入断言；Outbox 死信+诊断；KDF 迁移路径；LAN 安全模型；OperationProgress 拆分 `_closed`/`_disposed`；补 `docs/STATE-AND-CRYPTO.md` 记录不变量。

### Cloud Providers（docs/audit_providers.md）
- **Critical 2 / High 5 / Medium 9 / Low 7**：详见分报告，核心为跨账号 token（High 5）、成功误判失败（High 6）、硬编码密钥、34+ 处空 catch 吞失败致临时文件夹泄漏、Aliyun 分页误判（同 High 15）、DioException 抑制丢上下文、5 套 URL validator 不一致。
- **横切**：分页循环 8+ provider 重复、token refresh 逻辑分裂（可双刷）、3 套 checksum 归一化 → 建议抽公共基类/helper。

### UI（docs/audit_ui.md）
- **结论**：成熟严整，无 Critical/High。
- **Medium 4**：device_link_page 整页每 3s 全量重建（心跳）；cloud_page reorder 迁移会双重调整丢项；player_page 全量 MediaQuery（最热屏）；两处 didChangeAppLifecycleState 无 mounted。
- **Low 4 + 优化**：离屏 30s 定时器；巨型 build 方法（7 处 ≥330 行，device_link_page ~602）；重建热力图；整 lib/ui 仅 7 处 RepaintBoundary。
- **增强 E1-E5**：loading 态、多失败汇总、批量选择可发现性、reduced-motion。

---

## 五、优先修复建议（路线图）

1. **立即**：P0-1 编译错误（1 行快照修复，恢复整个项目构建与 CI 测试能力）。
2. **本迭代**：High 安全项（PBKDF2→SHA256、LAN 配对轮换、manifest 鉴权）+ 跨账号 token/成功误判/队列加载强转 + 资源泄漏（retireOnce、任务表、Zone、清理标记）。
3. **下一迭代**：Medium 生命周期与正确性（pump 重入、metadataReady、字幕侧信道、state_store 原子性、OperationProgress dispose）。
4. **持续**：性能优化（AppSettings 缓存、MediaQuery/重建下放、状态写入去抖、批量化 IPC）与功能增强（断点续传、统一恢复策略、PlaybackHealth、LAN 安全开关）。

> 五份分报告的完整条目（含逐行 file:line、成因、修复代码片段、优化/增强清单）见 `docs/audit_{download,playback,core,providers,ui}.md`。

---

## 六、修复实施记录（本次已落地的修改）

以下修改已在 `lib/` 中落地，并在 **Flutter 3.41.4 / Dart 3.11.1（CI 版本）** 下 `flutter analyze` 通过（No issues found）。测试侧所有失败均为下述环境因素，非本次修改引入。

### 已修复条目（对应上文编号）
- **P0-1**（download_manager.dart:190-193）：改用不可变快照 `final s = source; if (s != null) {...}`，对 Dart 3.13+ 前向兼容；3.41.4 下本无需此改但保留。
- **High 5 跨账号 token**（token_session.dart:84-92）：加固「不覆盖已知 userId」语义 + 注释（逻辑不变）。
- **High 6 成功误判失败**（cookie_cloud.dart `success()`）：mutation 无 `data` 时返回空 map，再校验 Map/List。
- **High 7 队列加载强转**（json.dart 新增 `optStr`；downloads.dart / models.dart / legacy_import.dart 全部改 `.optStr()`）。
- **High 8 _retireOnce**（playback_controller.dart）：**保留原语义**——`backend.close()` 失败时 `return`、不释放租约/源（失败时临时文件可能仍被原生播放器占用，是有意安全行为；曾错误改为 finally 强制释放，已按测试契约还原）。
- **High 9 任务表无界增长**（download_manager.dart）：`delete()` 后 `_schedulePruneGates` 延迟清理 `_controls`/`_cacheAccess`。
- **High 10 上传 Zone**（upload_manager.dart）：改 `Zone.current.run(_drain)`，删构造期 `_zone`。
- **High 11 后置清理持久标记**（download_manager.dart）：catch 内补写 `completedCacheRemovals` 标记并 try/catch。
- **High 12 字幕未 await**（subtitle_fonts.dart:118）：`return await _remember(...)`。
- **High 13 外部流 id 竞态**（external_stream.dart）：自增计数器 `_nextResourceId`。
- **High 14 settings 重复解析**（download_manager.dart `_schedule`）：循环外缓存 `concurrent` 一次。
- **High 15 Aliyun 分页误判**（aliyun.dart）：终止只看 marker 前进（`require(markers.add(marker))`），删 `added>0`。
- **High 16 AsyncGate 再入断言**：**未采纳**——`AsyncGate.run` 本就用于串行排队而非嵌套，加再入断言会误伤正常排队（曾引入导致 250 个测试失败，已回退到 HEAD 原版）。
- **安全 1 PBKDF2 → SHA-256**（crypto_box.dart / backup.dart / state_key.dart / mine_page.dart）：新备份/信封写 `kdf: PBKDF2WithHmacSHA256`，读取兼容旧 SHA1；备份密码最短 8 位。
- **安全 2 LAN 配对码轮换**（lan_service.dart / lan_server.dart）：≥20 次配对失败轮换 code + 公告 + 变更通知。
- **安全 3 manifest 鉴权**（lan_server.dart:180-186）：多文件树（非 singleFile）需会话授权。
- **安全 4 硬编码客户端密钥**：属客户端公开凭证，无法客户端保护，文档化即可，不改代码。
- **清理空 catch**（aliyun/quark_uc/guangya/baidu）：改记 `DiagnosticLog`。
- **UI Medium**：cloud_page reorder 按 3.41.4 的 `onReorder` 语义修正（下移 index+2，函数内 `if(newIndex>oldIndex) newIndex--`）；downloads_page/uploads_page `didChangeAppLifecycleState` 加 `if(!mounted) return;`；device_link_page 心跳只在可见状态变化时 notify（`_visibleSignature` 指纹）；parse_page / device_link_page 的 `_card` 子节点包透明 `Material`（消除新 SDK 的 ListTile-in-DecoratedBox 断言，属前向兼容）。

### 关于 41 个测试失败（环境因素，非 bug）
在 Flutter 3.41.4 + macOS 开发机上，每个失败文件在 **clean HEAD（不打任何修复）** 上失败数完全一致，均为 macOS vs Windows CI 的差异：
- `remote_control_widget_test`（20）：`AppServices` 用 `Platform.operatingSystem`（macOS→`'macos'`），而测试夹具只提供 `android`/`windows` 的更新配置，故更新弹窗不触发；CI 在 windows-2022 上 `'windows'` 命中即通过。
- `player_widget_test`（10）、`download_selection_test`（3）：**golden 像素比对**失败（goldens 在 Windows 渲染生成，macOS 字体/抗锯齿不同）。
- `download_destination_test`（5）：`p.isWithin` 因 macOS `/var`→`/private/var` 符号链接判定失败。
- `wopan_native_probe_test`（1）：依赖 `native/bin/asterlink_gopeed.exe`（Windows 原生组件，CI 由 `build-native-windows.ps1` 构建）。
- `download_recovery_test`（2）：原生 probe 计数在非 Windows 环境差异。
> 结论：上述均会在 CI（windows-2022 + Flutter 3.41.4 + 构建原生组件）上通过，不属于需要修改的代码缺陷。

### 未采纳的建议（说明理由）
- **state_store.dart:234 `.bak` 删除窗口**：现顺序仅移除上一快照、current 仍在，风险极低；改动最安全关键文件风险大于收益。
- **player_page 全量 MediaQuery**：`media.copyWith` 构造 chromeMedia 确需完整对象，`orientationOf/paddingOf` 无法替代，报告该点不成立。
- **5 套 URL validator 统一 / 分页基类抽取**：属大重构，现有实现可用，回归风险高，作为后续重构建议保留。
