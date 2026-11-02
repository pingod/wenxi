import 'dart:convert';

import 'package:html/parser.dart' as html;

import '../core/json.dart';

/// Parses a published UC command without executing any document scripts.
class UcPublishedCommand {
  static final _bootstrapStart = RegExp(
    r'^window\.appData\s*=\s*JSON\.parse\(\s*decodeURIComponent\(\s*',
  );
  static final _bootstrapEnd = RegExp(r'^\s*\)\s*\)');
  static const _maximumLength = 2000;
  static final _invisible = RegExp(r'[\u200b-\u200d\u2060\uFEFF]');
  static final _label = RegExp(r'口令\s*[:：]\s*(.+)$');

  static String _clean(String text) => text.replaceAll(_invisible, '').trim();

  static String _unquote(String text) {
    final value = _clean(text);
    const quotes = {'「': '」', '『': '』', '“': '”', '"': '"', '`': '`'};
    if (value.length >= 2 && quotes[value[0]] == value[value.length - 1]) {
      return _clean(value.substring(1, value.length - 1));
    }
    return value;
  }

  static Iterable<String> _fencedBlocks(String text) sync* {
    var marker = '', width = 0;
    final lines = <String>[];
    for (final line in const LineSplitter().convert(text)) {
      final trimmed = line.trimLeft();
      if (marker.isEmpty) {
        if (!trimmed.startsWith('```') && !trimmed.startsWith('~~~')) continue;
        marker = trimmed[0];
        width = 0;
        while (width < trimmed.length && trimmed[width] == marker) {
          width++;
        }
      } else if (trimmed.startsWith(marker * width) &&
          trimmed.trimRight().split('').every((char) => char == marker)) {
        yield lines.join('\n');
        lines.clear();
        marker = '';
      } else {
        lines.add(line);
      }
    }
  }

  static String _window(String text, int start) =>
      text.substring(start, (start + 160).clamp(start, text.length));

  static String? _bootstrapLiteral(String page) {
    const marker = 'window.appData';
    var offset = 0;
    while (true) {
      final start = page.indexOf(marker, offset);
      if (start < 0) return null;
      // Match only the short call header. Repeating regex alternatives over
      // the entire encoded document exhausts the AOT interpreter's stack.
      final header = _bootstrapStart.firstMatch(_window(page, start));
      if (header == null) {
        offset = start + marker.length;
        continue;
      }
      final quote = start + header.end;
      require(
        quote < page.length && page.codeUnitAt(quote) == 0x22,
        '每日口令页面数据格式异常',
      );
      var cursor = quote + 1;
      while (cursor < page.length) {
        final char = page.codeUnitAt(cursor);
        if (char == 0x5c) {
          // Skip an escaped code unit, including escaped quotes/backslashes.
          cursor += 2;
        } else if (char == 0x22) {
          final end = cursor + 1;
          require(_bootstrapEnd.hasMatch(_window(page, end)), '每日口令页面数据不完整');
          return page.substring(quote, end);
        } else {
          cursor++;
        }
      }
      throw const AppException('每日口令页面数据不完整');
    }
  }

  static String extract(String page) {
    var content = page;
    final literal = _bootstrapLiteral(page);
    if (literal != null) {
      try {
        final encoded = jsonDecode(literal) as String;
        final doc = asJson(jsonDecode(Uri.decodeComponent(encoded))).obj('doc');
        content = [
          doc.str('body_html'),
          doc.obj('_cachedContent').str('body'),
          doc.str('body'),
        ].firstWhere((body) => body.trim().isNotEmpty, orElse: () => '');
      } on FormatException {
        throw const AppException('每日口令页面数据格式异常');
      } on ArgumentError {
        throw const AppException('每日口令页面数据格式异常');
      }
      require(content.isNotEmpty, '每日口令页面没有公开正文');
    }

    final document = html.parse(content);
    for (final node in document.querySelectorAll(
      'script, style, noscript, template, img, svg, [hidden], '
      '[aria-hidden="true"]',
    )) {
      node.remove();
    }
    final body =
        document.querySelector(
          'article, .markdown-body, .ne-viewer-body, main',
        ) ??
        document.body;
    require(body != null, '每日口令页面没有有效正文');
    final candidates = <String>{};
    void add(String text) {
      final value = _clean(text);
      if (value.isEmpty) return;
      require(value.length <= _maximumLength, '每日口令内容过长');
      candidates.add(value);
    }

    // The publisher's copyable blocks identify the input. The UC endpoint
    // validates it, so changing token prefixes or suffixes needs no app update.
    for (final code in body!.querySelectorAll('pre, code')) {
      add(code.text);
    }
    if (candidates.isEmpty) {
      for (final block in _fencedBlocks(body.text)) {
        add(block);
      }
    }
    if (candidates.isEmpty) {
      void addSnippet(String snippet) {
        final text = _clean(snippet), labelled = _label.firstMatch(text);
        if (labelled != null) {
          add(_unquote(labelled[1]!));
        } else if (_unquote(text) != text) {
          add(_unquote(text));
        }
      }

      for (final node in body.querySelectorAll('p, li, blockquote')) {
        addSnippet(node.text);
      }
      if (candidates.isEmpty) {
        for (final line in const LineSplitter().convert(body.text)) {
          addSnippet(line);
        }
      }
    }
    if (candidates.isEmpty &&
        !content.contains(RegExp(r'[<>\r\n]')) &&
        _clean(content).isNotEmpty) {
      add(content);
    }
    require(candidates.length == 1, '每日口令页面没有唯一的 UC 口令');
    return candidates.single;
  }
}
