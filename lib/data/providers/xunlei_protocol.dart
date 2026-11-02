import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../../core/json.dart';
import '../../domain/models.dart';
import '../../domain/xunlei_web_login.dart';
import '../state_store.dart';

class XunleiProtocol {
  static const authBase = 'https://xluser-ssl.xunlei.com';
  static const clientId = 'Xp6vsxz_7IYVw2BB';
  static const clientSecret = 'Xp6vsy4tN9toTVdMSpomVdXpRmES';
  static const version = '8.31.0.9726';
  static const packageName = 'com.xunlei.downloadprovider';
  static const webVersion = '1.93.9';
  static const webPackageName = 'pan.xunlei.com';
  static const appUa =
      'ANDROID-com.xunlei.downloadprovider/8.31.0.9726 netWorkType/5G appid/40 deviceName/Xiaomi_M2004j7ac deviceModel/M2004J7AC OSVersion/12 protocolVersion/301 platformVersion/10 sdkVersion/512000 Oauth2Client/0.9 (Linux 4_14_186-perf-gddfs8vbb238b) (JAVA 0)';
  static const _salts = [
    '9uJNVj/wLmdwKrJaVj/omlQ',
    'Oz64Lp0GigmChHMf/6TNfxx7O9PyopcczMsnf',
    'Eb+L7Ce+Ej48u',
    'jKY0',
    'ASr0zCl6v8W4aidjPK5KHd1Lq3t+vBFf41dqv5+fnOd',
    'wQlozdg6r1qxh0eRmt3QgNXOvSZO6q/GXK',
    'gmirk+ciAvIgA/cxUUCema47jr/YToixTT+Q6O',
    '5IiCoM9B1/788ntB',
    'P07JH0h6qoM6TSUAK2aL9T5s2QBVeY9JWvalf',
    '+oK0AN',
  ];
  static String deviceSign(String id) =>
      'div101.$id${md5.convert(utf8.encode(sha1.convert(utf8.encode('$id${packageName}4034a062aaa22f906fca4fefe9fb3a3021')).toString()))}';
  static String captchaSign(String id, String timestamp) {
    var digest = '$clientId$version$packageName$id$timestamp';
    for (final salt in _salts) {
      digest = md5.convert(utf8.encode('$digest$salt')).toString();
    }
    return '1.$digest';
  }

  // The official web client's qrImg signing chain (version 1.93.9).
  // Web tokens must retain their client identity when renewing action captcha.
  static String webCaptchaSign(String id, String timestamp) {
    var digest =
        '${XunleiWebLogin.clientId}$webVersion$webPackageName$id$timestamp';
    for (final salt in const [
      'nSRZ+dnDOmo6D1T2nSKYP2qJ',
      'IYXEGQcnn9EPsfbBGN7mOTeo',
      'KsNB42qr58JR7sZw/ZJpH+cy2',
      'GxVMxHYFNwWCjtPE',
      '+QoEaqp',
      'hsCZLjlslE/6v6uziIzGCnw7mL',
      '1X5EmnTRduq9YHHJrna',
      'vtWp5chbRbIiVvNn+l',
      'Zfk0F',
      'l',
      'Wj+LeMfybKPoZep3m6T3k',
      'lybzZGLYzhgBwM3CDO',
      '7oNGgod8jui69+Z',
      'pGW',
      '+gjRQKugSO3PXtWKa31cYZKI+z',
    ]) {
      digest = md5.convert(utf8.encode('$digest$salt')).toString();
    }
    return '1.$digest';
  }

  static bool trustedPage(String? value) {
    final uri = Uri.tryParse(value ?? '');
    return uri != null &&
        uri.scheme == 'https' &&
        uri.userInfo.isEmpty &&
        uri.port == 443 &&
        (uri.host == 'xunlei.com' || uri.host.endsWith('.xunlei.com'));
  }

  static bool trustedCallback(String? value) {
    final uri = Uri.tryParse(value ?? '');
    return uri != null &&
        uri.scheme == 'xlaccsdk01' &&
        uri.host == 'xunlei.com' &&
        uri.userInfo.isEmpty &&
        !uri.hasPort &&
        uri.path == '/callback';
  }

  static String withDeviceSign(String url, String sign) {
    require(
      trustedPage(url) && sign.startsWith('div101.') && sign.length == 71,
      '无法打开此验证页面',
    );
    final uri = Uri.parse(url);
    return uri
        .replace(queryParameters: {...uri.queryParameters, 'deviceid': sign})
        .toString();
  }

  static Json jwt(String token) {
    try {
      return asJson(
        jsonDecode(
          utf8.decode(base64.decode(base64.normalize(token.split('.')[1]))),
        ),
      );
    } catch (_) {
      return {};
    }
  }
}

class XunleiDevice {
  const XunleiDevice(this.id, this.peer);
  final String id, peer;
  String get sign => XunleiProtocol.deviceSign(id);
}

class XunleiDevices {
  XunleiDevices(this.vault);
  final CredentialStore vault;
  final _gate = AsyncGate();
  Future<XunleiDevice> get() => _gate.run(() async {
    Future<String> identifier(String key) async {
      final old = vault.secret(key);
      if (old != null && RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(old)) return old;
      final id = newId().replaceAll('-', '');
      await vault.putSecret(key, id);
      return id;
    }

    final device = XunleiDevice(
      await identifier('xunlei.device_id'),
      await identifier('xunlei.peer_id'),
    );
    if (vault.secret('xunlei.device_sign') != device.sign) {
      await vault.putSecret('xunlei.device_sign', device.sign);
    }
    return device;
  });
}
