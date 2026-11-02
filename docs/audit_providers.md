# Audit — Cloud Providers (`lib/data/providers/`)

Scope: all 41 files in `lib/data/providers/` (~23.7K LOC incl. `uploads/`). Reviewed deeply:
`personal_cloud.dart`, `token_session.dart`, `cookie_cloud.dart`, `quark_uc.dart`, `aliyun.dart`,
`baidu.dart`, `uc.dart`, `quark.dart`, `pan123.dart`, `pikpak.dart`, `wopan.dart`, `tianyi.dart`,
`c139.dart`, `xunlei.dart`, `lanzou.dart`, `github.dart`, `ctfile.dart`, `weiyun.dart`,
`feijipan.dart`, `guangya.dart`, `ilanzou.dart`, `aliyun_signature.dart`, `pan115_crypto.dart`, and
the `uploads/*` helpers. Remaining providers scanned via pattern grep (`as` casts, `.first`, `!`,
empty `catch`, `unawaited`, token-refresh, `substring`, `jsonDecode`).

Line numbers are exact against the current checkout.

---

## Critical

### C1. Token/session refresh can silently reuse a rotated-away credential across accounts (`token_session.dart:26-44`, `80-107`)
`TokenSession.credential` is a mutable field; `checkpoint()` re-reads the store and reassigns
`session.credential = current` only if `sameWebTokenSession`. `TokenSessions.update()` loops up to 3
times calling `store.replaceCredential(platform, previous, updated, ...)` and *returns* on
`committed`; if all 3 miss (concurrent account swap) it throws. This is largely correct, but the
comparison helpers are the whole safety boundary: `refreshedFields()` (`token_session.dart:109-145`)
derives `userId` from server data and `update()` only *warns* via `require(userId.isEmpty ||
previous.field('userId').isEmpty || userId == previous.field('userId'))`. If the previous credential
has **no** stored `userId` (e.g. first login where `_driveInfo`/`_account` failed but token refresh
succeeded), a refresh response for a *different* account is accepted without any identity check —
`previous.field('userId').isEmpty` short-circuits the guard to `true`. The refreshed token then
overwrites the active account's tokens.
**Symptom:** after an edge-case login, files from another account could be listed/downloaded under
this session; token rotation may cross accounts.
**Why it matters:** cloud providers never expect a refresh to change account; there is no second
check at use time for many providers (`AliyunConnector`, `pikpak`, `wopan`, `guangya` all rely on
`userId` being populated).
**Fix:** In `update()`, when `fields['userId']` is non-empty and `previous.field('userId')` is empty,
*persist* it as the identity anchor but also require that the credential revision still matches
(`preserveRevision` already guards this) — do not treat "previous empty" as "matched". For providers
that fetch identity lazily (`_driveInfo`), ensure identity is captured *before* the first refresh
response is committed.

### C2. `_CookieCloudHttp.success()` rejects legitimate empty-data success replies (`cookie_cloud.dart:93-114`)
`success()` ends with:
```dart
require(json['data'] is Map || json['data'] is List, '...响应缺少有效数据，请重试');
```
UC/Quark mutation endpoints (e.g. `file/delete` via `delete()` → `post('file/delete', ...)`,
`quark_uc.dart:502-507`) legitimately return `{ "code": 0, "status": 200 }` with **no `data` key**.
`success()` then throws `AppException('...响应缺少有效数据')`, so a *successful* delete/rename/move
is reported as a failure — the caller thinks the mutation failed when it actually succeeded, and any
cleanup path that re-tries on failure will double-execute.
**Symptom:** `delete`/`rename`/`move` throw despite server success; temp-folder cleanup may retry a
delete that already happened.
**Fix:** Only require `data` for endpoints that return data. Either pass a `requiresData: false`
flag for mutations, or relax to: require success status/code; return `{'data': json['data']}` even
when `json['data'] == null` for mutation call sites. At minimum add `&& json.containsKey('data')`
before the require so absence is allowed.

---

## High

