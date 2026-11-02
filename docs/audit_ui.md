# UI Layer Audit — `lib/ui/`

Scope: `lib/ui/`, 72 files, ~29,393 lines. Reviewed deeply: `browser_page.dart` (2798),
`player_page.dart` (2672), `device_link_page.dart` (1983), `login_page.dart` (1900),
`parse_page.dart` (1565), `downloads_page.dart` (1302), `cloud_command_page.dart` (543),
`download_progress.dart` (446), `common.dart` (415), `cloud_search_page.dart` (545),
`preview_page.dart` (276), `player_rate_input.dart`, `uploads_page.dart`, plus a project-wide
pattern sweep (controllers/dispose, timers, `setState`-after-await, post-frame callbacks,
`MediaQuery`, giant build methods).

Baseline: `flutter analyze --no-pub` reports **7 issues project-wide**; the only one in
`lib/ui/` is `cloud_page.dart:537` (`onReorder` deprecated). This audit is otherwise about bugs
the analyzer cannot see.

## Overall verdict

This is a **mature, disciplined UI layer**. The scary categories are mostly already handled:

- **Controller / lifecycle leaks: none found.** Every `TextEditingController`,
  `AnimationController`, `ScrollController`, `FocusNode`, `PageController`, and
  `StreamSubscription` declared in a `State` is disposed. Periodic timers
  (`login_page.dart:455,1606,1786`, `downloads_page.dart:56`, `uc_tv_authorization_page.dart:232`,
  `guangya_sms_login_page.dart:138`, `native_password_login_page.dart:895`) are all cancelled in
  `dispose`. Listener add/remove pairs are balanced.
- **`setState` after dispose: no confirmed instances.** The two "scary-looking" `setState`s
  inside async closures that run after an `await` (`parse_page.dart:334`,
  `cloud_command_page.dart:234`) are in fact protected by an immediately preceding
  `checkpoint()`/`shareCheckpoint()` that re-checks `mounted`/`widget.active` and throws. See
  note below.
- **`BuildContext` across async gaps:** pervasive and correct — `context.mounted` / `mounted`
  is checked after essentially every `await` before touching UI. `busy()` in `common.dart`
  captures `Navigator`/`Theme` before awaiting.

Findings below are therefore real but mostly **Low/Medium**; the higher-value items are the
Medium optimization issues (heatmap rebuilds, giant build methods) and a couple of defensive
hardening points.

---

## Critical

_None._ No crash-on-use defect, no confirmed post-dispose `setState`, no null-deref on a live
path was found in the reviewed files.

---

## High

_None confirmed after verification._ Two candidate "missing mounted" bugs were investigated and
turned out to be guarded (documented here so they are not re-flagged):

### H-candidate-1 — `parse_page.dart:334` `setState` inside `_progress.run` async closure — NOT A BUG
Inside `_parse()`, the closure passed to `_progress.run` does
`await widget.services.cloud.share(...)` (line 329), then `setState(() => stage = ...)` (334).
Looks unguarded, **but line 333 `checkpoint()` runs first**, and `checkpoint()` calls
`require(_current(generation) && !scope.token.isCancelled, ...)` where
`_current` = `mounted && widget.active && generation == _generation` (`parse_page.dart:147-148`).
So a disposed page throws at line 333 before line 334 executes. Safe. `require` throws
`AppException` (`lib/core/json.dart:55`). Recommendation (optional): move the `setState`
behind an explicit `if (!mounted) return;` for readability, since the safety depends on an
easy-to-remove `checkpoint()`.

### H-candidate-2 — `cloud_command_page.dart:234` `setState` inside `scope.run` async closure — NOT A BUG
Identical shape: `shareCheckpoint()` at line 233 (defined at 219-225) calls
`require(current(run) && ...)` before the `setState` at 234, and `current(run)` =
`mounted && value == generation` (`cloud_command_page.dart:68`). Safe for the same reason.

---

## Medium

### M1 — `device_link_page.dart:973-974` entire page body rebuilds every ~3 s (heartbeat)
`build()` wraps the whole content `ListView` (all sections of a 602-line build) in
`AnimatedBuilder(animation: Listenable.merge([lan, widget.services.downloads]))`.
`LanService` (`lib/lan/lan_service.dart:51`, a `ChangeNotifier`) calls `notifyListeners()` from
a 3-second heartbeat `_tick()` (`lan_service.dart:166-172`) and on state changes
(debounced 200 ms, `lan_service.dart:530-536`). Consequence: the device-link page re-executes
its full 600-line `build` on every heartbeat tick and on every download-progress tick, even when
the visible content is unchanged (LAN idle or no active transfer). This is the page's dominant
rebuild cost.
**Fix:** scope the listeners to the widgets that actually consume them. Wrap only the status
card / peer list / transfer rows in their own `AnimatedBuilder`s (or `ListenableBuilder`), and
render the static chrome (title, buttons, empty states) outside the listener. At minimum use a
`ValueListenable`/selector for the specific fields shown, or split `lan` notifications so a
heartbeat only repaints the status line.

