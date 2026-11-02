/// Repairs pasted HTTP links that use an isolated “删” as a deletion marker.
/// Do not decode/re-encode the URL: signed bytes and query ordering must survive.
class LinkObfuscation {
  static const _markerPattern = r'(?:删|%e5%88%a0)';
  static final _marker = RegExp(_markerPattern, caseSensitive: false);
  static final _markerRuns = RegExp('$_markerPattern+', caseSensitive: false);
  static const _tail = r'''[^\s<>"'，。；！、【】《》「」“”‘’\u3000\u200b]+''';
  static final _httpPrefixes = ['https://', 'http://']
      .map(
        (prefix) =>
            prefix.split('').map(RegExp.escape).join('$_markerPattern*'),
      )
      .join('|');
  static final _http = RegExp('(?:$_httpPrefixes)$_tail', caseSensitive: false);
  static final _bare = RegExp(
    '(?<![A-Za-z0-9./_@%删-])(?:[A-Za-z0-9.-]|$_markerPattern)+'
    '(?::(?:[0-9]|$_markerPattern)+)?/$_tail',
    caseSensitive: false,
  );
  static final _han = RegExp(r'[\u3400-\u9fff\uf900-\ufaff]');
  static final _encodedHan = RegExp(
    r'^(?:%[0-9a-f]{2}){3}$',
    caseSensitive: false,
  );
  static final _scheme = RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*://');
  static final _hostLabel = RegExp(
    r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$',
    caseSensitive: false,
  );
  static final _badEscape = RegExp(r'%(?![0-9a-fA-F]{2})');

  static String cleanText(String text) {
    if (!_marker.hasMatch(text)) return text;
    // Use the cleaned view for both link offsets and extraction-code matching.
    // The caller retains the original paste separately for history/replay.
    text = text.replaceAllMapped(_http, (match) => cleanUrl(match[0]!));
    return text.replaceAllMapped(_bare, (match) => cleanUrl(match[0]!));
  }

  static String cleanUrl(String value) {
    if (!_marker.hasMatch(value)) return value;
    var cleaned = value;
    // A second pass covers a raw marker inserted inside an encoded marker.
    // Never decode/re-encode surrounding path escapes or signature parameters.
    for (var pass = 0; pass < 2; pass++) {
      final input = cleaned;
      cleaned = input.replaceAllMapped(_markerRuns, (match) {
        if (_hanBefore(input, match.start) || _hanAfter(input, match.end)) {
          return match[0]!;
        }
        return '';
      });
      if (cleaned == input) break;
    }
    if (cleaned == value || _badEscape.hasMatch(cleaned)) return value;
    final uri = Uri.tryParse(
      _scheme.hasMatch(cleaned) ? cleaned : 'https://$cleaned',
    );
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.userInfo.isNotEmpty ||
        !uri.host.contains('.') ||
        !uri.host.split('.').every(_hostLabel.hasMatch)) {
      return value;
    }
    return cleaned;
  }

  static bool _hanBefore(String text, int offset) =>
      offset > 0 && _han.hasMatch(text.substring(offset - 1, offset)) ||
      offset >= 9 && _isEncodedHan(text.substring(offset - 9, offset));

  static bool _hanAfter(String text, int offset) =>
      offset < text.length &&
          _han.hasMatch(text.substring(offset, offset + 1)) ||
      offset + 9 <= text.length &&
          _isEncodedHan(text.substring(offset, offset + 9));

  static bool _isEncodedHan(String text) {
    if (!_encodedHan.hasMatch(text)) return false;
    try {
      return _han.hasMatch(Uri.decodeComponent(text));
    } on FormatException {
      return false;
    }
  }
}