### H1. Hardcoded third-party client secrets in source (`wopan.dart:19`, `pikpak.dart:30`, `xunlei_protocol.dart:10`)
```dart
// wopan.dart:19
static const clientSecret = 'XFmi9GS2hzk98jGX';
// pikpak.dart:30
static const _secret = 'dbw2OtmVEeuUvIptb1Coyg';
// xunlei_protocol.dart:10
static const clientSecret = 'Xp6vsy4tN9toTVdMSpomVdXpRmES';
```
These are embedded Android/web client secrets baked into the shipped binary. They are also usable to
mint tokens / refresh credentials (`wopan.dart:357`, `pikpak.dart:167,212`, `xunlei.dart:241`). They
can be extracted from the APK/IPA trivially.
**Why:** if rotated upstream the app breaks; if abused they enable account-takeover flows for stolen
refresh tokens and get the app's device fingerprint banned.
**Fix:** Treat as "known-public client credentials" and document this explicitly (they are not a
server-side secret and cannot be protected client-side). Do not log them (see H4). Ensure any
diagnostics never echo request bodies containing `client_secret`. If the vendors rotate, ship updated
constants rather than fetching remotely.

### H2. Empty `catch (_) {}` swallows real failures on mutation/cleanup paths (34+ sites)
Representative hot spots on *state-changing* code:
- `aliyun.dart:1419-1429` — `_shareSource` cleanup fallback: a failed trash means a leaked temp
  folder is silently left. It relies on `stageCleanup` caller to retry but swallows the error so
  nothing is logged.
- `quark_uc.dart:392-405` — `prepareFile` catch-all re-throws but the cleanup inside is
  `catch (_) { /* Persisted cleanup is retried ... */ }` with no `DiagnosticLog.event`, so a failed
  transfer-folder delete is invisible.
- `guangya.dart:639-651`, `baidu.dart:518-527`, `wopan.dart:53,557`, `xunlei.dart:636`,
  `pan123.dart:371,626,641,766`, `pikpak.dart:853`, `feijipan_upload.dart:205` — same pattern.
**Symptom:** silent resource leaks (temporary "文析助手临时转存" folders accumulate on the user's
drive), lost cleanup, undiagnosable failures.
**Why:** these are the exact paths where a partially-completed transfer leaves junk; success of the
primary operation hides the failure.
**Fix:** Every swallowed catch on a cleanup/mutation path should emit `DiagnosticLog.event(...)` /
`DiagnosticLog.error(...)` with a redacted reference before returning. Where the exception indicates
a real unrecoverable state, rethrow. At minimum add structured logging; consider a shared
`ignoreWithLog(stage, () async { ... })` helper.

### H3. Aliyun pagination false-positive: legitimately all-duplicate page treated as "分页重复" (`aliyun.dart:711-742`)
```dart
read.items = result.length;
...
marker = data.str('next_marker');
if (marker.isEmpty) { ... return result; }
require(added > 0 && markers.add(marker), '阿里云盘分页重复，请刷新列表重试');
```
`added == 0` is treated as a fatal "duplicate pagination" error. But `_list` dedups via `ids.add`,
and the API can legitimately return a page whose items were *all already seen* (e.g. items moved
into the same folder between pages, or overlapping markers under `order_by name`) while still
returning a fresh `next_marker`. In that case the require throws and the whole listing fails even
though progress is possible.
**Symptom:** intermittent "阿里云盘分页重复，请刷新列表重试" on large/active directories.
**Fix:** Base loop-termination on `marker` advance only (the `markers.add` guard against a repeated
*marker* is correct); do **not** require `added > 0`. Guard against a stuck cursor with a page cap
and a marker-set check, not item growth.

### H4. `DioException` suppression loses all context; failures may hide leaked headers (`http.dart:394-397`, used by every provider)
`DioJsonHttp.request` converts every `DioException` to `HttpRequestFailure.network(error)` and drops
stack/URL. The comment acknowledges `toString()` can leak signed credentials/headers, which is good,
but the resulting `HttpRequestFailure` carries only a coarse `kind`/message. Provider-level error
handling (`_checked`, `success()`) then has no status code for network failures, so retry vs. fatal
decisions rely on `retryable` heuristics that miss e.g. TLS/proxy `DioExceptionType.unknown` with a
non-`SocketException` payload (`http.dart:105-110`).
**Symptom:** transient `unknown`-type errors during download/refresh are treated as non-retryable
and surface as generic "网络连接失败", preventing the `_listPage`/`_call` retry loops from recovering.
**Fix:** In `HttpRequestFailure.network`, classify `DioExceptionType.unknown` with `error.error is
HttpException`/`TlsException`/`OSError` as retryable; and propagate `error.response?.statusCode` into
`HttpRequestFailure.status` so callers get HTTP status even when a body failed to parse.

