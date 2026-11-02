import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../download/download_shutdown.dart';

/// Stays mounted at the shell so a tray download can also show its countdown.
class DownloadShutdownPrompt extends StatefulWidget {
  const DownloadShutdownPrompt(this.controller, {super.key, this.showWindow});
  final DownloadShutdown controller;
  final Future<void> Function()? showWindow;

  @override
  State<DownloadShutdownPrompt> createState() => _DownloadShutdownPromptState();
}

class _DownloadShutdownPromptState extends State<DownloadShutdownPrompt> {
  DialogRoute<void>? _route;
  bool _scheduled = false, _showing = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    _changed();
  }

  void _changed() {
    if (!mounted || _scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) unawaited(_sync());
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _sync() async {
    final controller = widget.controller;
    if (!controller.countingDown) {
      final route = _route;
      _route = null;
      if (route?.isActive == true) route!.navigator?.removeRoute(route);
      return;
    }
    if (_route != null || _showing) return;
    _showing = true;
    try {
      await widget.showWindow?.call();
      if (!mounted || !controller.countingDown) return;
      final route = _route = DialogRoute<void>(
        context: context,
        builder: (context) => AnimatedBuilder(
          animation: controller,
          builder: (context, _) => AlertDialog(
            icon: Icon(
              controller.action == DownloadCompletionAction.hibernate
                  ? CupertinoIcons.moon
                  : CupertinoIcons.power,
              size: 28,
              color: Theme.of(context).colorScheme.primary,
            ),
            scrollable: true,
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 12,
            ),
            title: Text('下载完成，即将${controller.action.label}'),
            content: SizedBox(
              width: 340,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${controller.remainingSeconds ?? 0}',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.displaySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    controller.action == DownloadCompletionAction.hibernate
                        ? '秒后进入休眠'
                        : '秒后关闭电脑',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                  LinearProgressIndicator(
                    value:
                        ((controller.remainingSeconds ?? 0) /
                                controller.countdownSeconds)
                            .clamp(0.0, 1.0),
                    minHeight: 4,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    controller.action == DownloadCompletionAction.hibernate
                        ? '全部文件已保存，唤醒后可继续当前工作。'
                        : '全部文件已保存，请保存其他应用中的工作。',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
            actions: [
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => controller.setEnabled(false),
                  child: Text('取消${controller.action.label}'),
                ),
              ),
            ],
          ),
        ),
      );
      await Navigator.of(context, rootNavigator: true).push(route);
      if (_route == route) {
        _route = null;
        // Esc/back/barrier dismissals cancel the opt-in, just like the button.
        controller.setEnabled(false);
      }
    } catch (_) {
      controller.setEnabled(false);
    } finally {
      _showing = false;
      if (mounted) _changed();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    widget.controller.setEnabled(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
