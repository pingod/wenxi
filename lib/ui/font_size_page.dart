import 'package:flutter/material.dart';
import '../app_services.dart';
import '../domain/settings.dart';
import 'app_text_scale.dart';
import 'common.dart';

class FontSizePage extends StatefulWidget {
  const FontSizePage(this.services, {super.key});

  final AppServices services;

  @override
  State<FontSizePage> createState() => _FontSizePageState();
}

class _FontSizePageState extends State<FontSizePage> {
  late int _percent = widget.services.settings.fontScalePercent;
  bool _saving = false;

  Future<void> _apply() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.services.updateSettings({'fontScalePercent': _percent});
      if (mounted) message(context, '字体大小已应用');
    } catch (error) {
      if (mounted) message(context, errorText(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final current = media.textScaler;
    final system = current is AppTextScaler ? current.system : current;
    return Scaffold(
      appBar: AppBar(title: const Text('字体大小')),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                const Text('在系统字体大小的基础上调整。100% 跟随系统，修改后点击下方按钮应用。'),
                const SizedBox(height: 24),
                MediaQuery(
                  data: media.copyWith(
                    textScaler: AppTextScaler(system, _percent / 100),
                  ),
                  child: Material(
                    color: fill(context),
                    borderRadius: BorderRadius.circular(16),
                    child: const Padding(
                      padding: EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '字体效果预览',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          SizedBox(height: 12),
                          Text(
                            '分享解析、网盘文件与下载记录',
                            key: Key('font-size-preview'),
                            style: TextStyle(fontSize: 14, height: 1.6),
                          ),
                          SizedBox(height: 8),
                          Text(
                            '选择适合自己的大小，让阅读更轻松。',
                            style: TextStyle(fontSize: 12, height: 1.6),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  _percent == 100 ? '100% · 跟随系统' : '$_percent%',
                  key: const Key('font-size-value'),
                  textAlign: TextAlign.center,
                ),
                Slider(
                  key: const Key('font-size-slider'),
                  min: AppSettings.minFontScalePercent.toDouble(),
                  max: AppSettings.maxFontScalePercent.toDouble(),
                  divisions:
                      (AppSettings.maxFontScalePercent -
                          AppSettings.minFontScalePercent) ~/
                      5,
                  value: _percent.toDouble(),
                  label: '$_percent%',
                  onChanged: _saving
                      ? null
                      : (value) => setState(() => _percent = value.round()),
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    for (final value in [80, 100, 120, 140, 160, 180])
                      ChoiceChip(
                        key: ValueKey('font-size-$value'),
                        label: Text('$value%'),
                        selected: _percent == value,
                        onSelected: _saving
                            ? null
                            : (_) => setState(() => _percent = value),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                TextButton(
                  key: const Key('font-size-reset'),
                  onPressed: _saving
                      ? null
                      : () => setState(() => _percent = 100),
                  child: const Text('恢复跟随系统'),
                ),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(20, 12, 20, 16),
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const Key('font-size-apply'),
                onPressed:
                    _saving ||
                        _percent == widget.services.settings.fontScalePercent
                    ? null
                    : _apply,
                child: Text(_saving ? '正在应用…' : '应用字体大小'),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