### H5. `checkedCloudUrl` / URL validation is duplicated and inconsistently applied
Direct download/redirect URL validation exists in at least 5 places with subtly different rules:
`token_session.dart:148-159` (`checkedCloudUrl`), `aliyun.dart:823-840` (`address`), `cookie_cloud.dart:445-457`
(host-suffix check), `quark_uc.dart` download resolution, `lanzou.dart:519-563` (`_downloadUrl`,
`_redirectUrl`). `_prepare` in `cookie_cloud.dart:574-581` re-checks only scheme/host/userinfo but
*not* the control-char check that `checkedCloudUrl` applies. A provider that returns a URL containing
tab/newline would pass `_prepare` but fail `checkedCloudUrl` — inconsistent per platform.
**Symptom:** different platforms accept/reject the same malformed URL; header-injection surface
(`http.dart:372-374` filters empty header values but not embedded CR/LF in a URL later reused).
**Fix:** Route every download/redirect URL through the single `checkedCloudUrl()` helper (with an
optional allowed-host parameter) and delete the per-file re-implementations.

---

## Medium

### M1. `wopan.decodeValue` collapses every decrypt/parse error into one generic message (`wopan.dart:34-52`)
```dart
} catch (_) {
  throw const AppException('联通云盘响应解密失败，请刷新或重新登录');
}
```
A genuine key/`access` mismatch (bad token) is indistinguishable from a corrupt response, and it
catches *all* exceptions including programmer errors. The caller cannot tell "re-login" from "retry".
**Fix:** Narrow the catch to `FormatException`/`CryptoException`; let `RangeError`/`StateError`
propagate. Map decrypt-key failures to `AccountLoginRequired`.

### M2. `pan123` renewal locks single-flight per `updatedAt`, but `_refreshing` key reuse can cache a stale future (`pan123.dart:304-328`)
`_refreshing` is keyed by `current.updatedAt`. During a renewal, if the credential is replaced
(revision changes), a second caller arrives with a *newer* `updatedAt` and starts a second renewal;
the `identical(...)` cleanup in `whenComplete` only removes when the stored future *is* this one. This
is mostly safe but two concurrent renewals for what is logically the same account (old + new
revision) can both hit the login endpoint. Same pattern in `tianyi.dart:519-535`.
**Fix:** Key single-flight on a stable account identity (`userId`/draft id) rather than `updatedAt`,
or add an explicit in-flight flag on the credential record.

### M3. `_batch` in Aliyun feeds a synthetic `HttpResult(...,'')` into `_checked`, dropping retry-after and body headers (`aliyun.dart:1043-1050`)
```dart
final body = _checked(HttpResult(reply.integer('status'), ''), reply.obj('body'));
```
The synthetic response has no headers, so a per-item `429` inside a batch cannot surface
`retry-after` and `AliyunApiException.rateLimited` will not trigger the list-level cooldown. If the
batch envelope succeeds but a member reply is rate-limited, the throttle signal is lost.
**Fix:** Pass the real header map from the batch reply (or the outer response) into the synthetic
`HttpResult`, or detect `status==429` in batch replies and raise a shared rate-limit state.

### M4. `_ShareDirectUnavailable` / guest-vs-account routing has silent `return null` on 401/403 (`cookie_cloud.dart:421, 431-433, 470`)
In `tryShareDownload`, several branches `return null` to mean "fall back to account route", but a 401
from the *guest* path also returns null, causing a retry as the *authenticated* account and, on
failure, a generic `AppException`. The reason the guest token was rejected (expired share vs. real
auth error) is lost. For `quark || credential == null` a `HttpRequestFailure` is rethrown
(`cookie_cloud.dart:334-337`) but for UC-with-account it is swallowed into `guestFailure`.
**Fix:** Distinguish `_ShareDirectUnavailable` reasons and log which route is being tried; do not
collapse a genuine account 401 into "guest unavailable".

### M5. `tianyi._api` retries the API request after session renewal even for non-idempotent mutations (`tianyi.dart:273-368`)
The loop `for (var attempt = 0; ; attempt++)` retries on `_TianyiSessionExpired` and `continue`s the
same request after `_renew`. The comment claims "Only an explicit expired session retries this one
API request. A successful transfer/mutation ... is never replayed." — but if a mutation *did* reach
the server and then returned a session-expired envelope (possible under a mid-flight token
rotation), the retry replays the mutation (double transfer/move). The guard only prevents replay
when `attempt > 0`.
**Fix:** For non-idempotent calls, pass an `idempotent: false` flag and after a renewal do **not**
resend the body; instead surface a "please retry" so the caller decides. Or require a dedupe key.

