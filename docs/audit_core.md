# Audit — CORE / DOMAIN / DATA (non-provider) layers

Scope reviewed (read in full):
- `lib/core/`: `crypto_box.dart`, `login_crypto.dart`, `json.dart`, `operation_progress.dart`, `app_version.dart`
- `lib/domain/`: `auth.dart` (1074), `models.dart`, `links.dart`, `downloads.dart`, `settings.dart`, `announcements.dart`, `remote_control.dart` + `remote_control_parser.dart`, `uc_published_command.dart`, `xunlei_kouling.dart`, `baidu_share_route.dart`, `web_tokens.dart`, `github_update.dart`, `downloads.dart`, etc.
- `lib/data/` (non-provider, non-uploads): `state_store.dart`, `state_key.dart`, `backup.dart`, `startup_recovery.dart`, `http.dart`, `http_retry.dart`, `cloud_repository.dart`, `remote_control_service.dart`, `remote_control_http.dart`, `github_update_service.dart`, `app_update_service.dart`, `cleanup_outbox.dart`, `cloud_search.dart`, `cloud_favorites.dart`, `playback_store.dart`, `legacy_import.dart`, `backgrounds.dart`, `cloud_search_history.dart`
- `lib/lan/`: `lan_service.dart`, `lan_server.dart`, `lan_discovery.dart`, `lan_datagrams.dart`, `lan_files.dart`, `lan_models.dart`, `lan_qr.dart`

Environment: `flutter analyze --no-pub lib/core lib/domain lib/data lib/lan` reports **0 errors, 0 warnings** (only 2 info-level `use_super_parameters` in `lib/data/providers/`, which is out of scope). The codebase is disciplined and defensive; findings below are therefore mostly hardening issues and edge cases rather than crashes. Severity is assigned by real-world impact and reachability.

---

## Critical

_None._ No remotely-triggerable RCE, key-exfiltration, or trivially-exploitable defect was found in this scope. The encryption envelope, key handling, and LAN request validation are sound.

---

## High

### H1. PBKDF2 uses SHA-1 as the PRF for both backup and local state-key wrapping
- **`lib/core/crypto_box.dart:53`** — `PBKDF2KeyDerivator(HMac(SHA1Digest(), 64))`
- **Callers:** `lib/data/backup.dart:22,67` (backup files), `lib/data/state_key.dart:376,404` (device-key recovery envelope). Both use 210000 iterations.
- **Symptom:** Password-derived keys for user backup files and the local password-recovery envelope are derived with HMAC-SHA1 instead of HMAC-SHA256.
- **Why it matters:** PBKDF2-HMAC-SHA1 is not broken, but it is the legacy PRF; SHA1's 160-bit state caps the usable PRF security well below SHA256 and is flagged by most crypto baselines. Backup passwords can be as short as 6 chars (`backup.dart:100`, `state_key.dart:374`), so attackers who obtain a backup file (portable, shareable) get a cheap offline-guessing target at a weakened PRF. The stored `'kdf': 'PBKDF2WithHmacSHA1'` string in `backup.dart:29` also pins the format to SHA1.
- **Fix:** Switch new derivations to `HMac(SHA256Digest(), 64)` (i.e. PBKDF2-HMAC-SHA256, ~600k iterations per OWASP 2023) and tag the envelope `kdf: 'PBKDF2WithHmacSHA256'`. On decrypt, dispatch on the stored `kdf` value and keep a SHA1 branch only for reading legacy files (already guarded by the `kdf` check at `backup.dart:54`). Bump the minimum password length for backups from 6 to ≥8.

