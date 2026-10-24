import 'dart:async';
import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:media_kit/media_kit.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'app_services.dart';
import 'diagnostics/app_log.dart';
import 'diagnostics/diagnostic_runtime.dart';
import 'ui/startup_failure_page.dart';
export 'ui/startup_failure_page.dart';
import 'domain/downloads.dart';
import 'ui/app_navigation.dart';
import 'ui/remote_control_dialogs.dart';
import 'ui/app_popup_menu.dart';
import 'ui/cloud_page.dart';
import 'ui/cloud_accounts_page.dart';
import 'ui/clipboard_link_banner.dart';
import 'ui/common.dart';
import 'ui/app_theme.dart';
import 'ui/app_background.dart';
export 'ui/app_theme.dart' show appTheme;
import 'ui/startup_loading_page.dart';
import 'ui/transfers_page.dart';
import 'ui/mine_page.dart';
import 'ui/parse_page.dart';
import 'ui/announcements_page.dart';
import 'ui/device_link_page.dart';
import 'ui/donate_page.dart';
import 'ui/about_dialog.dart';
import 'ui/download_shutdown_prompt.dart';
import 'ui/guest_download_prompt.dart';
import 'ui/player_page.dart';
import 'platform/external_open.dart';
import 'playback/external_playback.dart';
import 'platform/desktop_platform.dart';
import 'platform/windows_pip.dart';
import 'platform/windows_window_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await DiagnosticRuntime.start();
    LicenseRegistry.addLicense(() async* {
      for (final entry in {
        'Gopeed': 'Gopeed-LICENSE.txt',
        'Android NDK / LLVM': 'android-ndk-NOTICE.txt',
        'media_kit native build': 'media-native-build-LICENSE.txt',
        'Noto Sans SC': 'NotoSansCJK-OFL.txt',
        'LanzouAPI': 'LanzouAPI-LICENSE.txt',
        '115driver m115 protocol': '115driver.txt',
      }.entries) {
        yield LicenseEntryWithLineBreaks([
          entry.key,
        ], await rootBundle.loadString('assets/licenses/${entry.value}'));
      }
    });
    MediaKit.ensureInitialized();
    if (isDesktopPlatform) {
      await windowManager.ensureInitialized();
      unawaited(
        windowManager.waitUntilReadyToShow(
          const WindowOptions(
            title: '文析助手',
            size: Size(1100, 780),
            minimumSize: appWindowMinimumSize,
            center: true,
          ),
          () async {
            await windowManager.show();
            await windowManager.focus();
          },
        ),
      );
    }
    runApp(const _Bootstrap());
  } catch (error, stack) {
    DiagnosticLog.active ??= DiagnosticLog.open(null);
    DiagnosticLog.error('app.bootstrap_failed', error, stack, fatal: true);
    runApp(
      MaterialApp(
        theme: appTheme(Brightness.light),
        builder: (context, child) => WindowsWindowTheme(child: child!),
        home: StartupFailurePage(error),
      ),
    );
  }
}

class _Bootstrap extends StatefulWidget {
  const _Bootstrap();
  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  late Future<AppServices> services = _startServices();
  Future<AppServices> _startServices() {
    final pending = loadServices();
    // Attach an error handler immediately, before FutureBuilder's next frame.
    pending.ignore();
    return pending;
  }

