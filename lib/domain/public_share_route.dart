import 'baidu_share_route.dart';
import 'models.dart';

/// A share parser is independent of the personal drive's account connector.
abstract final class PublicShareRoute {
  static const platforms = {
    CloudPlatform.baidu,
    CloudPlatform.quark,
    CloudPlatform.uc,
    CloudPlatform.xunlei,
    CloudPlatform.pan123,
    CloudPlatform.c139,
  };
  static const metadataKey = 'publicShareParser';
  static bool uses(BrowseSession session) =>
      BaiduShareRoute.usesPublicParser(session) ||
      session.mode == BrowseMode.share &&
          platforms.contains(session.platform) &&
          session.meta(metadataKey) == 'remote';

  static String profile(CloudPlatform platform) =>
      platform == CloudPlatform.baidu
      ? BaiduShareRoute.publicDownloadProfile
      : '${platform.name}_public';
}
