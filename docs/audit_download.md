# Download Subsystem Audit

Scope: `lib/download/` (all files, incl. `download_manager.dart` 2445 lines), `lib/upload/`, `lib/data/uploads/`, `lib/data/providers/uploads/`.

Method: read every in-scope file in full; cross-checked call sites and the `flutter analyze --no-pub` result for the whole scope. The only analyzer diagnostic across all four directories is the null-safety error reported as Finding C1 below.

Severity counts: **Critical 1 · High 4 · Medium 6 · Low 8** (plus Optimization and Enhancement sections).

---

## Critical

### C1 — `download_manager.dart:192` — nullable captured local accessed without promotion (does not compile; NPE risk)
- **Location:** `lib/download/download_manager.dart:179` (`DownloadSpec? source;`) and `:190-193`
  ```dart
  if (source != null) {
    await cleanups.release(source.cleanup);   // :191
    await cleanups.ready(source.cleanup);     // :192  <-- reported line
  }
  ```
- **Symptom:** `flutter analyze --no-pub lib/download lib/upload lib/data/uploads lib/data/providers/uploads` reports exactly one error:
  `error • The property 'cleanup' can't be unconditionally accessed because the receiver can be 'null'. • lib/download/download_manager.dart:192:37 • unchecked_use_of_nullable_value`.
- **Why it is a bug:** `source` is a **mutable local captured by the `release()` closure** and is reassigned at `:203`/`:205`. Dart type promotion does not apply to captured mutable locals, so even inside `if (source != null)` the compiler refuses to promote `source` to non-null, and line 192 (and 191) try to read `.cleanup` on a `DownloadSpec?`. At runtime the same non-promotion means the guard is not a guarantee the compiler can lean on. (Note: `cleanups.release`/`cleanups.ready` themselves accept `DownloadCleanup?` and null-guard, so the null value passed is harmless — the defect is the *receiver* `source`.)
- **Concrete fix:** promote through an immutable snapshot:
  ```dart
  final s = source;
  if (s != null) {
    await cleanups.release(s.cleanup);
    await cleanups.ready(s.cleanup);
  }
  ```

---

## High

### H1 — `download_manager.dart:133 / :123` — unbounded per-task maps leak over a session
- **Location:** `_cacheAccess` declared `:133`, created on demand at `:240`, `:1445`, `:1978`; `_controls` declared `:123`, created on demand at `:961`.
- **Symptom:** Every task id that ever runs `_readPlaybackCache`/`_deleteCache`/`_transfer` adds an `AsyncGate` to `_cacheAccess`; every task that is paused/deleted/resumed via `_control` adds an `AsyncGate` to `_controls`. Neither map ever removes entries (grep confirms no `_cacheAccess.remove`/`_controls.remove` anywhere). `_deleteCache` at `:1446` removes from `_readable` but not from `_cacheAccess`.
- **Why it is a bug:** Memory grows monotonically with the number of distinct download tasks created during an app session (a long-running/always-on download client). Each entry is small but never reclaimed — an unbounded resource leak.
- **Concrete fix:** Remove the gate for an id when the task is fully deleted (in `delete` `:1267` after `_tasks.remove`, and in `_drainRemovedDownloads`/`_deleteIdleRecords` after `_tasks.remove`) guarded so an in-flight gate isn't dropped mid-use (only remove after `_tasks` no longer contains the id and no `_running` entry exists), e.g. `_cacheAccess.remove(id); _controls.remove(id);` at the point the removal marker is committed.

### H2 — `download_manager.dart:162,711-712` — `settings` re-parsed from JSON on every access, twice per schedule-loop iteration
- **Location:** `AppSettings get settings => AppSettings.fromJson(store.data.obj('settings'));` (`:162`); consumed in the `_schedule` `while` loop `:711-712` (`settings.concurrent` evaluated twice per iteration), plus `settingsChanged` `:783`, `enqueueAll`, `_prepareSource` `:1785`.
- **Symptom:** Each `.settings` read runs a full `AppSettings.fromJson` (object allocation + map walks) over the store's raw map. In `_schedule` the loop re-reads it on every dequeued task.
- **Why it's a bug (perf):** Redundant work / repeated parsing — exactly the class of churn this audit targets. In hot scheduling paths it multiplies allocations.
- **Concrete fix:** Read `final s = settings;` once before the loop and reuse `s.concurrent`; cache the parsed `AppSettings` on the manager and invalidate it in `_update`/`_persist`/`settingsChanged` rather than reparsing per access.