### M2 — `cloud_page.dart:537` deprecated `onReorder` used with mismatched index semantics
Analyzer: `'onReorder' is deprecated ... Use the onReorderItem callback instead`. The page
passes `onReorder: _reorder` and `_reorder` (`cloud_page.dart:464-471`) manually compensates:
```dart
void _reorder(int oldIndex, int newIndex) {
  if (_saving) return;
  setState(() {
    if (newIndex > oldIndex) newIndex--;   // old API still needs this
    final platform = _preferences.order.removeAt(oldIndex);
    _preferences.order.insert(newIndex, platform);
  });
}
```
Per the deprecation note, `onReorderItem` **already adjusts `newIndex`** for the removed item.
A blind rename to `onReorderItem` will keep the `if (newIndex > oldIndex) newIndex--;` line and
then **double-adjust**, dropping items one slot low on downward drags.
**Fix:** migrate to `onReorderItem` AND delete the `if (newIndex > oldIndex) newIndex--;`
adjustment (or keep `onReorder` until you do the full migration). Also note the semantics
accessibility buttons at `cloud_page.dart:549,552` call `_reorder(index, index+2)` relying on
the old ±1 convention — re-verify these after migration.

### M3 — `player_page.dart:1923` full `MediaQuery.of(context)` in the hottest build
`final media = MediaQuery.of(context);` (the only full `MediaQuery.of` in `lib/ui/`) subscribes
the player build to *every* MediaQuery aspect (padding, insets, textScaler, orientation, …).
The player rebuilds on any of them, and this is the most frame-sensitive screen. The app
elsewhere correctly uses granular accessors (`MediaQuery.sizeOf` / `textScalerOf` etc., 53
uses).
**Fix:** only read the aspects actually used here (it immediately uses `media.orientation` and
`media.padding`) → replace with `MediaQuery.orientationOf(context)` and
`MediaQuery.paddingOf(context)` so unrelated MediaQuery changes don't rebuild the player.

### M4 — `didChangeAppLifecycleState` calls `setState` without a `mounted` guard
- `downloads_page.dart:127`: `setState(() => _foreground = state == AppLifecycleState.resumed);`
- `uploads_page.dart:33`: `setState(() => foreground = state == AppLifecycleState.resumed);`

Both override `didChangeAppLifecycleState` (observer is removed in `dispose`, so this is
*usually* safe). But lifecycle notifications can be delivered while a route is being torn down
in edge cases (app backgrounded exactly as a push/pop settles), and Flutter's framework does
not guarantee the element is still mounted. This is the one place the codebase's otherwise
strict mounted discipline is dropped.
**Fix:** `if (!mounted) return;` at the top of each override (matching `login_page.dart:433`
which only reads fields and defers to `_poll()`).
**Severity:** Low–Medium (defensive; low practical probability, trivial fix).

---

## Low

### L1 — `downloads_page.dart:56` 30 s periodic refresh runs while page is off-screen
`_refreshTimer = Timer.periodic(Duration(seconds: 30), (_) => _checkFiles())`. `_checkFiles`
guards on `widget.active`, `_foreground`, and `ModalRoute.of(context)?.isCurrent`, so it does
little while hidden — but the timer still wakes every 30 s for the page's whole lifetime,
including when it is not the current tab. Cancelling/rescheduling on `widget.active` change
(in `didUpdateWidget`, which already exists at `downloads_page.dart:112`) would avoid the wakeups
and the repeated `ModalRoute.of(context)` traversal.
**Fix:** move timer creation into the `widget.active` transition and cancel it when inactive.

### L2 — `device_link_page.dart:1963` manual PIN digit clamp is fragile
```dart
digits.substring(0, digits.length.clamp(0, 6))
```
`digits.length.clamp(0, 6)` is always within `[0, length]`, so it cannot throw today, but the
intent ("take at most 6 digits") reads as if it could. Prefer
`digits.length > 6 ? digits.substring(0, 6) : digits`. Purely readability/hardening.

### L3 — `common.dart:173` `progress.dispose()` only via `route.completed`
`unawaited(route.completed.then((_) => progress.dispose()))`. In `busy()`, `route` is normally
removed at `common.dart:199` (`if (route.isActive) navigator.removeRoute(route)`), which
completes `route.completed`, so disposal fires. If the whole `Navigator` is destroyed while
`busy()` is awaiting (e.g. app teardown), `route.completed` may not complete and the
`OperationProgress` is leaked. Very low impact (one per in-flight dialog during shutdown).
**Fix:** dispose in the `finally` block (idempotently) instead of relying solely on
`route.completed`.