### H2. LAN pairing code is a low-entropy 6-digit secret with only per-IP, per-minute throttling
- **`lib/lan/lan_service.dart:141-144`** — `connectionCode = Random.secure().nextInt(1000000).toString().padLeft(6,'0')` (1,000,000 possibilities; regenerated only on `start()`).
- **`lib/lan/lan_server.dart:58-70`** — `/v1/pair` rejects after 8 failed attempts per remote IP within a rolling minute, but the code does not rotate on failure and is stable for the entire `start()` lifetime.
- **Symptom:** An attacker on the same LAN can spread guesses across many source IPs (trivial with ARP spoofing / multiple hosts) or over time (8/min/IP indefinitely) against a fixed 6-digit code; brute-force convergence is feasible (birthday-free, ~10⁶ space, no lockout escalation, code never rotates).
- **Why it matters:** A successful pairing grants an authenticated session that can read the share list, push into the recipient inbox, and receive files (`/v1/shares`, `/v1/inbox`, `/s/…`). The pairing code is the only gate. `_attempts` is keyed by `remote` IP only (`lan_server.dart:60`), so multi-host attacks bypass the throttle entirely.
- **Fix:** Rotate `connectionCode` after a configurable number of total failures (e.g. 10) or a short TTL (e.g. 2 min), and make it opt-in visible (user taps to display). Track failed attempts in a global counter in addition to per-IP. Consider raising to 8 digits. The code already lives in memory only — also ensure it is cleared on `_stop()`.

### H3. Unauthenticated `/v1/info` and share-manifest endpoints enumerate devices and shares to any LAN host
- **`lib/lan/lan_server.dart:51-57`** (`/v1/info` returns `id`, `name`, `port` with no auth) and **`lib/lan/lan_server.dart:179-185`** (`/v1/manifests/<token>` returns the full manifest with no session check).
- **Symptom:** Any device on the LAN — no pairing, no connection code — can `GET /v1/info` to enumerate all running instances (names + ports) and, given a 32-hex share token, `GET /v1/manifests/<token>` to read every file name/path/size/hash in an active share. The manifest route only requires a valid token, not a session (`_findShare(parts[2])` with no `_authorize`).
- **Why it matters:** The tokens are 128-bit so guessing is infeasible, but the branch treats the manifest as public. If a share link (`/s/<token>`) leaks once (screenshot, clipboard via `_sendInbox` kind `share` to a peer that later logs it), the full file tree is readable by anyone on the LAN, not just paired devices. This may be an intentional design (single-file browser download page uses the same token), but the multi-file manifest exposure is broader than the browser download flow needs.
- **Fix:** For `/v1/manifests/<token>`, require either a valid session (`_authorize`) **or** that the share is `singleFile` (which is what the browser flow needs). Multi-folder manifests should require a paired session. Alternatively document this as an accepted risk.

---

## Medium

### M1. `DownloadSpec.fromJson` / `RemoteIdentity.fromJson` / `DownloadTask.fromJson` use unguarded `as String?` casts
- **`lib/domain/models.dart:489`** — `appUpdateKey: j['appUpdateKey'] as String?`
- **`lib/domain/downloads.dart:68-69`** — `j['etag'] as String?`, `j['modified'] as String?`
- **`lib/domain/downloads.dart:194-195`** — `j['destination'] as String?`, `j['savedPath'] as String?`
- **`lib/data/legacy_import.dart:36-37,56-57,60-61`** — same pattern on legacy JSON.
- **Symptom:** If any of these keys ever holds a non-String, non-null value (e.g. an int written by a future/older schema, a hand-edited state file, or a corrupted backup), the cast throws `_TypeError`/`CastError`. Because `DownloadTask.fromJson` runs while loading the entire persisted queue, one bad task aborts the whole `StateStore` decode path → `StateRecoveryRequired` / lost queue.
- **Why it matters:** `j.str(...)` already exists and safely coerces (`this[key]?.toString() ?? fallback`), so these casts buy nothing and convert a recoverable value into a fatal load error. `app_version.dart` shows state files are forward-versioned; robustness matters.
- **Fix:** Replace each `j['k'] as String?` with `j.str('k')` (empty string for absent) or add a small helper `optStr(key) => this[key]?.toString()`. Note `appUpdateKey` is compared by equality only (`app_update_service.dart:65`), so `''` vs `null` is fine if callers treat empty as absent — or use `this[key] is String ? this[key] as String : null`.

