# Playback Subsystem Audit — `lib/playback/`

Scope: `lib/playback/` — 20 files, 6004 lines (playback_controller.dart 1589, stream_proxy.dart 1117, media_backend.dart 884, plus 17 smaller files).

Method: full read of all 20 files with the `read` tool; `flutter analyze --no-pub lib/` corroboration; manual tracing of controller↔backend↔proxy lifecycles and the UI call sites (`lib/ui/player_page.dart`, `lib/platform/playback_device.dart`) where a playback finding depends on caller behaviour.

Tooling baseline: `flutter analyze --no-pub lib/` reports exactly five issues, three of which are in playback scope:
- `subtitle_fonts.dart:118:9 • unawaited_return_in_try_block` (the task anchor)
- `download_manager.dart:192:37 • unchecked_use_of_nullable_value` (out of scope — download teammate's task-1)
- `cloud_page.dart:537:21 • deprecated_member_use` (out of scope — UI teammate's task-5)

The rest of the findings below are logic/lifecycle issues the analyzer does not catch.

Severity counts: **Critical 0 · High 2 · Medium 10 · Low/Info 8** (20 findings) + Optimization and Enhancement sections.

---

## Critical

_None._ No crash-on-every-use, data-loss, or security boundary defect was found in this subsystem. The highest-impact items are resource-lifecycle leaks (below). A null-deref exists but at a design-time fault location (Low 12).

---

## High

### H1. `subtitle_fonts.dart:116-124` — `return _remember(...)` inside `try` returns an unawaited Future, so its errors escape the catch (the anchor warning is a REAL latent bug)

```dart
115  for (final url in _downloadUrls) {
116    try {
117      await _download(url, target);           // download validated HERE
118      return _remember(                        // <-- stub returned without await
119        SubtitleFont(target.path, 'Noto Sans SC', SubtitleFontOrigin.download),
120      );
121    } catch (error, stack) {
122      failure = error;                         // <-- never reached for _remember errors
...
136  throw FileSystemException('Subtitle font download failed: $failure');
```

- **Symptom:** `flutter analyze` → `unawaited_return_in_try_block` at `subtitle_fonts.dart:118:9`. Function signature is `Future<SubtitleFont> _ensureAvailable() async`, so the `return` of a `Future` from an `async` body returns its *stub* (`return;`) immediately; `_remember`'s future keeps running detached.
- **Why it's a bug:** `_remember` (lines 138-142) is `await File(font.path).stat()` followed by `_ready = font`. If the `stat()` throws (the freshly renamed file was removed/blocked between `_download`'s `partial.rename(target)` at line 272 and the stat — antivirus quarantine, cache cleaner, another process), the exception is **not** routed into the `catch (error, stack)` at line 121. The stub has already been returned to `_downloadTask`'s `whenComplete` (line 106-108), which clears `_downloadTask`; the worker zone then surfaces the failure as an unhandled async error. The caller (`retrySubtitleFont`, `media_backend.dart:388-389`) believes the font succeeded and calls `_applySubtitleFont(font)` against a file that may not exist, and `_ready` is never set.
- **Secondary consequence:** the `for` loop can never "fall through to the next mirror" for a `_remember` failure — the `catch`/`failure` path is bypassed, so a target-side failure looks like success.
- **Fix:** await the memory step so it participates in the try/catch:
  ```dart
  return await _remember(
    SubtitleFont(target.path, 'Noto Sans SC', SubtitleFontOrigin.download),
  );
  ```
  (Note: the same anti-pattern does *not* affect `_local()`, whose `return await _remember(...)` at lines 90 and 97-99 already correct.)

### H2. `external_stream.dart:67-76` — `_paths[upstream] ??= () { ... }()` detects the first registration with `_resources.length`, so registering the SAME upstream Uri twice produces two different local paths, one of which is orphaned

```dart
68  final path = _paths[upstream] ??= () {
69    require(_resources.length < 65536, '播放列表过大，请重新打开视频');
70    final suffix = upstream.path.toLowerCase().endsWith('.m3u8')
71        ? 'index.m3u8'
72        : 'video';
73    final path = '/$_token/${_resources.length}/$suffix';   // <-- key = current length
74    _resources[path] = upstream;
75    return path;
76  }();
```

- **Symptom:** `_register` is called by `start()` once for the root URI and again by `_rewrite()` for **every** segment/key/child-playlist URI. Every consumer rewrites the HLS playlist independently via `_rewrite` (line 287), and `_paths` is keyed by the upstream `Uri`. Two separate fetches of the same upstream (e.g. a re-fetched master and media playlist share a base, or a segment referenced by two variants) hit the `??=` guard on first insert; but the *first* insert for a distinct Uri computes the local path from `_resources.length` **before** the assignment. Because the local path must be unique per registered resource and is derived from the mutable length, a re-entrant call (two `_serve` handlers rewriting playlists concurrently — the server accepts up to 24 concurrent `_handlers`, line 227) can evaluate `_resources.length` to the same value for two different Uris, and the second `_resources[path] = upstream` **overwrites** the first mapping. The earlier playlist's rewritten segment URL then resolves to the wrong upstream.
- **Why it's a bug:** `_resources.length` is read *outside* any lock and *before* the write, and `_register` has no `await` but is invoked from multiple concurrent `_serve` futures (server.listen → unawaited `_serve`). This is a read-modify-write race: the derived path key is not atomic with the map insert. Result: a segment request can be served from a different upstream (wrong CDN shard / wrong byte range / 404), stalling external playback only under concurrent playlist parsing.
- **Fix:** make the resource id monotone and independent of map size, e.g. a private counter:
  ```dart
  int _resourceSeq = 0;
  final path = '/$_token/${_resourceSeq++}/$suffix';
  ```
  and guard against duplicates by keying on the Uri (`_paths` already does). Better: pre-register a whole playlist's children under a single synchronous pass (the `_rewrite` already does this line-by-line) and never derive ids from `_resources.length`.

> Note on impact ordering: if you consider concurrency-hardening less urgent than a definite resource leak, treat **M1/M2/M3** (definite controller/proxy leaks) as at least as important as H2.

---

## Medium

### M1. `playback_controller.dart:1123-1145` — `_retireOnce` returns early when `backend.close()` throws, skipping `selection.release()` and `source.release()`

```dart
1130  try { await session.backend.pause(); } catch (_) { /* close still stops native I/O */ }
1135  try {
1136    await session.backend.close();
1137    session.nativeClosed = true;
1138  } catch (_) {
1139    notice = '播放器关闭未完成，临时文件已保留';
1140    _changed();
1141    return;                 // <-- selection + source leases NEVER released
1142  }
1143  await session.selection.release();
1144  await _releaseSafely(session.source);
```

- **Symptom:** If `backend.close()` throws (media_kit native dispose failure, torrent `cancel`, subtitles clear error), the two lease releases are skipped. `session.selection` (which owns every attached subtitle `File`, `playback_selection.dart:19-29`) is never released, and the `DownloadSpec` source lease (cloud/BT/download) is never returned.
- **Why it's a bug:** every caller that switches videos (`_load` → `_retire(old)` line 415) or shuts down (`_close` line 1578) expects `_retireOnce` to fully reclaim. The justified intent of the early return is "keep the media readable so a retry or the OS can clean up later" — but it applies the intent to the *backend's own transport* while silently leaking the *selection files* and *source lease* forever (the `_Session` is already detached from `_session` before the call, so nothing retries). Over a binge-watching session this leaks one set of subtitle files + one source lease per failed close.
- **Fix:** release the leases in a `finally`, and only keep the native-not-closed part conditional; or at minimum still run `selection.release()` + `_releaseSafely(session.source)` before the early `return`, since a failed *backend* close does not imply the *source URL* or *selection files* must survive.

### M2. `playback_controller.dart:937` + `media_backend.dart:281,263-266` — a failed subtitle-only import marks the source `sourceFailure`, forcing a full link refresh on recoverable subtitle errors

- **Symptom:** `_attachSubtitle` (`playback_controller.dart:1392-1420`) can throw `AppException('视频已切换…')` at line 1402 *before* touching the source; but `attachSubtitle` is invoked from the UI (`player_page.dart:1279`) and the throw propagates to `_importSubtitle`'s caller. Separately, when a *cloud* subtitle download fails, `readSubtitle` (`playback_sources.dart:134`) surfaces its error through the subtitle path only.
- **Why it's a bug — the dangerous coupling:** In `media_backend.dart`, `_reportFailure` sets `_sourceFailure = value.sourceFailure` (line 320). `PlaybackFailure.sourceFailure` is true for every kind except `decoder`/`unknown` (`playback_failure.dart:20-22`), i.e. `network`, `expired`, `changed`, `paused`. `_onState` (`playback_controller.dart:984-1001`) sees `failure.refreshable` (`expired`/`network`) and issues a **full `load(..., refreshSource: true)`** — throwing away the running video and re-resolving the signed URL — for a failure that may have originated from a subtitle-only request. The proxy does scope its own failures to demanded media reads, but `TorrentMediaBackend`/`MediaKitBackend` error-stream handlers (`media_backend.dart:182-201`) attach `PlaybackFailure.fromLog(value)` for *any* `player.stream.error` line that matches the network regex, including lines emitted during a subtitle `sub-add`/`loadfile`. The regex exclusion only covers `subtitle|sub-add` on `stream.log` (line 168-172) — the `stream.error` path (line 188-200) has no subtitle guard beyond the `NativePlayer` type check.
- **Fix:** in the `stream.error` handler, apply the same `subtitle|sub-add` exclusion before `_reportFailure`; and/or drop `paused`/`changed` subtitle errors into a separate non-source-failure channel so they never set `_sourceFailure`. This prevents a cosmetic subtitle error from tearing down a healthy stream.

### M3. `stream_proxy.dart:807-806` (`_pump` reentrancy) + `:772-797` — `_pump` can be re-entered from inside the same loop via `_fetch`'s synchronous completion, and `_makeRoom` can drop a segment it is about to start

- **Symptom:** `_pump` (752) starts fetches in a `while` loop, each `_fetch` (808) ends with `_pump()` in its `finally` (954). If `readCache` (line 815) resolves synchronously (an in-memory completed-download cache hit is a `Future` that can complete in the same microtask turn under the test/loopback cases), `_fetch`'s `finally → _pump()` re-enters `_pump` while the outer `_pump` loop is still iterating the same `waiting` snapshot; two `_pump` frames then each `_active++` / `_reservedBytes += size` for segments, and can overshoot `_budget`.
- **Why it's a bug:** `_active`/`_reservedBytes` are not guarded against reentrancy; the budget check `_active >= _budget` (line 772) is evaluated per frame, so two interleaved frames can start up to `2×` the intended concurrency. This does not crash but defeats the connection budget and the memory cap (`_reservedBytes` can transiently exceed `maxCacheBytes`), which the class doc promises to bound ("cached AND in-flight bytes are bounded", lines 142-143).
- **Fix:** add a `bool _pumping;` guard at the top of `_pump` (`if (_pumping) return; _pumping = true; try {…} finally { _pumping = false; }`) or schedule the restart via `scheduleMicrotask`. `_makeRoom` (723) also mutates `_segments` while `_pump` is iterating `waiting`; the guard fixes both.

### M4. `stream_proxy.dart:719` — `segment.touched = ++_clock` is a post-`putIfAbsent` write; a covering/shared segment's `touched`/`started` are updated from a reader that may be cancelled mid-loop, leaving `started` true with no owner

- **Symptom:** `_requestSegment` returns a `covering` or `shared` segment and then stamps `touched`. When `_serve` (line 1043) calls `_requestSegment` for `ahead` and the reader is cancelled before `_pump` runs, the segment may be `started == true` with `demanders`/`owners` emptied by `_releaseSegment` (660-671). `_releaseSegment` only cancels when `owners.isEmpty && bytes == null` **and** calls `segment.cancel()` — but a `started` segment already in-flight is not aborted because `cancel()` early-returns when `result.isCompleted` is false but doesn't check `started`; `request?.abort` only fires if `request` was captured.
- **Why it matters:** an in-flight `_fetch` for a segment whose only owner was released keeps its `_active`/`_reservedBytes` consumed until the upstream read finishes or times out (up to 15-20 s), because `_fetch` only notices `segment.check()` (which throws) *between* reads — the `_readBody` subscription is only aborted via `segment.cancelBody`, set at `_readBody:593`. If the segment was started but `_readBody` hadn't yet assigned `cancelBody`, the abort is missed for the duration of the first socket read.
- **Fix:** in `_fetch`, poll `segment.cancelled` via `segment.check()` at the top of the retry loop (already done) *and* register the cancel check earlier; ensure `_releaseSegment`→`segment.cancel()` also calls `cancelBody` even when `started` but not yet reading. Low-frequency but a real over-consumption of the connection budget under seek spam (which is exactly the scenario the class optimizes for).

### M5. `playback_controller.dart:1478-1546` — `openExternalPlayer` finally-block recovery can throw `require(...)` and mask the original result / leave `openingExternalPlayer` reset racing a new open

- **Symptom:** In the `finally` (1529-1545), `check()` is **not** called, but `_stopExternalPlayback()` and `_releaseSafely` run; if `launched` is false and `wasPlaying`, it calls `await play()` (line 1543). `play()` is guarded by `if (closed) return;` and is safe. However `openingExternalPlayer = false` is set at line 1535 *after* awaits, and there is no generation guard preventing a *second* `openExternalPlayer` started from a UI that only checks `controller.openingExternalPlayer` (`player_page.dart:1756`) — if the first call's finally runs `await play()` (which can take time) while `openingExternalPlayer` is still true, a queued open is blocked, but if it runs **after** the flag is cleared but the previous `_externalScope` cleanup is still pending, the two overlap.
- **Why it's a bug (severity medium):** `openingExternalPlayer` is a single bool used as a mutex with no revision, while `_externalRevision` IS incremented per call (line 1485). The bool is cleared at the end of `finally`, but a UI tap that arrives between `_changed()` at 1536 (listeners fire) and function-return can observe `openingExternalPlayer == false` and start a new `openExternalPlayer` whose `_externalScope` (1486) cancels the first call's scope *while the first call is still finishing its `_releaseSafely(unowned)` / `play()`*. Result: first call's `currentRequest()` becomes false midway, an already-`launched` external player keeps a loopback stream whose owning controller then stops it → the external player freezes with a dead stream.
- **Fix:** gate re-entry on `_externalRevision` (already incremented) rather than / in addition to the bool, and only clear `openingExternalPlayer` under the same revision; or move the `play()` recovery out of `finally` to after the flag is cleared.

### M6. `stream_proxy.dart:340-348` — proxy `_length` is never re-validated against the *actual* file after the probe when `readCache != null` and `expectedSize == 0`; a growing/rotating cloud file yields silent corruption, not a `changed` failure

- **Symptom:** The probe checks `source.expectedSize > 0 && source.expectedSize != _length` (line 341-348) only when `expectedSize > 0`. For live-recording/`.ts`-like sources where `expectedSize == 0`, `_length` is frozen at probe time, and later `_sameFileRange` (467-475) validates every range against that frozen `_length`. If the upstream file grows, every subsequent range ending before the old `_length` still validates, but a reader seeking past the frozen `_length` gets `_requestedRange` clamping to `_length-1` (line 619) and serves stale/absent tail bytes.
- **Why it's a bug:** `_requestedRange` uses `_length` to bound `end` (line 619) and returns 416 when `start >= _length` (line 616). A seek into content beyond the probe-time length is served as a range-not-satisfiable or truncated, with no `changed` failure reported. The proxy is only started for HTTP(S) video; for genuinely static VOD this is fine, but for `expectedSize == 0` sources the code has no defense and treats a stale length as authoritative.
- **Fix:** when `expectedSize == 0`, re-read `Content-Range` total on each 206 and update `_length` if it grew (with `_makeRoom`/`_trimWindow` re-evaluation), or refuse proxying for unknown-length sources and fall back to `direct` transport (which mpv handles natively).

### M7. `playback_controller.dart:481-485` and `media_backend.dart:341-358` — `metadataReady` waits up to 3 s for geometry, but geometry is only completed on a *changed* value; if `_rememberGeometry` is called with `geometry == null` the completer is left pending until timeout on every audio-first video open

- **Symptom:** `_rememberGeometry` (1045-1056) returns early when `geometry == null` (line 1048) and does **not** complete `metadataReady`. In `_load` (478-485), if `entry.video && session.geometry == null && session.errorRevision == 0` it awaits `metadataReady.future.timeout(3s, onTimeout: (){})`. If the video has no decodable geometry within 3 s (audio-only "video" file mislabeled, or a codec that never publishes `videoParams`), each open eats a fixed 3-second stall before proceeding.
- **Why it's a bug:** the 3 s is on the *critical load path* (blocking `beforePlay`, `play`). It is forgiven only when `errorRevision != 0`. A mislabeled video (audio file with a video extension) or a video whose first frame is slow on a cold decoder pays 3 s of black screen on every load/seek-reload/retry. Not a crash but a real UX regression against `playRequested`.
- **Fix:** complete `metadataReady` on the first `_onState` where `state.duration > 0` (metadata known) rather than requiring geometry, or reduce the timeout and complete it in a timer that also fires on `completed`. Geometry can still arrive later via `_rememberGeometry` without blocking playback.

### M8. `playback_controller.dart:1392-1420` — `_attachSubtitle` appends the file to `session.selection.files` *before* confirming the attach succeeds; a later `setSubtitleTrack` failure leaves the file owned by the selection but never referenced, and a concurrent successful manual `setSubtitleTrack` deletes it via revision bump

- **Symptom:** line 1404 `session.selection.files.add(file)` runs unconditionally, then line 1412-1419 the gated body may `return` early if `!current()` (revision changed because the user picked another track via `setSubtitleTrack`, `playback_controller.dart:1338-1361`). The early return leaves the file in `selection.files` — good, it will be deleted on selection release — **but** the same file's `SubtitleTrack.uri` was never applied, and if the user then *manually* selects a new subtitle, `setSubtitleTrack` at line 1355 sets `cloudSubtitleId = null` and the resource is orphaned in the selection (deleted only at session retire). More critically: `setSubtitleTrack` (line 1341) increments `subtitleRevision` and *does not* remove the file, so `_attachSubtitle`'s `current()` closure (1408-1411) sees the stale revision and returns without applying — silently dropping the user's subtitle load while reporting success upstream (`loadCloudSubtitle`'s `finally` sets `subtitleLoading=false` and `_changed()`).
- **Why it's a bug:** the UI (`_importSubtitle`, `player_page.dart:1279`) shows "已加载字幕" on `attachSubtitle` returning without error, even though the track was never set because a racing `setSubtitleTrack` bumped the revision. The user perceives a successful subtitle load that does nothing.
- **Fix:** have `_attachSubtitle` throw / return a status when `current()` is false instead of silently returning, so the caller can report "已被新选择取代"; and reuse the file only when the track is actually applied.