### H3 — `upload_manager.dart:20,183` — upload runner captured in a stale `Zone`
- **Location:** `final _zone = Zone.current, ...` (`:20`); `_runner = _zone.run(_drain);` (`:183`).
- **Symptom:** The zone captured at construction time is reused for every `_drain` invocation. `runZoned` zone-values (e.g. any ambient `RequestScope`, DI/logging zone values established later) reflect construction-time state, not the state at schedule time.
- **Why it's a bug:** Subtle cross-zone propagation bug: `RequestScope.checkpoint()`/cancellation and any zone-scoped dependencies used inside `cloud.upload` run against a stale zone. If the app recreates the ambient zone (e.g. per-screen `runZoned`), uploads still see the old one.
- **Concrete fix:** Capture the zone at schedule time: `_runner = Zone.current.run(_drain);` (drop the stored `_zone`), or document intent explicitly if construction-time zone is truly required.

### H4 — `download_manager.dart:1452-1693` (`_run`) — failed post-export cleanup leaves `payloadReady`/cache without a durable retry marker when not playing back
- **Location:** `_run` completion cleanup `:1611-1627`:
  ```dart
  if (_playbackHolds.containsKey(id)) {
    // record completedCacheRemovals marker
  } else {
    await engine.remove(id);
    await _deleteCache(id);
  }
  ```
  wrapped in `try { ... } catch (_) { await _update(id, {'phase': '已保存，缓存稍后清理'}); }`.
- **Symptom / why it's a bug:** In the non-playback branch, if `engine.remove`/`_deleteCache` throws, the catch only sets a UI phase string ("已保存，缓存稍后清理") — it does **not** persist a `completedCacheRemovals` marker. `_drainCompletedCaches` only retries ids present in that marker (`:1418`). So a transient failure leaves the private payload cache orphaned on disk with no durable retry path until app restart's reconcile (which only handles `recoverOrphans` for cleanups, not completed caches).
- **Concrete fix:** On catch, also stage a `completedCacheRemovals` marker (same `store.change` used in the playback branch) so `_drainCompletedCaches` retries it, rather than only mutating the `phase` string.

---

## Medium

### M1 — `download_manager.dart:1294-1375` (`_deleteIdleRecords`) — reintroduces nested-gate stack recursion
- **Location:** `Future<void> locked(int index) async { if (index<ids.length) { await _control(ids[index], () => locked(index+1)); ... } }` (`:1306-1310`).
- **Symptom:** One nested async frame per id. `_withTaskControls` explicitly avoids this ("Nesting one Future per task overflows the stack when thousands of nested gates complete at once", `:1132-1133`).
- **Why it matters:** Currently bounded because `batch` chunks deletes to ≤64 (`:1192-1195`), so depth ≤64 today. It is a latent landmine if the chunk size grows, and it is inconsistent with the flat-barrier design used elsewhere.
- **Concrete fix:** Reserve all controls with a flat barrier (mirror the `_withTaskControls` `ready`/`release` pattern) instead of recursive `locked()`.

### M2 — `download_manager.dart:2390-2400` (`_hls`) — speed/Speed-limit use cumulative counters, not a sliding window
- **Location:** `received` accumulates across the whole run; `speed` computed as `received * 1000 ~/ (speedClock.elapsedMilliseconds + 1)` (`:2400`); pacing at `:2389-2393` derives delay from cumulative received vs. total elapsed.
- **Symptom:** Reported HLS speed is the run-average throughput, not current speed; speed-limit pacing drifts because the delay is computed from cumulative bytes over total elapsed.
- **Why it's a bug:** Misleading speed display and imprecise throttling for HLS downloads (inconsistent with `_transfer`'s native per-interval speed).
- **Concrete fix:** Track a periodic sample (`sampledReceived`/`sampledAt` reset each ~500 ms/1 s window) exactly as `upload_manager.dart:296-312` does, and pace against a per-window byte budget.

