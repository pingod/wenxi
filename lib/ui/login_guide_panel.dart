import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../domain/login_guide.dart';
import 'common.dart';

/// Walk-through for logging in with the system browser.
///
/// Linux has no embedded web view, so platforms whose only login is a browser
/// session fall back to pasting a Cookie or token. This panel opens the site,
/// states exactly which value to copy, and offers to move a matching clipboard
/// value into the credential field.
class LoginGuidePanel extends StatefulWidget {
  const LoginGuidePanel({
    super.key,
    required this.guide,
    required this.onFill,
    this.enabled = true,
    this.openBrowser,
    this.readClipboard,
    this.pollInterval = const Duration(seconds: 1),
  });

  final LoginGuide guide;

  /// Receives a credential that already passed the platform's own validation.
  final ValueChanged<String> onFill;

  /// Cleared while the page is submitting, so a late clipboard read cannot
  /// overwrite the field the user is about to send.
  final bool enabled;

  final Future<bool> Function(Uri url)? openBrowser;
  final Future<String?> Function()? readClipboard;
  final Duration pollInterval;

  @override
  State<LoginGuidePanel> createState() => _LoginGuidePanelState();
}

class _LoginGuidePanelState extends State<LoginGuidePanel> {
  Timer? _timer;
  bool _open = true, _watching = false, _busy = false;
  String? _found;

  static Future<bool> _launch(Uri url) =>
      launchUrl(url, mode: LaunchMode.externalApplication);

  static Future<String?> _read() async =>
      (await Clipboard.getData(Clipboard.kTextPlain))?.text;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _openSite() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final url = Uri.parse(widget.guide.url);
      final opened = await (widget.openBrowser ?? _launch)(url);
      if (!mounted) return;
      if (!opened) {
        message(context, '暂时无法打开浏览器，请手动访问 ${widget.guide.url}');
        return;
      }
      _watch();
    } catch (_) {
      if (mounted) message(context, '暂时无法打开浏览器，请手动访问 ${widget.guide.url}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Poll the clipboard once the browser has been opened, because that is the
  /// moment the user starts copying the credential. The poll stops on the first
  /// match or when the page is left.
  void _watch() {
    _timer?.cancel();
    setState(() => _watching = true);
    _timer = Timer.periodic(widget.pollInterval, (_) => _poll());
  }

  Future<void> _poll() async {
    if (!mounted || !_watching) return;
    try {
      final text = await (widget.readClipboard ?? _read)();
      if (!mounted || !_watching) return;
      final value = LoginGuide.extract(widget.guide.platform, text);
      if (value == null || value == _found) return;
      _timer?.cancel();
      setState(() {
        _found = value;
        _watching = false;
      });
    } catch (_) {
      // A clipboard the platform cannot read must not break the page.
      _timer?.cancel();
      if (mounted) setState(() => _watching = false);
    }
  }

  void _stop() {
    _timer?.cancel();
    setState(() => _watching = false);
  }

  void _fill() {
    final value = _found;
    if (value == null) return;
    widget.onFill(value);
    setState(() => _found = null);
    message(context, '已填入剪贴板中的凭据，请确认后点击「验证并保存」');
  }

  Widget _step(int index, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 22,
          child: Text(
            '${index + 1}.',
            style: TextStyle(fontSize: 13, color: secondary(context)),
          ),
        ),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 13,
              height: 1.45,
              color: secondary(context),
            ),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final guide = widget.guide;
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: fill(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: border(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            child: Row(
              children: [
                Icon(
                  CupertinoIcons.compass,
                  size: 18,
                  color: secondary(context),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    guide.title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Icon(
                  _open
                      ? CupertinoIcons.chevron_up
                      : CupertinoIcons.chevron_down,
                  size: 16,
                  color: secondary(context),
                ),
              ],
            ),
          ),
          if (_open) ...[
            const SizedBox(height: 12),
            for (var i = 0; i < guide.steps.length; i++)
              _step(i, guide.steps[i]),
            const SizedBox(height: 4),
            Row(
              children: [
                FilledButton.tonalIcon(
                  key: const ValueKey('login-guide-open'),
                  onPressed: _busy ? null : _openSite,
                  icon: const Icon(
                    CupertinoIcons.arrow_up_right_square,
                    size: 18,
                  ),
                  label: const Text('打开官网'),
                ),
                const SizedBox(width: 10),
                if (_watching)
                  TextButton(onPressed: _stop, child: const Text('停止读取剪贴板'))
                else
                  Text(
                    '复制凭据后会自动提示填入',
                    style: TextStyle(fontSize: 12, color: secondary(context)),
                  ),
              ],
            ),
            if (_watching)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Row(
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: secondary(context),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '已打开浏览器，登录并复制凭据后会在这里提示',
                        style: TextStyle(
                          fontSize: 12,
                          color: secondary(context),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (_found != null)
              Container(
                margin: const EdgeInsets.only(top: 12),
                padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    const Icon(CupertinoIcons.doc_on_clipboard, size: 18),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '已从剪贴板读取到${guide.platform.shortName}凭据',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    TextButton(
                      key: const ValueKey('login-guide-fill'),
                      onPressed: widget.enabled ? _fill : null,
                      child: const Text('填入'),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}