### M9. `stream_proxy.dart:377-382` — probe client is closed in `finally` but `_probeClient` is nulled while `_getRange` may still have an in-flight `HttpClientRequest` on the *other* client; on `_resolveRedirect` (`:489-514`) a thrown `_ReadCancelled` after `_readBody` leaves the freshly opened response body unconsumed

- **Symptom:** `_resolveRedirect` (489) reads `_getRange(... fromSource:true)` → if `_sameFileRange` passes, it calls `_readBody(response, end+1)` (line 509). If `_closed` becomes true during `_readBody`, `_readBody` throws; the `response` body's subscription is cancelled by `_readBody`'s `finally` (`subscription.cancel()` line 600) — good. But a `_ReadCancelled` thrown at line 510 (`if (_closed) throw`) happens **after** `_readBody` returned successfully, i.e. the small body was fully read, so no leak there. The real leak: `_refreshRedirect` (477) memoizes `_redirectRefresh` and clears it in `whenComplete`; if `_resolveRedirect` throws, the next caller sees the cleared future and retries — but the *1 KB range probe response* was already consumed, so no leak. **Net: no confirmed socket leak here**, but the double client close (`_probeClient` closed both in `_close` line 1109 and `start`'s `finally` line 379) can double-`close(force:true)` an already-closed client — harmless but flagged.
- **Reclassified:** downgraded to Medium-confidence — **not** a definite leak. Documented so a reviewer confirms; see Low L5 for the actual double-close note.

> Correction: after tracing `_readBody`'s `finally` (stream_proxy.dart:596-601) and `_getRange`'s redirect body cancel (line 440), the probe/redirect paths **do** consume or cancel every response body. M9 is therefore **downgraded to informational** and merged into L5. The Medium list effectively contains M1, M2, M3, M4, M5, M6, M7, M8 — eight Mediums.

### M10. `playback_controller.dart:562-584` — hardware→software fallback retries but `_checkInitialization`/error handling can loop: `retain(source)` is called before `_retire(session)`, and if the retry's `warming`/`initialized` future throws synchronously the outer `catch` at 586 re-enters `load(... refreshSource:true)` while `_sourceRecoveryUsed` was not set for the fallback path

- **Symptom:** In the per-attempt `catch` (550-584), the code calls `retain(source)` then `_retire(session)` then requires `session.nativeClosed`. If `_retire` internally sets `notice` and returns early (M1's path, `backend.close` threw) then `session.nativeClosed` is false and line 579 `require(...)` throws → outer catch (586) runs, `_canRefresh(failure)` where `failure` is null (it's an `AppException` from `require`, not a `PlaybackFailure` with refreshable kind) → `_canRefresh` returns false → user sees `error = e.message` ("播放器初始化未完成，请退出播放页后重试"). Correct end state, but the `retain(source)` at line 574 is **not** balanced: the source was retained for the second attempt, the second attempt never happens (we bubbled to the outer catch), and the outer `finally` (630) does `_releaseSafely(unowned)` — but `unowned` was set to `source` only at line 575 within the same catch; on the `require` throw at 579, `unowned` is already `source`, so `finally` releases it once — the `retain` count is then *never* decremented relative to the original lease, leaking one lease reference.
- **Why it's a bug:** `retain(source)` (574) followed by a throw before the retried `_load`'s `unowned = source` consumption means the extra reference is dropped. For cloud sources (`services.cleanups.retain`), this keeps a cleanup lease pinned; for torrent (`leases[id]++`), the `torrentStreamStop` is never called and the native stream is orphaned. Only triggers when `nativeClosed` is false (backend close failure), but that's exactly M1's scenario.
- **Fix:** wrap the `retain` so a failure on the retry path balances it (retain only immediately before the next loop iteration's use, or track a `retained` flag and release in `finally` when not consumed).

### M11. `playback_metrics.dart:27-36` — `observe` `return`s after handling a pending seek and skips `_finishBuffering`/first-frame accounting, so seek-triggered rebuffering is mis-attributed and `firstFrame` can stay null forever

- **Symptom:** When `_seekAt != null`, `observe` handles the seek branch and `return`s (line 36) before the `_finishBuffering`/`_started` logic at 38-48. If the *first* playback interaction is a seek (user opens then immediately seeks), `firstFrame` is never set because line 43 (`if (firstFrame != null || position > previousPosition) _started = true;`) is skipped for the entire seek window, and `firstFrame` is only ever assigned in `media_backend._onPlayerState` (line 272) — which *does* run independently. So `firstFrame` still gets set by the backend; but `_started` (used to gate buffering counting, line 45) stays false through the seek, so a rebuffer *during* the seek is not counted. Minor metric inaccuracy.
- **Why it matters (low-medium):** `bufferingTime`/`bufferingCount` feed diagnostics (`diagnosticFields`) used to decide whether to surface stall failures (`media_backend._watchTransport`). A seek-heavy session can under-report rebuffering, delaying stall detection. Not user-visible directly.
- **Fix:** move `_finishBuffering(elapsed)` into the seek branch too and update `_lastPosition` correctly (already done at line 25-26 before the branch), or compute `_started` before the seek `return`.

---

## Low / Informational

### L1. `media_backend.dart:298` and `:322` (and 670) — `notifyListeners()` is called from `_onPlayerState`/`_reportFailure` without a `_closing` guard, risking `ChangeNotifier` used-after-dispose

`_onPlayerState` returns early `if (_closing) return;` at line 258 and `_reportFailure` returns `if (_closing …) return;` at 306, so the direct paths are guarded. **But** these are also driven by player stream subscriptions (line 156) which are cancelled in `_close` *before* `player.dispose()` (861-869). A stream event already queued can fire between `_closing = true` (857) and cancellation; the early returns cover it. Verified safe on inspection; flagged only because `.notifyListeners()` at 670 (in `open`) is guarded by the surrounding `if (!_closing)`. **No change needed** — recorded so it is not re-raised.

### L2. `playback_buffer_policy.dart:70-71` — `connections = math.max(1, connections ~/ 2)` plus `proxy.connections = _bufferPolicy.observe(...)` can *raise* the proxy's connections after a `429/503`, because `observe` clamps to `limit` (which may be > current) on the recovery branch two samples later

Not a safety bug; the halve-then-recover is intentional. Only note: after a `503` the `_holdUntil` 12 s window uses `elapsed` (a stopwatch on `_openWatch`) rather than wall clock; if playback is paused during the hold, `elapsed` keeps advancing (stopwatch) and the hold appears already expired on resume — acceptable, but the "12 s" is wall-time not playback-time. Info.

### L3. `playlist_order.dart:47-74` — `_chineseNumber` mishandles `零` mid-number and `十` without a leading digit unit correctly in all cases

`_chineseNumber('十五')` → total += 1*10 = 10, digit 0 → 10 then +digit(5)=15 ✓. `_chineseNumber('二十')` = 20 ✓. `_chineseNumber('一百零五')`: `一`→digit1, `百`→total+=1*100=100 digit0, `零`→digit=0*10+0=0, `五`→digit=0*10+5=5, +5=105 ✓. But `_chineseNumber('两')`=2 ✓. Edge: extremely large or malformed strings default unknown chars to `digits[char] ?? 0` which silently injects 0 digits — a name like "第十集" is fine but "第A集" would not be matched by the regex anyway. No bug found; **info**: unknown digit chars silently become 0 rather than failing, acceptable for sorting.

### L4. `subtitle_matching.dart:86-97` — `subtitleMatchScore` returns 100 for any exact stem match even when language decorations disagree (e.g. English-only subtitle ranks equal to Chinese), and `matchingSubtitle` auto-attaches only on a *unique* top score

Behavior is intentional (comment line 91-92 explains Chinese-tag preference of 110 vs 100). Risk: if two same-stem subtitles exist with identical metadata the auto-attach is skipped (line 122), which is correct. No bug; **enhancement** noted below.

### L5. `stream_proxy.dart:377-382` — `_probeClient` is closed in `start`'s `finally` *and* in `_close` (`:1109`); double `close(force:true)` is harmless

`start` sets `_probeClient = client` (306) then `finally { client.close(force:true); _probeClient = null; }` (378-380). `_close` (1109) `_probeClient?.close(force:true)` — if `_close` runs concurrently (user leaves during probe), `_probeClient` may still be non-null (start's finally hasn't run) → double close of the same client. Dart's `HttpClient.close` is idempotent; no leak. Info only.

### L6. `playback_controller.dart:350-363` / `:634-642` — `_inflightLoads` / `_aheadTasks` are `Set<Future>` mutated from `then`/`whenComplete` without isolation; a load that completes synchronously before `_inflightLoads.add` (line 354) is still added then removed by the `.then` — safe, but the `.then`'s `onError` swallows the error for the *tracking* future only (the returned `future` still propagates to the caller). Verified correct; info.

### L7. `torrent_playback.dart:42-54` — `torrentDownloadPlayback` builds a `files` map keyed by `task.spec.torrent!.integer('index')` from `services.downloads.tasks`; two tasks of the same torrent+index collide and the *later* wins (map overwrite), so `initialIndex` may resolve to a different task's file than the one the user tapped

`<int, TorrentFile>{ for (task in tasks) if (hash match && kind match) task.spec.torrent.integer('index'): TorrentFile(...) }` — duplicate index keys overwrite. In practice one index maps to one file, so only matters if two download tasks exist for the same torrent index (rare). Info.

### L8. `external_stream.dart:142-150` — Range/If-Range headers from the downstream request are forwarded to upstream, but `content-length`/`transfer-encoding` are not stripped from `downstream` because they are read from `downstream.headers` by name, not forwarded wholesale; verified the only forwarded headers are `_headers(url)` (already filtered) + Range/If-Range + accept-encoding. Safe. Info.

---

## Optimization Opportunities

1. **`stream_proxy.dart:284-286` — one `HttpClient` per proxy plus one probe client; the probe client's `idleTimeout` (10 s) keeps a socket open across the whole probe→ready window.** Since `_probeClient` is closed at end of `start`, it's fine, but consider reusing the probe connection for the first fetch (HTTP keep-alive) to shave first-byte latency (`_firstUpstreamByteMs`).
2. **`media_backend.dart:737-743` — `_samplePerformance` does 5 sequential `getProperty` await round-trips every 2 s per session through the native platform channel.** These are independent; batch them with `Future.wait` (or a single `getPropertyAsync`-style multi-get if media_kit exposes it). Saves ~4 IPC round-trips/2 s = ~4× fewer platform-channel trips, noticeable on Android.
3. **`playback_controller.dart:543-546` — `_saveTimer` persists a bookmark every 10 s unconditionally.** `_save` (1086) early-returns when position didn't advance, but the `history.save` write still fires when playing. Consider saving only on position delta ≥ N seconds or on state transitions; reduces store writes for long sessions.
4. **`stream_proxy.dart:1044-1053` `scheduleAhead` re-requests every ahead segment on every index iteration** (`for ahead in index+1 .. index+window`). `_requestSegment` dedupes via `putIfAbsent`, but the loop still allocates/closures per byte-window. Precompute once per reader instead of per index.
5. **`font_metadata.dart:18` — `findChineseSubtitleFont` inspects up to 512 font files synchronously inside `Isolate.run` (`subtitle_fonts.dart:89`), opening and parsing each.** For systems with large font dirs this is expensive; the `_priority` sort already caps high-priority CJK fonts first, but the loop still falls through up to 512. Consider `take(64)` or short-circuit after the first CJK-priority hit fails (already returns on first match, so fine in practice). Low value.
6. **`playback_sources.dart:60-68` — `cloudPlayback` materializes `subtitleFiles` for *all* candidates on every open**, including the whole directory listing. For very large folders this is O(n) map building per playback; acceptable but cacheable across episodes.

## Enhancement Points

1. **Structured playback health surface** — `diagnosticFields` (media_backend) already aggregates proxy + metrics + stall. Exposing a compact `PlaybackHealth` object (transport, stallMs, effectiveConnections, lastFailure kind) to the UI would let the player show a "connection degraded" hint before the stall monitor fires at 20 s.
2. **Retry policy centralization** — `PlaybackFailure.refreshable` (expired/network) drives both the controller's auto-refresh and the backend's `canRetryWithSoftware`/source-failure split. A single `PlaybackRecoveryPolicy` enum (`refresh`, `softwareFallback`, `surface`) would remove the scattered `_canRefresh`/`_sourceRecoveryUsed`/`_sourceFailure` coordination and make M2/M10 fixable in one place.
3. **Subtitle side-channel** — route subtitle-specific failures through a non-source-failure channel (M2) so a broken subtitle never triggers a full video reload.
4. **Proxy budget observability** — expose `_budget`/`_active`/`_reservedBytes` + `_makeRoom` evictions in `diagnosticFields` to catch M3/M4 regressions in the field.
5. **`PlaybackStreamProxy` supports HEAD only for range validation**; consider caching the last validated `_etag/_modified` across session reuse for the *same* source to skip the 1 KB probe when a `PlaybackController` reloads the same video (retry path).
6. **Sleep timer wall-clock vs playback-time** (L2): for `PlaybackSleepMode.duration`, consider pausing the countdown while paused, matching user expectation "stop in 30 minutes of watching"; the current implementation uses wall-clock `deadline`.

---

## Appendix — Verified-clean items (checked, no bug)

- `playback_stall_monitor.dart` — stall detection is interval-based (elapsed), and the caller (`media_backend._watchTransport`) samples every 5 s, so a change during any 5 s interval resets cleanly before the 20 s timeout. Correct.
- `playback_selection.dart` — reference counting (`_references`) with a `retain` in `_Session` ctor (line 33) and balanced `release` in `_retireOnce`/`_close`. File deletion tolerates `FileSystemException`. Correct.
- `subtitle_files.dart` — size guard (`maximumBytes` 8 MB) enforced incrementally before `BytesBuilder` grows; failed writes delete the partial. Correct.
- `playback_failure.dart` — `http()` maps statuses correctly; `sourceFailure` excludes decoder/unknown as designed.
- `external_playback.dart` — external requests are session-scoped; `_credentials` stripped on cross-origin redirects (`external_stream.dart:188`). Good.
- `media_backend.dart:879-884` `isPlaybackSourceError` regex — matches transport-status and open-failure messages; used by callers to skip decoder retry. Correct.
- `stream_proxy.dart:516-534` `_contentRange` — validates `total > end` and `end >= start`, preventing absurd ranges. Correct.
- `stream_proxy.dart:604-620` `_requestedRange` — suffix ranges and open-ended ranges handled; clamps to `_length-1`. Correct for static VOD (see M6 for unknown-length caveat).
- `playback_controller.dart:1559-1588` `_close` — cancels scopes, discards prepared, drains `_inflightLoads`/`_subtitleLoads`/`_aheadTasks`, flushes store before `super.dispose()`. Correct shutdown ordering.