### M3 — `upload_manager.dart:406-414` (`remove`) — `_tasks.remove(t)` when `t == null` is a silent no-op but `_save()` still writes
- **Location:** `final t = task(id); require(t == null || !t.active, ...); _tasks.remove(t); ...` (`:407-412`).
- **Symptom:** If `t` is null the `require` passes, `List.remove(null)` silently does nothing, yet `_save()` and `notifyListeners()` run.
- **Why:** Harmless functionally, but it hides callers passing stale/unknown ids and triggers a needless persist. Low-impact correctness smell of the "unchecked nullable passed into a List API" family.
- **Concrete fix:** `if (t == null) return;` early, before the `require`, to make it explicit.

### M4 — `feijipan_upload.dart:116-118` — COS signing key-time sampled three times, can straddle a second boundary
- **Location:** `sessions.now()` called three times to build `seconds`, and both halves of `keyTime` (`:116-118`).
- **Symptom:** `seconds`, `keyTime start`, `keyTime end` can each fall in different seconds; the signature window start can exceed `seconds + 10` skew checks or produce an off-by-one-second signature window.
- **Why:** Flaky auth failures (intermittent 403) under clock skew / slow execution. Classic "sample `now()` once" bug.
- **Concrete fix:** `final now = sessions.now();` then derive all three values from `now`.

### M5 — `download_manager.dart:753,1688-1692` — `lastError` set inside `_run`'s `finally` and the schedule `catchError` is a global that outlives the task
- **Location:** `lastError = ...` in `_schedule` `catchError` (`:751-753`) and `finally` (`:1690`); surfaced via `lastError` getter.
- **Symptom:** `lastError` is a single mutable field overwritten by the last failing run; concurrent runs can clobber each other's message, and it is never cleared on success.
- **Why:** UI shows a stale/attributable-to-wrong-task error banner. Not fatal but misleading.
- **Concrete fix:** Key errors per task (map id→message) or clear `lastError` at the start of each `_run` and on task success.

### M6 — `transfer_http.dart:187-227` (`probe`) — `parent?.whenCancel.then(...)` future is fire-and-forget across loop iterations
- **Location:** `parent?.whenCancel.then((_) { if (!cancel.isCancelled) cancel.cancel(); });` (`:193-195`).
- **Symptom:** Each `probe` retry (the 1→2-byte Guangya retry loop `:203-209`) registers a new unawaited `.then` on the parent cancel future. On the second iteration the first token is cancelled in `finally`, but the second `.then` closure remains attached to `parent.whenCancel` until the parent is cancelled — an accumulating listener on a long-lived `cancel` future.
- **Why:** Unawaited future / listener accumulation (minor leak & multiple cancels) when many probes share a scope.
- **Concrete fix:** Break out of the retry with a single token, or use `parent?.whenCancel` once to build the token, or check `parent?.isCancelled` at loop top (already done at `:192`) and avoid re-subscribing.

---

## Low

### L1 — `upload_manager.dart:20` storing `_zone` (also see H3) — if only used here, remove dead field after H3 fix.

### L2 — `download_manager.dart:1449` — `directory.delete(recursive: true)` in `_deleteCache` has no `try/catch`; a `FileSystemException` propagates into `_drainCompletedCaches`/`_drainRemovedDownloads` handlers (caught there) but also `_run` `:1623` (caught locally). Behavior OK, but partial deletes aren't retried idempotently. Wrap or log.

### L3 — `download_manager.dart:481-489` (`_notifyGuestDownload`) — `putIfAbsent` creates `_GuestDownloadBatch` entries cleared only in `close`/delete; a not-download guest task that never completes keeps a tiny entry. Bounded, minor.