### M2. `AsyncGate` deadlocks if a gated action itself calls another gated method
- **`lib/core/json.dart:60-67`** — `AsyncGate.run` chains onto `_tail`; `StateStore.change` (and thus every `Vault.*`, `CleanupOutbox.*`, `PlaybackStore.*`, `RemoteControlService._saveCache/_saveSeen`) runs inside it.
- **Symptom:** `_tail = result.then(...)`. If code inside a `change(edit)` callback (or any `_gate.run(action)`) calls another `_gate.run(...)` on the *same* gate and awaits it, the inner action waits for `_tail` to settle, but `_tail` includes the outer action which is awaiting the inner → **permanent hang** (no timeout).
- **Why it matters:** Today no `change()` callback calls `change()` again (I checked every call site in `lib/data/` and `lib/lan/`), so it is latent — but it is an easy trap for the next contributor, and the failure mode is a silent UI hang, not an exception. `RemoteControlService._saveCache` already runs `store.change` in a `while` loop *outside* any outer `change`, which is correctly structured; that discipline is undocumented.
- **Fix:** Add a re-entrancy guard/assert (e.g. zone key set inside `run`, throw a clear error if re-entered on the same gate), or document loudly in a doc-comment on `AsyncGate.run` that the action must not await another `run` on the same gate. Consider giving `StateStore._gate` and `CleanupOutbox._gate` independent gates (already are) and asserting.

### M3. `state_store.dart` commit deletes the backup before installing the new snapshot (narrow invariant violation)
- **`lib/data/state_store.dart:234-238`**
  ```dart
  if (await file!.exists()) {
    if (await backup.exists()) await backup.delete();
    await file!.rename(backup.path);
  }
  await temporary.rename(file!.path);
  ```
- **Symptom:** Between `backup.delete()` and `file.rename(backup.path)` a crash leaves **no** `.bak` while `.tmp` holds the new data and `file` still holds the current data. The comment says "Keep one previous authenticated snapshot until the next successful commit," but the window briefly violates it. Actual data loss is improbable because `file` is still present until renamed, yet the recovery logic (`state_store.dart:97-156`) tries `file → pending(.tmp) → backup`; a crash exactly in this window plus a later partial write to `file` would remove both good copies.
- **Why it matters:** The application goes to great lengths elsewhere (atomic write + read-back verify in `state_key.dart:363`, `startup_recovery.dart:146-152`) to be crash-safe; this ordering is the one spot that is not strictly atomic.
- **Fix:** Rename first, then delete the old backup:
  ```dart
  if (await file!.exists()) {
    if (await backup.exists()) await backup.delete();
    await file!.rename(backup.path);
  }
  ```
  → reorder to `await file!.rename('${file.path}.bak.tmp'); await temporary.rename(file.path); await backupTmp.rename(backup.path)` or simpler: delete stale backup, then `file.rename(backup)`, then `temporary.rename(file)`, and only *after* both succeed is the invariant restored — accept the one-instruction gap but ensure `pending`(.tmp) is tried before `backup` in recovery (it already is at `state_store.dart:97`). The minimal safe fix is: do not delete `backup` at all until after `temporary.rename(file.path)` succeeds.