### L4 — Redundant `mounted` checks after `_current(...)`
`parse_page.dart:182` `if (proceed != true || !_current(generation) || !mounted) return false;`
— `_current` already includes `mounted`. Harmless; noted only for consistency.

---

## Optimization

### O1 — Giant build methods
Measured build-method spans (`Widget build(...)` → matching brace):

| File | build start | span |
|---|---|---|
| `device_link_page.dart` | 950 | ~602 lines |
| `announcements_page.dart` | 74 | ~405 lines (plus 253:226, 290:189) |
| `appearance_page.dart` | 72 | ~395 lines |
| `browser_page.dart` | 2315 | ~391 lines |
| `parse_page.dart` | 984 | ~387 lines |
| `cloud_page.dart` | 99 | ~338 lines |
| `player_page.dart` | 1920 | ~336 lines |
| `liquid_bottom_navigation.dart` | 156 | ~332 lines |
| `cloud_command_page.dart` | 296 | ~246 lines |
| `player_playlist_panel.dart` | 63 | ~229 lines |

`device_link_page.dart` already has ~10 private `_x()` widget-returning helpers, so splitting is
incremental — extract the large `ListView(children:[...])` sections (`_status()`, transfer
panels, peer list) into named `StatelessWidget`s. Benefit is two-fold: shorter rebuild scope and
the ability to make sections `const` / individually memoized (see M1). Do the same dominant
split for `browser_page.dart:2315`, `parse_page.dart:984`, `player_page.dart:1920`.

### O2 — Rebuild-scope heatmaps
- `device_link_page.dart:973` (M1): whole body listens to `lan` + `downloads`.
- `player_page.dart` has 23 `setState` and 6 timers driving chrome/HUD; use `ValueNotifier`s per
  transient HUD element (volume, seek preview) rather than a whole-page `setState`, and wrap
  frequently-repainting sub-trees in `RepaintBoundary` (only 7 `RepaintBoundary`s exist in all of
  `lib/ui/`, a low number for a media app with animated overlays).
- `download_progress.dart` is the stateful widget rebuilt per transfer row on every progress
  tick; it is already careful (`_scheduleVisibility` post-frame throttle) — leave as-is, but
  consider `RepaintBoundary` around the animated fill so progress repaints don't dirty siblings.

### O3 — `const` usage
2,017 `const` occurrences is already good. Spot-check showed hot lists (`ListView.separated`
item builders) build themed rows eagerly per scroll — these are naturally non-const, fine. No
systemic non-const issue found.

### O4 — ListView vs Column
Pages correctly use `ListView`/`ListView.builder`/`ListView.separated` for scrollable content
(e.g. `browser_page.dart` file grid, `downloads_page.dart` task list, `cloud_page.dart:536`
`ReorderableListView.builder`). No large `Column`-as-scroller anti-pattern was found.

## Enhancement (UX)

- **E1 — Perceived latency on parse/command:** the "正在读取文件列表…" stage is a text label
  updated by `setState`; add a `LinearProgressIndicator` / skeleton rows while the file list
  loads (`parse_page.dart:334`, `cloud_command_page.dart:234`), since list fetch can take
  several seconds on large shares.
- **E2 — Device-link heartbeat status:** because the page rebuilds on the 3 s heartbeat
  (M1), a small "在线/离线 · N 台设备" status chip could surface LAN liveness cheaply; the
  data is already flowing via `lan.peers` / `lan.running`.
- **E3 — Bulk download failures:** `downloads_page.dart:512` surfaces only the *first* failed
  task's error (`result.failed.values.first`). Show a summary list (e.g. a bottom sheet with
  per-file reason) so users can triage multiple failures.
- **E4 — Batch action discoverability:** selection mode is entered via long-press / app-bar
  ("选择" at `browser_page.dart:1897,2067`); add a visible "全选" affordance and a count badge in
  the selection app bar (partially present via `_selectionNotice`, `downloads_page.dart:514`).
- **E5 — Reduced motion:** several animated widgets (`liquid_bottom_navigation.dart`,
  `download_progress.dart`, `loading_indicator.dart`) animate unconditionally. `download_progress`
  already honors `MediaQuery.disableAnimationsOf(context)` (`download_progress.dart:153`); apply
  the same guard to the nav-bar morph and loading spinner.

## Summary of counts

| Severity | Count |
|---|---|
| Critical | 0 |
| High | 0 confirmed (2 candidates investigated → cleared) |
| Medium | 4 (M1–M4) |
| Low | 4 (L1–L4) |
| Optimization | 4 themes (O1–O4) |
| Enhancement | 5 (E1–E5) |

Top actionable items: **M1** (device-link whole-page rebuild every 3 s), **M2** (deprecated
`onReorder` + index-semantics double-move if naively migrated), **O1** (split the six
400–600-line build methods), **M3** (full `MediaQuery.of` in the player), **M4** (unguarded
`setState` in lifecycle callbacks).