  Future<AppServices> loadServices() async {
    try {
      return await AppServices.open();
    } catch (error, stack) {
      DiagnosticLog.error('app.services_failed', error, stack, fatal: true);
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<AppServices>(
    future: services,
    builder: (context, state) {
      if (state.hasData) return AsterLinkApp(state.data!);
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: appTheme(Brightness.light),
        darkTheme: appTheme(Brightness.dark),
        builder: (context, child) => WindowsWindowTheme(child: child!),
        home: state.hasError
            ? StartupFailurePage(
                state.error!,
                onRetry: () => setState(() => services = _startServices()),
              )
            : const StartupLoadingPage(),
      );
    },
  );
}

class AsterLinkApp extends StatelessWidget {
  const AsterLinkApp(
    this.services, {
    super.key,
    this.initialTab = 0,
    this.fontFamily,
  });
  final AppServices services;
  final int initialTab;
  final String? fontFamily;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: services.store,
    builder: (context, _) {
      final settings = services.settings;
      return MaterialApp(
        title: '文析助手',
        debugShowCheckedModeBanner: false,
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: appTheme(
          Brightness.light,
          fontFamily: fontFamily,
          palette: settings.themePalette,
          glassStyle: settings.glassStyle,
        ),
        darkTheme: appTheme(
          Brightness.dark,
          fontFamily: fontFamily,
          palette: settings.themePalette,
          glassStyle: settings.glassStyle,
        ),
        themeAnimationDuration:
            (MediaQuery.maybeDisableAnimationsOf(context) ??
                WidgetsBinding
                    .instance
                    .platformDispatcher
                    .accessibilityFeatures
                    .disableAnimations)
            ? Duration.zero
            : const Duration(milliseconds: 240),
        themeAnimationCurve: Curves.easeOutCubic,
        themeMode: switch (settings.theme) {
          'Light' => ThemeMode.light,
          'Dark' => ThemeMode.dark,
          _ => ThemeMode.system,
        },
        builder: (context, child) => WindowsWindowTheme(
          enabled: services.platformFeatures,
          child: child!,
        ),
        home: MainShell(services, initialTab: initialTab),
      );
    },
  );
}