### M6. `substring`/index arithmetic assumes fixed-length prefixes without a length guard in several parsers
- `c139.dart:626` `rootId: path.substring(6)` and `c139.dart:588` `.substring(6)` — guarded only by
  `_familyPath` requiring `path.length > 6` and `startsWith('root:/')`, so `openFamily` at line 626 is
  *not* preceded by the `require`; if the API returns a short `path` it throws `RangeError` instead of
  a friendly error.
- `wopan.dart:25` `access.substring(0, 16)` guarded by `require(access.length >= 16)`. OK.
- `lanzou_protocol.dart:305` `token.substring(1, token.length - 1)` — if `token.length < 2`, throws.
**Fix:** Add explicit `require(value.length >= n)` guards at the `openFamily` call site and in
`lanzou_protocol` unescape; prefer a helper `takePrefix(s, n)` that throws `AppException`.

### M7. `guangya` `traceparent` and `newId().substring(0,8)` rely on UUID segment length (`guangya.dart:62`, `quark_uc.dart:304`)
`newId()` presumably returns a UUID; `newId().replaceAll('-','').substring(0,16)` and
`newId().substring(0,8)` are safe *only* if `newId()` is always ≥ that length. Not validated. Low
risk but a single-char change to `newId()` breaks two providers at runtime.
**Fix:** Centralize `traceId()`/`shortId()` helpers with their own length guarantees.

### M8. Provider-specific token expiry windows are inconsistent (`token_session.dart:50` vs per-provider)
`TokenSessions.expired()` uses a fixed 60 s pre-expiry window (`expiry <= now() + 60000`), while
`aliyun._device` uses 60 s for device session (`aliyun.dart:185`), `wopan` no explicit skew, and
`pan123._expiresSoon` uses 60 s but on a *different* clock (`now().add(60s)` vs. epoch seconds). A
provider whose token TTL is short (< a few minutes) will thrash refresh because the 60 s window
overlaps most of its life.
**Fix:** Make the skew a per-platform value on `TokenSessions` (default 60 s) and reuse one clock.

### M9. `loginRequired` heuristic accepts `status==401` / `code==31001` but not HTTP 403 (`cookie_cloud.dart:769-777`)
```dart
if (response.status == 401) return true;
... return json.integer('status') == 401 || json.integer('code') == 31001;
```
UC/Quark frequently signal expired sessions with `403` + `code: 31001` (covered) but sometimes a bare
`403` body. A bare 403 is then treated as a normal API error by `success()` and reported as
"请求失败（HTTP 403）" instead of triggering re-login.
**Fix:** Also return true for `response.status == 403 && body empty`, or map 403 to a typed
auth-required exception consistently with `success()`.

---

## Low

### L1. `personalCloudDate` swallows format anomalies by returning input (`personal_cloud.dart:5-12`)
`if (!RegExp(...).hasMatch(raw)) return value;` — a non-numeric timestamp is returned verbatim and
later rendered; a malformed-but-numeric value returns `value` too. Harmless but yields inconsistent
display across providers that use it.

### L2. `_md5` in `quark_uc.dart:42-46` regex `[^0-9a-f]` boundary over a longer hex string can misfire
The regex `(?:^|[^0-9a-f])([0-9a-f]{32})(?:[^0-9a-f]|$)` on a 40-hex SHA1 would *not* match a
32-hex prefix because the 33rd char is hex (not `[^0-9a-f]`), which is correct — but a 64-hex SHA256
containing a valid 32-hex substring delimited by non-hex is unlikely; acceptable. Documented

### L3. `quark_uc.dart:567` `(task.obj('save_as')['save_as_top_fids'] as List? ?? [])`
Safe (cast to nullable) but `save_as` could be absent → `obj()` returns `{}` → `[]`, silently
returning "转存完成但未返回新文件 ID". A more precise error would help.

### L4. `github.dart:247` `matches.first` after `isNotEmpty` check — safe; `github.dart:138`
`(raw as List)` guarded by `require(raw is List)` — safe. No action.

