import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../data/http.dart';
import '../preview/text_document.dart';
import '../preview/text_preview_loader.dart';
import 'common.dart';

class TextPreview extends StatefulWidget {
  const TextPreview(this.document, {super.key});
  final TextDocument document;
  @override
  State<TextPreview> createState() => _TextPreviewState();
}

class _TextPreviewState extends State<TextPreview> {
  final vertical = ScrollController(), horizontal = ScrollController();
  late bool wrap = widget.document.language == null;
  double fontSize = 14;
  @override
  void dispose() {
    vertical.dispose();
    horizontal.dispose();
    super.dispose();
  }

  Color? _tokenColor(String scope, bool dark) => switch (scope
      .split('.')
      .first) {
    'keyword' ||
    'selector-tag' ||
    'meta' => Color(dark ? 0xffc5a5ff : 0xff7950b3),
    'string' ||
    'regexp' ||
    'attr' ||
    'attribute' => Color(dark ? 0xff9ad9b1 : 0xff237b4b),
    'number' || 'literal' || 'symbol' => Color(dark ? 0xffffca82 : 0xffad5500),
    'title' ||
    'built_in' ||
    'type' ||
    'selector-class' => Color(dark ? 0xff93caff : 0xff225da7),
    'comment' || 'quote' => Color(dark ? 0xff97a4b5 : 0xff6a7482),
    'variable' || 'params' => Color(dark ? 0xffefaaaa : 0xffa54545),
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final doc = widget.document, theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final scale = MediaQuery.textScalerOf(context);
    final style = TextStyle(
      fontFamily: 'monospace',
      fontSize: fontSize,
      height: 1.65,
      color: theme.colorScheme.onSurface,
    );
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.only(left: 16, right: 4),
          decoration: BoxDecoration(
            color: fill(context),
            border: Border(bottom: BorderSide(color: border(context))),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${doc.language ?? '文本'} · ${doc.encoding}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: secondary(context)),
                ),
              ),
              IconButton(
                key: const Key('text-preview-wrap'),
                tooltip: wrap ? '关闭自动换行' : '自动换行',
                isSelected: wrap,
                onPressed: () => setState(() => wrap = !wrap),
                icon: const Icon(Icons.wrap_text, size: 21),
              ),
              PopupMenuButton<double>(
                tooltip: '文字大小',
                initialValue: fontSize,
                icon: const Icon(Icons.text_fields, size: 21),
                onSelected: (size) => setState(() => fontSize = size),
                itemBuilder: (_) => [
                  for (final size in [12.0, 14.0, 16.0, 18.0, 20.0])
                    CheckedPopupMenuItem(
                      value: size,
                      checked: size == fontSize,
                      child: Text('${size.toInt()} 号'),
                    ),
                ],
              ),
              IconButton(
                key: const Key('text-preview-copy'),
                tooltip: '复制全部',
                onPressed: () async {
                  try {
                    await Clipboard.setData(ClipboardData(text: doc.text));
                    if (context.mounted) {
                      message(context, doc.truncated ? '已复制当前预览内容' : '内容已复制');
                    }
                  } catch (_) {
                    if (context.mounted) message(context, '复制失败，请长按选择文字');
                  }
                },
                icon: const Icon(CupertinoIcons.doc_on_doc, size: 19),
              ),
            ],
          ),
        ),
        if (doc.truncated || doc.language != null && !doc.highlighted)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: theme.colorScheme.secondaryContainer.withValues(alpha: .45),
            child: Text(
              doc.truncated
                  ? '文件较大，仅显示前 ${doc.text.length} 个字符。'
                  : '代码较大，已使用纯文本显示。',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        Expanded(
          child: doc.text.isEmpty
              ? const Center(child: Text('文件为空'))
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final width = wrap
                        ? constraints.maxWidth
                        : math.max(
                            constraints.maxWidth,
                            doc.lines.fold<int>(
                                      0,
                                      (length, line) => math.max(
                                        length,
                                        line.replaceAll('\t', '    ').length,
                                      ),
                                    ) *
                                    scale.scale(fontSize) +
                                80,
                          );
                    final list = SizedBox(
                      width: width,
                      height: constraints.maxHeight,
                      child: Scrollbar(
                        controller: vertical,
                        child: ListView.builder(
                          controller: vertical,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          itemCount: doc.lines.length,
                          itemBuilder: (context, index) => Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (doc.language != null)
                                SizedBox(
                                  width: 54,
                                  child: Padding(
                                    padding: const EdgeInsets.only(right: 14),
                                    child: SelectionContainer.disabled(
                                      child: Text(
                                        '${index + 1}',
                                        textAlign: TextAlign.right,
                                        textScaler: scale,
                                        style: style.copyWith(
                                          color: secondary(
                                            context,
                                          ).withValues(alpha: .65),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              Expanded(
                                child: Padding(
                                  padding: EdgeInsets.only(
                                    left: doc.language == null ? 20 : 0,
                                    right: 20,
                                  ),
                                  child: Text.rich(
                                    TextSpan(
                                      children: [
                                        if (doc.tokens != null)
                                          for (final token
                                              in doc.tokens![index])
                                            TextSpan(
                                              text: token.text.replaceAll(
                                                '\t',
                                                '    ',
                                              ),
                                              style: TextStyle(
                                                color: _tokenColor(
                                                  token.scope,
                                                  dark,
                                                ),
                                              ),
                                            )
                                        else
                                          TextSpan(
                                            text: doc.lines[index].replaceAll(
                                              '\t',
                                              '    ',
                                            ),
                                          ),
                                        if (doc.lines[index].isEmpty)
                                          const TextSpan(text: ' '),
                                      ],
                                    ),
                                    key: ValueKey('text-preview-line-$index'),
                                    style: style,
                                    textScaler: scale,
                                    softWrap: wrap,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                    return SelectionArea(
                      child: wrap
                          ? list
                          : Scrollbar(
                              controller: horizontal,
                              notificationPredicate: (n) =>
                                  n.metrics.axis == Axis.horizontal,
                              child: SingleChildScrollView(
                                controller: horizontal,
                                scrollDirection: Axis.horizontal,
                                child: list,
                              ),
                            ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class LocalTextPreviewPage extends StatefulWidget {
  const LocalTextPreviewPage({
    super.key,
    required this.path,
    required this.name,
  });
  final String path, name;
  @override
  State<LocalTextPreviewPage> createState() => _LocalTextPreviewPageState();
}

class _LocalTextPreviewPageState extends State<LocalTextPreviewPage> {
  final scope = RequestScope();
  TextDocument? document;
  String error = '';
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => error = '');
    try {
      final value = await scope.run(
        () => TextPreviewLoader.local(widget.path, widget.name),
      );
      if (mounted) setState(() => document = value);
    } catch (e) {
      if (mounted) setState(() => error = errorText(e));
    }
  }

  @override
  void dispose() {
    scope.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    title: widget.name,
    child: document != null
        ? TextPreview(document!)
        : error.isNotEmpty
        ? EmptyPanel(
            '暂时无法预览',
            error,
            icon: CupertinoIcons.doc_text,
            action: TextButton(onPressed: _load, child: const Text('重试')),
          )
        : const Center(child: CircularProgressIndicator()),
  );
}