class MainShell extends StatefulWidget {
  const MainShell(
    this.services, {
    super.key,
    this.initialTab = 0,
    this.externalPlayerBuilder,
  });
  final AppServices services;
  final int initialTab;
  final Widget Function(ExternalOpenRequest)? externalPlayerBuilder;
  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell>
    with WindowListener, TrayListener, WidgetsBindingObserver {
  late int selected = widget.initialTab;
  final parseKey = GlobalKey<ParsePageState>();
  bool trayReady = false, closing = false;
  bool _openingExternal = false, _externalScheduled = false;
  bool _openingLan = false;
  static const titles = ['分享解析', '网盘列表', '传输管理', '我的'];
  @override
  void initState() {
    super.initState();
    widget.services.sharedText.addListener(_shared);
    if (widget.services.downloadNavigation.value > 0) selected = 2;
    widget.services.downloadNavigation.addListener(_showDownloads);
    widget.services.lanNavigation.addListener(_showLan);
    widget.services.transferTab.addListener(_transferTabChanged);
    widget.services.externalOpens.addListener(_externalAvailable);
    widget.services.clipboard.addListener(_clipboardChanged);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final state = WidgetsBinding.instance.lifecycleState;
      widget.services.clipboard.setForeground(
        state == null || state == AppLifecycleState.resumed,
      );
      widget.services.control.setForeground(
        state == null || state == AppLifecycleState.resumed,
      );
      widget.services.announcements.setForeground(
        state == null || state == AppLifecycleState.resumed,
      );
      if (state == null || state == AppLifecycleState.resumed) {
        widget.services.refreshPublicDownloadPassword();
      }
      _externalAvailable();
      if (widget.services.lanNavigation.value > 0) _showLan();
    });
    if (isDesktopPlatform && widget.services.platformFeatures) {
      windowManager.addListener(this);
      trayManager.addListener(this);
      _desktop();
    }
  }

  void _clipboardChanged() {
    if (mounted) setState(() {});
  }

  void _transferTabChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    widget.services.clipboard.setForeground(state == AppLifecycleState.resumed);
    widget.services.control.setForeground(state == AppLifecycleState.resumed);
    widget.services.announcements.setForeground(
      state == AppLifecycleState.resumed,
    );
    if (state == AppLifecycleState.resumed) {
      widget.services.refreshPublicDownloadPassword();
      _externalAvailable();
    }
  }

  @override
  void didChangePlatformBrightness() {
    widget.services.downloadOverlay.refreshAppearance();
  }

  void _externalAvailable() {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (!mounted ||
        _openingExternal ||
        _externalScheduled ||
        !widget.services.externalOpens.hasPending ||
        lifecycle != null && lifecycle != AppLifecycleState.resumed) {
      return;
    }
    _externalScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _externalScheduled = false;
      if (mounted) unawaited(_openExternal());
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _externalHome() async {
    final closing = <Future<Object?>>[];
    Navigator.of(context).popUntil((route) {
      if (route.isFirst) return true;
      if (route is TransitionRoute) closing.add(route.completed);
      return false;
    });
    // Dispose the previous player before starting another playback session.
    await Future.wait(closing);
  }

  Future<void> _openExternal() async {
    if (_openingExternal) return;
    _openingExternal = true;
    try {
      while (mounted) {
        final lifecycle = WidgetsBinding.instance.lifecycleState;
        if (lifecycle != null && lifecycle != AppLifecycleState.resumed) break;
        final request = widget.services.externalOpens.take();
        if (request == null) break;
        await _externalHome();
        if (!mounted) break;
        if (request.kind == ExternalOpenKind.error) {
          message(context, request.message);
        } else if (request.kind == ExternalOpenKind.play) {
          final page =
              widget.externalPlayerBuilder?.call(request) ??
              PlayerPage(
                externalPlayback(widget.services, request),
                subtitleDirectory: Directory(
                  '${widget.services.cacheDirectory.path}/playback-subtitles',
                ),
              );
          unawaited(
            Navigator.push<void>(
              context,
              MaterialPageRoute(builder: (_) => page),
            ),
          );
          await WidgetsBinding.instance.endOfFrame;
        } else {
          final url = request.downloadUrl;
          if (url != null) {
            widget.services.transferTab.value = 0;
            setState(() => selected = 2);
            await directDownloadDialog(
              context,
              widget.services,
              initial: url,
              fileName: request.name,
              headers: request.headers,
              external: true,
            );
          } else {
            setState(() => selected = 0);
            widget.services.sharedText.value = null;
            widget.services.sharedText.value = request.sharedText;
          }
        }
      }
    } catch (error, stack) {
      DiagnosticLog.error('app.external_open_failed', error, stack);
      if (mounted) message(context, errorText(error));
    } finally {
      _openingExternal = false;
      if (mounted) _externalAvailable();
    }
  }

  @override
  void onWindowFocus() {
    widget.services.clipboard.setForeground(true);
    widget.services.control.setForeground(true);
    widget.services.announcements.setForeground(true);
    widget.services.refreshPublicDownloadPassword();
  }

  @override
  void onWindowBlur() {
    widget.services.clipboard.setForeground(false);
    widget.services.control.setForeground(false);
    widget.services.announcements.setForeground(false);
  }

  void _useClipboard() {
    final suggestion = widget.services.clipboard.suggestion;
    if (suggestion == null) return;
    setState(() => selected = 0);
    parseKey.currentState?.acceptClipboard(suggestion.text);
    unawaited(widget.services.clipboard.acknowledge(suggestion));
  }

  void _shared() {
    if (mounted && widget.services.sharedText.value?.isNotEmpty == true) {
      setState(() => selected = 0);
    }
  }

  void _showDownloads() {
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    setState(() => selected = 2);
    DiagnosticLog.event('ui.tab', fields: {'tab': 'downloads'});
  }

  void _showLan() => unawaited(_openLan());

  Future<void> _openLan() async {
    if (!mounted || _openingLan) return;
    _openingLan = true;
    try {
      final text = await Navigator.push<String>(
        context,
        MaterialPageRoute(
          builder: (_) => DeviceLinkPage(
            widget.services,
            initialText: parseKey.currentState?.input.text ?? '',
          ),
        ),
      );
      if (!mounted || text == null || text.isEmpty) return;
      setState(() => selected = 0);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final parser = parseKey.currentState;
      parser?.acceptClipboard(text);
      await parser?.parse();
    } finally {
      _openingLan = false;
    }
  }

  Future<void> _desktop() async {
    try {
      await windowManager.setPreventClose(true);
      // AppIndicator reads PNG/SVG icons; .ico is a Windows-only container.
      await trayManager.setIcon(
        Platform.isWindows
            ? 'assets/icons/app.ico'
            : p.join(
                p.dirname(Platform.resolvedExecutable),
                'data',
                'flutter_assets',
                'assets',
                'icons',
                'app.png',
              ),
      );
      await trayManager.setToolTip('文析助手');
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'show', label: '打开文析助手'),
            MenuItem.separator(),
            MenuItem(key: 'pause', label: '停止全部传输'),
            MenuItem(key: 'exit', label: '退出'),
          ],
        ),
      );
      trayReady = true;
    } catch (_) {
      /* Closing still offers a visible pause-and-exit path. */
    }
  }

  @override
  void onTrayIconMouseDown() {
    windowManager.show();
    windowManager.focus();
  }

  @override
  void onTrayIconRightMouseDown() {
    // AppIndicator owns the menu on Linux and has no popUpContextMenu method;
    // calling it there only raises a missing-implementation error.
    if (Platform.isWindows) unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem item) {
    if (item.key == 'show') onTrayIconMouseDown();
    if (item.key == 'pause') {
      busy(context, widget.services.stopTransfers, label: '停止传输…');
    }
    if (item.key == 'exit') _close(forceExit: true);
  }

  @override
  void onWindowClose() {
    _close();
  }

  Future<void> _close({bool forceExit = false}) async {
    if (closing || !mounted) return;
    closing = true;
    try {
      final active =
          widget.services.downloads.tasks.any((t) => t.active) ||
          widget.services.uploads.activeCount > 0 ||
          widget.services.lan.running;
      if (active) {
        await windowManager.show();
        await windowManager.focus();
        if (!mounted) return;
        final action = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('还有传输任务'),
            content: Text(
              widget.services.lan.running
                  ? '设备互联正在运行。可保留后台传输；退出应用会结束文件分享。'
                  : '可保留后台传输，或停止任务后退出。中断的上传需要重新上传。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              if (trayReady && !forceExit)
                TextButton(
                  onPressed: () => Navigator.pop(context, 'background'),
                  child: const Text('后台传输'),
                ),
              TextButton(
                onPressed: () => Navigator.pop(context, 'exit'),
                child: const Text('暂停并退出'),
              ),
            ],
          ),
        );
        if (action == null) return;
        if (action == 'background') {
          await windowManager.hide();
          return;
        }
      }
      await widget.services.close();
      if (trayReady) await trayManager.destroy();
      DiagnosticRuntime.stop();
      await windowManager.destroy();
    } catch (e, stack) {
      DiagnosticLog.error('app.close_failed', e, stack);
      if (mounted) message(context, errorText(e));
    } finally {
      closing = false;
    }
  }

  @override
  void dispose() {
    widget.services.sharedText.removeListener(_shared);
    widget.services.downloadNavigation.removeListener(_showDownloads);
    widget.services.lanNavigation.removeListener(_showLan);
    widget.services.transferTab.removeListener(_transferTabChanged);
    widget.services.externalOpens.removeListener(_externalAvailable);
    WidgetsBinding.instance.removeObserver(this);
    widget.services.clipboard.removeListener(_clipboardChanged);
    widget.services.clipboard.setForeground(false);
    widget.services.control.setForeground(false);
    widget.services.announcements.setForeground(false);
    if (isDesktopPlatform && widget.services.platformFeatures) {
      windowManager.removeListener(this);
      trayManager.removeListener(this);
    }
    super.dispose();
  }

  Future<void> _menu(String action) async {
    switch (action) {
      case 'new':
        await directDownloadDialog(context, widget.services);
      case 'accounts':
        await Navigator.push<void>(
          context,
          MaterialPageRoute(builder: (_) => CloudAccountsPage(widget.services)),
        );
      case 'cloud-layout':
        await Navigator.push<void>(
          context,
          MaterialPageRoute(
            builder: (_) => CloudListSettingsPage(widget.services),
          ),
        );
      case 'refresh':
        await widget.services.refreshAccounts();
      case 'pause':
        await busy(
          context,
          widget.services.downloads.pauseAll,
          label: '暂停全部任务…',
        );
      case 'resume':
        await busy(context, widget.services.downloads.resumeAll);
      case 'clear':
        if (await confirm(context, '清理完成记录', '仅移除已完成记录，已下载的文件会保留。') &&
            mounted) {
          await busy(context, () async {
            for (final task in widget.services.downloads.tasks.where(
              (t) => t.status == DownloadStatus.completed,
            )) {
              await widget.services.downloads.delete(task.id);
            }
          });
        }
      case 'about':
        await showWenxiAbout(context, widget.services.control);
      case 'donate':
        await Navigator.push<void>(
          context,
          MaterialPageRoute(builder: (_) => const DonatePage()),
        );
      case 'stop-uploads':
        if (await confirm(context, '停止全部上传', '未完成任务将停止，重试时会从头上传。') && mounted) {
          await busy(context, widget.services.uploads.stopAll);
        }
      case 'clear-uploads':
        await busy(context, widget.services.uploads.clearCompleted);
    }
  }

  List<AppMenuAction<String>> get menu => switch (selected) {
    1 => const [
      AppMenuAction(
        value: 'cloud-layout',
        label: '排序与隐藏',
        icon: CupertinoIcons.slider_horizontal_3,
      ),
      AppMenuAction(
        value: 'accounts',
        label: '账号管理',
        icon: CupertinoIcons.person_2,
      ),
      AppMenuAction(
        value: 'refresh',
        label: '刷新全部账号',
        icon: CupertinoIcons.arrow_clockwise,
      ),
    ],
    2 when widget.services.transferTab.value == 1 => const [
      AppMenuAction(
        value: 'stop-uploads',
        label: '停止全部上传',
        icon: CupertinoIcons.stop,
      ),
      AppMenuAction(
        value: 'clear-uploads',
        label: '清理完成记录',
        icon: CupertinoIcons.trash,
      ),
    ],
    2 => const [
      AppMenuAction(
        value: 'new',
        label: '新建下载',
        icon: CupertinoIcons.plus_circle,
      ),
      AppMenuAction(value: 'pause', label: '全部暂停', icon: CupertinoIcons.pause),
      AppMenuAction(
        value: 'resume',
        label: '继续未完成任务',
        icon: CupertinoIcons.play,
      ),
      AppMenuAction(
        value: 'clear',
        label: '清理完成记录',
        icon: CupertinoIcons.trash,
      ),
    ],
    _ => const [
      AppMenuAction(value: 'donate', label: '打赏作者', icon: CupertinoIcons.gift),
      AppMenuAction(
        value: 'about',
        label: '关于文析助手',
        icon: CupertinoIcons.info_circle,
      ),
    ],
  };
  Widget _navigation(BuildContext context, {required bool rail}) =>
      AppNavigation(
        selectedIndex: selected,
        transfers: widget.services.navigationTransfers,
        rail: rail,
        onSelected: (index) {
          DiagnosticLog.event(
            'ui.tab',
            fields: {
              'tab': ['parse', 'cloud', 'downloads', 'mine'][index],
            },
          );
          setState(() => selected = index);
        },
      );

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      for (var i = 0; i < 4; i++)
        SingleActivator(
          [
            LogicalKeyboardKey.digit1,
            LogicalKeyboardKey.digit2,
            LogicalKeyboardKey.digit3,
            LogicalKeyboardKey.digit4,
          ][i],
          control: true,
        ): () =>
            setState(() => selected = i),
      const SingleActivator(LogicalKeyboardKey.keyL, control: true): () {
        setState(() => selected = 0);
        parseKey.currentState?.focusInput();
      },
    },
    child: Focus(
      autofocus: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return AppBackground(
            repository: widget.services.backgrounds,
            settings: widget.services.settings.background,
            child: Builder(
              builder: (context) {
                final rail = constraints.maxWidth >= 820;
                final desktopHeader =
                    (selected == 0 || selected == 3) &&
                    isDesktopTarget(Theme.of(context).platform);
                final content = Scaffold(
                  extendBody: !rail,
                  backgroundColor: BackgroundScope.of(context)?.active == true
                      ? Colors.transparent
                      : Theme.of(context).brightness == Brightness.dark
                      ? const Color(0xff101012)
                      : const Color(0xfff7f8fb),
                  appBar: AppBar(
                    backgroundColor: backgroundSurface(context),
                    title: Text(titles[selected]),
                    centerTitle: desktopHeader ? false : null,
                    titleSpacing: desktopHeader ? 28 : null,
                    toolbarHeight: desktopHeader ? 52 : null,
                    actions: [
                      if (selected == 0)
                        AnimatedBuilder(
                          animation: widget.services.lan,
                          builder: (context, _) => Tooltip(
                            message: '设备互联',
                            child: TextButton.icon(
                              key: const Key('parse-device-link'),
                              onPressed: _showLan,
                              icon: Badge.count(
                                count: widget.services.lan.unread,
                                isLabelVisible: widget.services.lan.unread > 0,
                                child: const Icon(
                                  Icons.devices_rounded,
                                  size: 21,
                                ),
                              ),
                              label: const Text('互联'),
                            ),
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: selected == 0
                            ? AnnouncementButton(widget.services.announcements)
                            : AppPopupMenuButton<String>(
                                tooltip: '更多操作',
                                onSelected: _menu,
                                actions: menu,
                                icon: CupertinoIcons.ellipsis,
                              ),
                      ),
                    ],
                  ),
                  body: SafeArea(
                    top: false,
                    bottom: rail,
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1120),
                        child: Column(
                          children: [
                            RemoteControlPrompts(
                              widget.services.control,
                              updater: widget.services.appUpdates,
                            ),
                            GuestDownloadPrompt(widget.services),
                            DownloadShutdownPrompt(
                              widget.services.downloadShutdown,
                              showWindow:
                                  widget.services.platformFeatures &&
                                      isDesktopPlatform
                                  ? () async {
                                      await windowManager.show();
                                      await windowManager.focus();
                                    }
                                  : null,
                            ),
                            if (widget.services.clipboard.suggestion
                                case final suggestion?)
                              ClipboardLinkBanner(
                                suggestion: suggestion,
                                onUse: _useClipboard,
                                onDismiss: () => unawaited(
                                  widget.services.clipboard.acknowledge(
                                    suggestion,
                                  ),
                                ),
                              ),
                            Expanded(
                              child: IndexedStack(
                                index: selected,
                                children: [
                                  ParsePage(
                                    widget.services,
                                    key: parseKey,
                                    active: selected == 0,
                                  ),
                                  CloudPage(
                                    widget.services,
                                    onParseShare: () {
                                      setState(() => selected = 0);
                                      WidgetsBinding.instance
                                          .addPostFrameCallback((_) {
                                            if (mounted && selected == 0) {
                                              parseKey.currentState?.focus
                                                  .requestFocus();
                                            }
                                          });
                                    },
                                  ),
                                  TransfersPage(
                                    widget.services,
                                    active: selected == 2,
                                  ),
                                  MinePage(widget.services),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  bottomNavigationBar: rail
                      ? null
                      : _navigation(context, rail: false),
                );
                return rail
                    ? Row(
                        children: [
                          Material(
                            color: backgroundSurface(context),
                            child: _navigation(context, rail: true),
                          ),
                          Expanded(child: content),
                        ],
                      )
                    : content;
              },
            ),
          );
        },
      ),
    ),
  );
}
