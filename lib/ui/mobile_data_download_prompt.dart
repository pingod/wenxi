import 'dart:async';
import 'package:flutter/material.dart';
import '../download/mobile_data_download_guard.dart';
import '../platform/download_network.dart';

class MobileDataDownloadPrompt extends StatefulWidget {
  const MobileDataDownloadPrompt(this.guard, {super.key});
  final MobileDataDownloadGuard guard;

  @override
  State<MobileDataDownloadPrompt> createState() =>
      _MobileDataDownloadPromptState();
}

class _MobileDataDownloadPromptState extends State<MobileDataDownloadPrompt>
    with WidgetsBindingObserver {
  DialogRoute<MobileDataDownloadChoice>? _route;
  MobileDataDownloadRequest? _shownRequest;
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.guard.attachPresenter();
    widget.guard.addListener(_changed);
    _changed();
  }

  @override
  void didUpdateWidget(MobileDataDownloadPrompt oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.guard == widget.guard) return;
    oldWidget.guard.removeListener(_changed);
    oldWidget.guard.detachPresenter();
    _removeRoute(defer: true);
    widget.guard.attachPresenter();
    widget.guard.addListener(_changed);
    _changed();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _changed();

  void _changed() {
    if (!mounted || _scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) unawaited(_sync());
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _removeRoute({bool defer = false}) {
    final route = _route;
    _route = null;
    _shownRequest = null;
    void remove() {
      if (route?.isActive == true) route!.navigator?.removeRoute(route);
    }

    if (defer) {
      WidgetsBinding.instance.addPostFrameCallback((_) => remove());
    } else {
      remove();
    }
  }

  Future<void> _sync() async {
    final guard = widget.guard, request = guard.request;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (request == null ||
        request.answered ||
        lifecycle != null && lifecycle != AppLifecycleState.resumed) {
      _removeRoute();
      return;
    }
    if (_route != null && _shownRequest == request) return;
    _removeRoute();
    _shownRequest = request;
    var remember = false;
    final route = _route = DialogRoute<MobileDataDownloadChoice>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          key: const ValueKey('mobile-data-download-prompt'),
          scrollable: true,
          title: const Text('流量下载提醒'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                request.network == DownloadNetwork.mobile
                    ? '当前正在使用移动数据，下载会消耗手机流量。是否继续下载？'
                    : '暂时无法确认当前网络类型，下载可能消耗手机流量。是否继续下载？',
                style: const TextStyle(fontSize: 14, height: 1.6),
              ),
              const SizedBox(height: 12),
              CheckboxListTile(
                key: const ValueKey('mobile-data-download-remember'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                dense: true,
                value: remember,
                onChanged: (value) => setState(() => remember = value ?? false),
                title: const Text('不再提醒'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.pop(context, MobileDataDownloadChoice.cancel),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                context,
                remember
                    ? MobileDataDownloadChoice.alwaysDownload
                    : MobileDataDownloadChoice.download,
              ),
              child: const Text('继续下载'),
            ),
          ],
        ),
      ),
    );
    final choice = await Navigator.of(context, rootNavigator: true).push(route);
    if (!mounted || _route != route || widget.guard != guard) return;
    guard.answer(request, choice ?? MobileDataDownloadChoice.cancel);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.guard.removeListener(_changed);
    widget.guard.detachPresenter();
    _removeRoute(defer: true);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
