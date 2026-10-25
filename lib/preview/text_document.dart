import 'dart:convert';
import 'dart:typed_data';
import 'package:enough_convert/gbk.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/c.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/csharp.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/dos.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/ini.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/kotlin.dart';
import 'package:re_highlight/languages/lua.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/php.dart';
import 'package:re_highlight/languages/powershell.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/ruby.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/scss.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/swift.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import '../core/json.dart';
import '../domain/file_types.dart';

class TextToken {
  const TextToken(this.text, this.scope);
  final String text, scope;
}

class TextDocument {
  const TextDocument({
    required this.text,
    required this.lines,
    required this.encoding,
    required this.truncated,
    this.language,
    this.tokens,
  });
  static const maxBytes = 2 * 1024 * 1024;
  static const maxCharacters = 250000;
  static const maxLines = 10000;
  static const maxLineLength = 12000;
  static const maxHighlightedCharacters = 64000;
  final String text, encoding;
  final String? language;
  final List<String> lines;
  final bool truncated;
  final List<List<TextToken>>? tokens;
  bool get highlighted => tokens != null;
}

// Decoding and grammar parsing run outside the UI isolate. Nothing is evaluated.
TextDocument decodeTextDocument((Uint8List, String, bool) input) {
  final (bytes, name, partial) = input;
  bool starts(List<int> signature) =>
      bytes.length >= signature.length &&
      List.generate(
        signature.length,
        (i) => i,
      ).every((i) => bytes[i] == signature[i]);
  require(
    ![
      [0x50, 0x4b, 3, 4],
      [0x50, 0x4b, 5, 6],
      [0x50, 0x4b, 7, 8],
      [0x52, 0x61, 0x72, 0x21],
      [0x37, 0x7a, 0xbc, 0xaf],
      [0x1f, 0x8b],
    ].any(starts),
    '文件实际是压缩包，请使用解压工具查看',
  );
  var encoding = 'UTF-8';
  String content;
  if (starts([0xff, 0xfe]) || starts([0xfe, 0xff])) {
    final little = bytes[0] == 0xff;
    encoding = little ? 'UTF-16 LE' : 'UTF-16 BE';
    require(partial || bytes.length.isEven, '文本编码不完整');
    content = String.fromCharCodes([
      for (var i = 2; i + 1 < bytes.length; i += 2)
        little ? bytes[i] | bytes[i + 1] << 8 : bytes[i] << 8 | bytes[i + 1],
    ]);
  } else {
    require(!bytes.contains(0), '文件包含二进制内容，无法作为文本预览');
    try {
      content = _decodeBounded(
        bytes,
        (value) => utf8.decode(value),
        partial,
        3,
      );
    } on FormatException {
      encoding = 'GBK';
      try {
        content = _decodeBounded(bytes, gbk.decode, partial, 1);
      } on FormatException {
        throw const AppException('无法识别文本编码，支持 UTF-8、UTF-16 和 GBK');
      }
    }
  }
  content = content
      .replaceFirst(RegExp(r'^\uFEFF'), '')
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n');
  require(
    !RegExp(r'[\x00-\x08\x0b\x0e-\x1f\x7f]').hasMatch(content),
    '文件包含二进制内容，无法作为文本预览',
  );
  var truncated = partial;
  if (content.length > TextDocument.maxCharacters) {
    content = _prefix(content, TextDocument.maxCharacters);
    truncated = true;
  }
  final allLines = content.split('\n'), lines = <String>[];
  for (final line in allLines) {
    if (lines.length == TextDocument.maxLines) {
      truncated = true;
      break;
    }
    if (line.length > TextDocument.maxLineLength) {
      lines.add(_prefix(line, TextDocument.maxLineLength));
      truncated = true;
      break;
    }
    lines.add(line);
  }
  content = lines.join('\n');
  final language = textFileLanguage(name);
  List<List<TextToken>>? tokens;
  if (language != null &&
      content.length <= TextDocument.maxHighlightedCharacters) {
    try {
      final grammar = _languages[language];
      if (grammar != null) {
        final highlighter = Highlight()
          ..registerLanguages({
            language: grammar,
            if (language != 'xml') 'xml': langXml,
          });
        final renderer = _TokenRenderer();
        highlighter
            .highlight(code: content, language: language)
            .render(renderer);
        if (renderer.lines
                .map((line) => line.map((t) => t.text).join())
                .join('\n') ==
            content) {
          tokens = renderer.lines;
        }
      }
    } catch (_) {
      /* A grammar failure still leaves readable plain text. */
    }
  }
  return TextDocument(
    text: content,
    lines: lines,
    encoding: encoding,
    language: language,
    truncated: truncated,
    tokens: tokens,
  );
}

String _prefix(String value, int count) {
  if (count > 0 &&
      value.codeUnitAt(count - 1) >= 0xd800 &&
      value.codeUnitAt(count - 1) <= 0xdbff) {
    count--;
  }
  return value.substring(0, count);
}

String _decodeBounded(
  Uint8List bytes,
  String Function(List<int>) decode,
  bool partial,
  int tail,
) {
  for (var remove = 0; ; remove++) {
    try {
      return decode(Uint8List.sublistView(bytes, 0, bytes.length - remove));
    } on FormatException {
      if (!partial || remove >= tail || remove >= bytes.length) rethrow;
    }
  }
}

final _languages = <String, Mode>{
  'javascript': langJavascript,
  'typescript': langTypescript,
  'python': langPython,
  'bash': langBash,
  'powershell': langPowershell,
  'dart': langDart,
  'java': langJava,
  'kotlin': langKotlin,
  'go': langGo,
  'c': langC,
  'cpp': langCpp,
  'csharp': langCsharp,
  'rust': langRust,
  'php': langPhp,
  'ruby': langRuby,
  'lua': langLua,
  'swift': langSwift,
  'json': langJson,
  'yaml': langYaml,
  'xml': langXml,
  'css': langCss,
  'scss': langScss,
  'sql': langSql,
  'ini': langIni,
  'markdown': langMarkdown,
  'dos': langDos,
};

class _TokenRenderer implements HighlightRenderer {
  final lines = <List<TextToken>>[[]];
  final scopes = <String>[];
  var count = 0;
  @override
  void addText(String text) {
    final parts = text.split('\n');
    for (var i = 0; i < parts.length; i++) {
      if (i > 0) lines.add([]);
      if (parts[i].isEmpty) continue;
      if (++count > 30000) throw const FormatException('Too many tokens');
      lines.last.add(
        TextToken(parts[i], scopes.where((s) => s.isNotEmpty).lastOrNull ?? ''),
      );
    }
  }

  @override
  void openNode(DataNode node) => scopes.add(node.scope ?? '');
  @override
  void closeNode(DataNode node) => scopes.removeLast();
}