### L4 — `completed_files.dart:87-108` (`_refresh`) — two-worker `Future.wait([worker(), worker()])` shares an iterator; correct but relies on single-threaded event loop for iterator safety; add a comment or use an index queue for clarity/robustness.

### L5 — `navigation_transfers.dart:94` — `_finishedBytes += (size ?? previous.total).clamp(0, 1 << 62);` treats a just-finished batch's bytes as "done" but resets `_finishedBytes = 0` only when `current.isEmpty`; a paused-then-resumed batch can double-count completion bytes. Minor progress-display accuracy.

### L6 — `image_preview_loader.dart:101` — `count = math.min(budget, identity.total ~/ minimumSegmentBytes)`; if `identity.total < minimumSegmentBytes` count could be 0 only when total < 512 KiB, but this path is only entered when `total > parallelThreshold` (1 MiB) so count ≥ 2 here. Still, guard `count` ≥ 1 defensively.

### L7 — `weiyun_hash.dart:95-104` (`finish`) — `padding` length uses `(_used < 56 ? 56-_used : 120-_used)+8`; correct per spec, but `_length` was already incremented by any `add` of body bytes — verify padding bytes are not counted in the length prefix (they are added *after* capturing `final length = _length`). Correct as-is; keep a regression test pinned.

### L8 — `download_manager.dart:156-158` — `tasks` getter allocates a new list and sorts on every call (called from UI + `activity` + `navigation_transfers` + `_syncForeground` every 2 s). Consider caching a sorted view invalidated on mutation.

---

## Optimization

1. **Cache parsed `AppSettings`** on `DownloadManager` (invalidate on `_persist`/`settingsChanged`) instead of reparsing in the `settings` getter (`:162`) — biggest win in `_schedule`'s hot loop (`:711-712`) and `settingsChanged` (`:783`).
2. **Prune `_controls`/`_cacheAccess`** when a task is deleted (H1) to cap memory for long sessions.
3. **Cache sorted task list** (`:156-158`) and invalidate on mutation; several observers (`activity`, `_syncForeground` timer, `NavigationTransfers`) call it repeatedly.
4. **HLS sliding-window speed** (M2) — reuse the sampled-window pattern from `upload_manager.dart:296-312`; removes cumulative-counter drift and makes throttling precise.
5. **`_hls` re-parse reuse**: `HlsPlaylist.choose/media` repeatedly `split('\n')` and rebuild lists (`hls.dart:54,75`); parse lines once and pass to both.
6. **`upload_io.dart` digest cache** (`_hashes`) is good; extend the same memoization to any provider that re-hashes overlapping ranges.
7. **`_persist` progress batching** (`:454-458`) already throttles to 2 s — keep; avoid sprinkling `progress:true` on high-frequency `_update`s that don't need persistence.

## Enhancement

1. **Atomic/intent-restoring save marker**: on post-export cleanup failure (H4), persist a `completedCacheRemovals` marker so cache cleanup is retried across restarts, not just via a UI phase string.
2. **Per-task error surface**: replace global `lastError` (M5) with a per-task error/notice channel so concurrent failures don't clobber each other.
3. **Upload resumption**: `UploadManager` restarts uploads from scratch on retry (`upload_task.dart`/`upload_manager.dart` message "重新上传会从头开始"). Add resumable multipart checkpoints (part etags) for large files.
4. **Structured cancellation tests**: add tests that hold `_withTaskControls`/`_acquirePost` barriers under stop to lock in the flat-barrier invariants (guards against M1 regression).
5. **Consistent S3/OSS multipart policy**: `s3_upload.dart` uses single PUT for small files while `upload_io.oss` always multiparts (`upload_io.dart:238-241`) — unify behavior and error strings for parity.
6. **HLS encryption/byte-range support**: `hls.dart` rejects encrypted and BYTERANGE playlists — document as a known limitation or add support; at minimum the error copy already guides users to streaming.
7. **`_deleteIdleRecords` flat barrier** (M1) to remove the latent stack-overflow risk category permanently.