### L5. `_awaitVisible` in `quark_uc.dart:515-529` polls with `Future.delayed` (not `RequestScope.wait`)
`await Future<void>.delayed(taskDelay)` is not cancellation-aware (unlike `RequestScope.wait`), so a
cancelled operation keeps the timer/delay alive up to `taskDelay * 8`. Minor resource/latency issue.
**Fix:** Use `RequestScope.wait(taskDelay)`.

### L6. Duplicated `_md5`/checksum normalization across providers
`quark_uc.dart:32-70` has a thorough MD5 normalizer; `aliyun.dart` uses `cloudChecksum`;
`token_session.dart:161-167` also implements `cloudChecksum`. Three checksum validators with
different acceptance (base64, markers, label stripping) → inconsistent verification strength.

### L7. `feijipan.dart:386,428`, `guangya.dart:478`, `ilanzou.dart:299`, `weiyun.dart:422`, `wopan.dart:540` — `(data['list'] as List).length`
All are preceded by an `is List` `require`, so safe. Listed for completeness; the pattern is fragile
against refactors (a future edit that removes the require reintroduces a crash).

---

## Cross-cutting patterns

### Duplication → base-class / shared-helper opportunities
1. **Cookie validation & Set-Cookie merge** implemented separately in `cookie_cloud.dart:797-847`
   (UC/Quark), `tianyi.dart:192-256` (`_acceptCookies`), `lanzou_upload.dart:38-56`,
   `lanzou.dart`. A shared `CookieJar.receive(headers, allowNames)` would dedupe ~4 copies and
   centralize the control-char filtering.
2. **Pagination loops** (`for page 1..N` + dedupe set + `added==0` break) are copy-pasted in
   `aliyun._list`, `baidu._list`, `quark_uc.list`, `weiyun`, `feijipan`, `guangya`, `wopan`,
   `ilanzou`, `c139`. All differ subtly in the "stop" condition and the "duplicate page" guard (see
   H3). A generic `paginate<T>(fetchPage, idOf, keyOf, maxPages)` would remove 8+ copies and fix the
   inconsistent duplicate-page handling in one place.
3. **Download URL validation**: see H5 — 5 divergent implementations. Consolidate on
   `checkedCloudUrl` (extend with allowed-hosts) + a shared `_isSafeDownloadUrl`.
4. **Temporary-folder transfer+cleanup** (`文析助手临时转存`): `aliyun._shareSource`,
   `quark_uc.prepareFile`, `guangya` share copy, `baidu` share transfer — each re-implements
   create-folder → stage-cleanup → transfer → verify → poll → cleanup-on-error. Extract a
   `ShareTransferStaging` helper.
5. **Token refresh (duplicate refresh suppression)**: `TokenSessions.fresh` for aliyun/pikpak/wopan/
   guangya, but `pan123` and `tianyi` each roll their own `_refreshing` map. Both custom impls have
   the `updatedAt`-keying weakness (M2). Fold them onto `TokenSessions`.
6. **Checksum normalization**: 3 implementations (L6).

### Error-handling consistency
- **Two error taxonomies:** `AppException`/`AccountLoginRequired` (most providers) vs.
  `AliyunApiException` (`aliyun.dart:18`) vs. `HttpRequestFailure` with `kind`. Callers branch on
  `error.code`/`error.status` in a handful of places; elsewhere everything collapses to message
  strings.
- **Silent catches (H2)** concentrated on cleanup paths across all providers — the single most
  repeated defect. Introduce a lint (custom analyzer) banning `catch (_) {}` outside a whitelisted
  set, forcing at least logging.
- **`return null` as "fall back"** (`cookie_cloud.dart`) mixed with exceptions-as-fall-back
  (`aliyun._playback` catches and falls back). Pick one: typed `Fallbackable` exceptions.
- **`loginRequired` detection differs per provider** (`cookie_cloud` vs `baidu.check` vs
  `pikpak._checked` vs `tianyi._TianyiSessionExpired`). Centralize auth-error classification.

### Header / token hygiene
- Providers correctly avoid logging raw `DioException` (http.dart:396 comment) and filter empty
  header values (http.dart:373). Good.
- **Gap:** batch reply handling (M3) and some `DiagnosticLog.event` fields could include
  `file`/account references — most use `DiagnosticLog.reference(id)` (redacted) which is correct;
  audit any ad-hoc fields for raw ids.
- Hardcoded client secrets (H1) — ensure never logged; grep for `client_secret`/`secret` in
  diagnostic fields (none found that print the value, only presence).