### M4. `OperationProgress.clear()`/`_publish` can touch a disposed `ValueNotifier`
- **`lib/core/operation_progress.dart:171-174`** — `_publish` unconditionally does `value = List.unmodifiable(steps)`; **`197-200`** — `clear()` calls `close()` then `_publish(const [])` with no `_closed`/`hasListeners` guard.
- **Symptom:** After `dispose()` (`203-206`), any late call to `clear()` (e.g. a still-running operation's `finally`) executes `_publish` → `value = ...` on a disposed `ValueNotifier`, which throws `FlutterError: A ValueNotifier was used after being disposed`. Callers that `.catchError` may swallow it, but a bare `await cleanups.progress.clear()` in a `finally` would surface it.
- **Why it matters:** Download/cleanup flows run in zones that may outlive the widget that owned the progress notifier; dispose races are exactly the class of bug this code tries to avoid elsewhere (`_closed` flags in `RemoteControlService`, `LanService`).
- **Fix:** Guard `_publish` with `if (_closed && refcount... )`— simplest: add `if (_closed) return;` at the top of `_publish`, and move the `close()`-triggered cancel-status publish *before* setting `_closed = true` (it already is ordered that way inside `close`, but `_publish` itself should refuse to write when disposed). Since `close()` must still publish the cancelled snapshot, invert: keep an explicit `disposed` flag distinct from `_closed`.

---

## Low

### L1. `_canonicalControl` can throw on non-string keys
- **`lib/domain/remote_control_parser.dart:289`** — `value.keys.cast<String>().toList()`.
- **Symptom:** If a parsed control document ever contains a map with non-String keys (JSON always yields String keys, so only reachable if `wire` is built from untrusted dotted literals — it isn't today), this throws `CastError` while computing the fingerprint. Defensive only.
- **Fix:** `value.keys.map((k) => k.toString())`. Low risk given JSON key types, but free.

### L2. `announcements._date` accepts an offset wider than ±14:00 and doesn't reject `+24`-style offsets
- **`lib/domain/announcements.dart:149-168`** — offset groups validated only `≤23`/`≤59`. Real timezone offsets max at ±14:00; `+23:59` is accepted and `DateTime.tryParse` may normalize/reject inconsistently. Cosmetic (only affects sort order of announcements).
- **Fix:** clamp offset hour to ≤14 or simply rely on `DateTime.tryParse` result plus a round-trip check. Negligible impact.

### L3. `state_store.Vault.secret()` returns secrets for a different account when `id == null`
- **`lib/data/state_store.dart:589-604`** — when a `pan123.`/`xunlei.` key is requested but `accountId(platform)` is `null`, it falls through to `store.data.obj('secrets')[key]` (the active/legacy bucket) — correct — but if a non-null id is not the active id it reads the per-account bucket. Edge: if id is null but an active account exists, `id == activeAccountId` is false and it reads `obj(id ?? '')` = `obj('')` which is empty → returns null instead of the active secret. Very narrow (only when account scope is explicitly set to null while an active account exists).
- **Fix:** compute `final id = accountId(platform); if (id == null || id == activeAccountId(platform)) return store.data.obj('secrets')[key]?.toString();`.

### L4. `cleanup_outbox.drain` swallows the underlying error into a generic retry message
- **`lib/data/cleanup_outbox.dart:145-158`** — `catch (_)` records `'云端清理失败，稍后重试'` and increments `attempts`, discarding the exception type/message.
- **Symptom:** Permanent failures (e.g. folder already deleted → 404, or an `executeAction` `AppException` like "账号已变化") are retried forever with no backoff cap on `attempts` and no dead-letter. Diagnostics lose the reason.
- **Fix:** Persist `error.runtimeType`/`error is AppException ? error.message : ...` (sanitized) into the `'error'` field for diagnostics, and stop retrying when `attempts` exceeds a bound or the failure is a non-retryable `AppException` (account-changed / not-found). Currently entries only leave the outbox on success.

### L5. `RequestScope.cancellable` / `wait` leak the losing `Future.any` branch
- **`lib/data/http.dart:45-54,56-70`** — `Future.any` resolves with whichever completes first; the other branch (the real `operation` or the `timer`) continues running to completion / is not cancelled. Common, generally benign, but for `cancellable` an in-flight network call is not actually aborted by cancellation alone (the Dio cancel token does abort separately at `http.dart:365`), and `wait`'s `timer` is cancelled in `finally` (good) but the `token.whenCancel` listener is never detached.
- **Fix:** Acceptable as-is; optionally use a `Completer` + explicit subscription cancellation. Low.

### L6. `CryptoBox.random` allocates a fresh `Random.secure()` per call and loops `nextInt(256)` per byte
- **`lib/core/crypto_box.dart:8-11`** — used for every 12-byte GCM nonce (each save of state to disk: `state_store.dart:13,229`), key generation, salts.
- **Symptom:** Correct and cryptographically secure, but relatively slow and allocates a new `Random.secure()` (which seeds from the OS RNG) on every call — callers like `state_store._encryptSnapshot` run this inside `compute` on every state commit.
- **Fix:** Hoist a single `static final Random _rng = Random.secure();` and reuse it; or use `Uint8List.fromList(List.generate(...))` with the shared RNG. Micro-optimization, not a bug.

### L7. `CryptoBox.open` permits a 12-byte-only payload before failing on GCM
- **`lib/core/crypto_box.dart:25`** — `require(... && packed.length >= 28, ...)`. A GCM tag is 16 bytes, so a valid sealed minimum is 12 (nonce) + 16 (tag) = 28 — the check is correct. However `seal` never validates that `plain` is non-null/length≥0 and `open` calls `packed.sublist(12)` on an unmodifiable list — fine. No action; listing for completeness. (No bug.)

### L8. `links.dart` scheme-force normalization can mask a genuinely invalid link
- **`lib/domain/links.dart:45-47`** — a value without `scheme://` is prefixed `https://`. Combined with the single-scheme-less-direct-URL fallback (`links.dart:159-164`), a pasted bare `looks.like.a.url` is accepted as `https://…`. This is intentional convenience, but it means `parse()` can produce a `direct` link for text that was never a URL (e.g. `example.com.pdf`), which then flows to the downloader. Low risk because the downloader still validates.
- **Fix:** none required; documented behavior.

### L9. `lan_service._json` aborts the request in `finally` even after a fully-read body (harmless but aborts the connection pool entry)
- **`lib/lan/lan_service.dart:343-346`** — `finally { finished = true; request?.abort(); }` runs after a successful `response` read. Aborting an already-consumed `HttpClientRequest` is a no-op-ish but may discard the underlying keep-alive connection, reducing connection reuse for bursty traffic (share list + manifests + inbox). Not a correctness bug.
- **Fix:** Only abort when not completed successfully (set a `success` flag and abort only on the failure/cancel path).

### L10. `remote_control_service._readCache` treats a clock-moved-back case by dropping cache silently
- **`lib/data/remote_control_service.dart:273`** — `if (!fetched.isAfter(clock()))` — if the device clock moved backwards, `fetched` (future) is dropped and the whole cache is not loaded (falls through to `_cached == null`). Acceptable safety choice; call out so it's not mistaken for corruption.

### L11. `legacy_import` does not clamp `checksumType`/`checksumValue` length
- **`lib/data/legacy_import.dart:36-37`** — `old['checksumType'] as String?` copied through `DownloadSpec` unvalidated. If a legacy store had a huge string, it persists. Same family as M1 (use `j.str`). Fold into M1's fix.

---

## Optimization

- **`CryptoBox.random` (crypto_box.dart:8):** hoist a single `static final Random _rng = Random.secure();`. Called on every state commit (`state_store.dart:229`) and every key/nonce generation. Saves OS-RNG seeding per call.
- **`state_store.change` re-encrypts and `compute`s the *entire* state on every mutation** (`state_store.dart:191-272`, `compute(_encryptSnapshot, (_key, serialized))`). For a large download queue each pause/resume/speed update triggers a full JSON serialize + AES-GCM + disk write inside the `AsyncGate`. Consider debouncing/coalescing task-progress writes (e.g. batch progress updates, flush on a 200–500 ms timer) so high-frequency download ticks do not serialize the whole document. `RemoteControlService` already models this with `_cacheToSave` retry batching.
- **`CloudRepository.collect` (cloud_repository.dart:842-864):** recursive `walk` lists each directory with `await list(...)` sequentially; could be parallelized per depth (bounded, like `cloud_search.dart`'s `parallel` queue) to cut large-tree enumeration time. It already yields every 128 files (`:851`) to stay cooperative.
- **`auth.dart` `LoginCredentials.plausible` / `normalize` (auth.dart:310-416):** several `RegExp` are constructed inline on every call (`RegExp(r'[\x00-\x1f\x7f-\x9f]')`, host patterns in `models.fromHost`). `models.dart:96-113` re-runs `fromKey` via a linear `values` scan and `hosts.any(...)` per platform on every lookup. Precompute a static `Map<String,CloudPlatform>` for exact hosts and a compiled list of `(RegExp)`. Hot path for every pasted link and every `fromKey` during state migration.
- **`CloudSearchHit.key` / `contentKey` hashing (cloud_search.dart:24, announcements.dart:24):** `jsonEncode` + `sha256` per hit/announcement on each rebuild. Fine at current scale (bounded ≤5000), but contentKey is recomputed in list keeps; cache it.
- **`lan_service._changed(progress:true)`** already throttles to a 200 ms timer (lan_service.dart:530-535) — good pattern; consider applying the same to `DownloadManager` progress notifications (out of scope but relevant).
- **`_ControlFields`/`_canonicalControl` (remote_control_parser.dart:287-294):** deep-sorts and re-encodes the entire wire map on every fetch to compute a fingerprint. Runs at most every 15 min; negligible.

## Enhancement

- **Typed JSON decoding helper:** introduce `optStr/String?`/`optInt`/guarded casts (fixes M1/L11 in one place) and, ideally, generated `fromJson` with schema-validation so persisted-state corruption degrades gracefully task-by-task instead of aborting the whole `StateStore` load.
- **`AsyncGate`: add re-entrancy assertion + documented contract** (M2) so future nested `change()` calls fail fast and loudly instead of hanging.
- **Outbox dead-lettering & diagnostics** (L4): cap retries, record sanitized error, expose `attempts`/`lastError` to the cleanup UI.
- **Crypto migration path** (H1): version the KDF in the envelope, prefer SHA-256, raise backup password minimum, and add a "re-key on restore" step so old SHA1 backups upgrade once opened.
- **LAN security model** (H2/H3): rotate the pairing code on failure/TTL, gate multi-file manifests behind a session, and surface to the user when the share is being accessed (e.g. mark `_changed()` on unauthenticated `/v1/manifests` hits for visibility). Consider requiring an explicit "allow LAN discovery" toggle separate from "sharing".
- **OperationProgress** (M4): separate `_closed` (stop accepting new steps) from `_disposed` (notifier disposed) so late `clear()`/`_finish` from zones that outlive the owner are safe no-ops.
- **Documented invariants:** the state file commit ordering, "one previous backup" invariant, and the `change()` serialization contract are load-bearing but only described in scattered comments — collect them in a short `docs/STATE-AND-CRYPTO.md`.

---

### Severity counts
- Critical: 0
- High: 3 (H1 PBKDF2-SHA1, H2 LAN pairing entropy/throttle, H3 unauthenticated manifest/info)
- Medium: 4 (M1 unguarded casts, M2 AsyncGate re-entrancy, M3 commit ordering, M4 disposed notifier)
- Low: 11 (L1–L11)

### Top 5 findings
1. **H1** `crypto_box.dart:53` — PBKDF2-HMAC-**SHA1** for backup + local key-wrapping (HMac(SHA1Digest) → SHA256, raise min password to 8).
2. **H2** `lan_service.dart:141` + `lan_server.dart:58-70` — fixed 6-digit pairing code, per-IP-only throttle, never rotates → LAN brute force grants session.
3. **H3** `lan_server.dart:179-185` — `/v1/manifests/<token>` and `/v1/info` readable without a paired session (multi-file tree exposure).
4. **M1** `models.dart:489` / `downloads.dart:68-69,194-195` / `legacy_import.dart` — unguarded `as String?` casts can abort the whole queue load on one bad field.
5. **M2** `json.dart:60-67` — `AsyncGate` hangs forever on nested same-gate `run()`; latent, easy trap.
