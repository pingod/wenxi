import 'models.dart';

class AliyunShareLink {
  const AliyunShareLink(this.id, {required this.fastTransfer});
  final String id;
  final bool fastTransfer;

  static AliyunShareLink? parse(Uri uri) {
    if (!{'http', 'https'}.contains(uri.scheme) ||
        uri.userInfo.isNotEmpty ||
        CloudPlatform.fromHost(uri.host) != CloudPlatform.aliyun) {
      return null;
    }
    final paths = [
      uri.path,
      if ((uri.path.isEmpty || uri.path == '/') && uri.fragment.startsWith('/'))
        Uri.tryParse(uri.fragment)?.path ?? '',
    ];
    for (final path in paths) {
      final match = RegExp(r'^/(s|t)/([A-Za-z0-9]+)(?=/|$)').firstMatch(path);
      if (match != null) {
        return AliyunShareLink(match[2]!, fastTransfer: match[1] == 't');
      }
    }
    return null;
  }

  static bool isFastTransfer(BrowseSession session) =>
      session.platform == CloudPlatform.aliyun &&
      session.mode == BrowseMode.share &&
      session.meta('aliyunShareType') == 'fastTransfer';

  // The anonymous API exposes only a preview, and saveFile always saves the
  // whole transfer. Represent it as one bundle rather than selectable files.
  static String bundleId(String shareId) => 'aliyun-fast-transfer:$shareId';
}