---

## Optimization

1. **Shared pagination helper** (cross-cutting #2) — removes ~8 loops and the inconsistent
   duplicate-page guard.
2. **Shared cookie jar + Set-Cookie parser** (cross-cutting #1) — dedupes UC/Quark/Tianyi/Lanzou.
3. **Unify `success()`/`_checked()` return contract.** Today some providers return the raw envelope
   (`pikpak._checked` returns `data`), others return `data['data']` (`cookie_cloud.success`), others
   return a synthetic `{'data': ...}` (`quark_uc.success`). A single `ApiEnvelope` type with
   `.data`/`.raw` accessors would remove the `json['data'] is Map ? json['data'] : {'data': ...}`
   dance repeated in `cookie_cloud.dart:113`, `quark_uc.dart:96`.
4. **Aliyun `_batch` waits tasks serially** (`aliyun.dart:1043-1050`): `for reply ... await
   _waitTask(...)`. Batch of N async tasks is polled one-at-a-time; parallelize the polls (bounded)
   or use a single combined async_task fetch where the API supports it.
5. **`_listIdle` Stopwatch is never stopped** after a successful request (only reset+started in the
   `finally` at `aliyun.dart:636`) — it accumulates across the whole session. Reset/stop on the
   success path; it currently measures "time since last request" only by luck of reset-before-use.
6. **`Dio` client single instance is correct** (`DioJsonHttp` holds one `Dio`); no per-request
   client creation found — good, no resource leak there. Keep it.
7. **`pan123._expiresSoon` decodes the JWT on every `_authorized` call** — cache the parsed `exp`
   on the credential or memoize per token string; JWT decode is cheap but called per request.

## Enhancements

1. **Structured per-request telemetry.** Most providers log only on error (`DiagnosticLog.event`).
   Add a `tracing` hook so an audit can reconstruct which route (guest/account/transfer/authorized)
   served each download — `uc.download_route` (`uc.dart:74`) is the model; generalize it.
2. **Central auth-required classifier.** A single function mapping `(status, code, provider)` →
   `AccountLoginRequired | RateLimited | Fallback | Fatal` removes the per-provider guessing and
   fixes M9/H4 at once.
3. **Idempotency keys for mutations.** Tainyi/Aliyun batch replay risk (M5, M3) would be eliminated
   by sending a client-generated `request_id` so a retried transfer is deduped server-side (Aliyun
   already supports `check_name_mode: refuse`; extend to a transfer dedupe key).
4. **Download URL host allow-listing.** Generalize `checkedCloudUrl` to accept a per-platform host
   suffix (like `cookie_cloud.dart:446-451` does for quark/uc) so all providers reject off-domain
   redirects uniformly — closes a redirect-to-attacker surface for the weaker providers (e.g.
   `ctfile`, `lanzou` HTML-parsed URLs).
5. **Expose provider capability matrix.** Many `PersonalCloudConnector` subclasses override
   `openShare`/`createShare`/`saveShare` to just throw (`personal_cloud.dart:20-40`). Surface this as
   a data-driven capability set so the UI can disable actions instead of catching `AppException`
   strings.
6. **Startup self-check for hardcoded secrets.** A build-time test asserting the embedded client
   secrets (H1) still authenticate against each provider's token endpoint would catch upstream
   rotation before users hit opaque "登录已失效" errors.

---

### Summary counts
- Critical: 2
- High: 5
- Medium: 9
- Low: 7

### Top 5 findings
1. **C1** `token_session.dart:109-145` — `refreshedFields` accepts a refresh response for a different account when the stored `userId` is empty; token rotation can cross accounts.
2. **C2** `cookie_cloud.dart:109-113` — `success()` throws "响应缺少有效数据" on legitimate empty-data mutation replies (`file/delete` etc.), reporting successful mutations as failures.
3. **H3** `aliyun.dart:742` — `require(added > 0 && ...)` treats an all-duplicate page with a fresh cursor as fatal "分页重复", failing large-directory listings.
4. **H1** `wopan.dart:19`, `pikpak.dart:30`, `xunlei_protocol.dart:10` — hardcoded client secrets embedded in source/binary, usable for token refresh.
5. **H2** `aliyun.dart:1419`, `quark_uc.dart:392` + 30 more — empty `catch (_) {}` on transfer-folder cleanup hides leaked temp folders and failed mutations.
