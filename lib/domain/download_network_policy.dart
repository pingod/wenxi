import 'dart:io';
import '../core/json.dart';

class DownloadNetworkPolicyException extends AppException {
  const DownloadNetworkPolicyException() : super('来源下载地址超出声明的网络权限，请更新来源后重试');
}

/// A snapshot of a signed source's download permissions, retained on its task.
class DownloadNetworkPolicy {
  DownloadNetworkPolicy._(this.hosts, this.schemes, this.ports);
  final List<String> hosts, schemes;
  final List<int> ports;

  factory DownloadNetworkPolicy.fromJson(Json json) {
    final hosts = json['hosts'],
        schemes = json['schemes'],
        ports = json['ports'];
    if (hosts is! List ||
        hosts.isEmpty ||
        hosts.length > 32 ||
        hosts.any((h) => h is! String || !validHost(h)) ||
        schemes is! List ||
        schemes.isEmpty ||
        schemes.any((s) => !{'http', 'https'}.contains(s)) ||
        ports is! List ||
        ports.isEmpty ||
        ports.length > 16 ||
        ports.any((p) => p is! int || p < 1 || p > 65535)) {
      throw const DownloadNetworkPolicyException();
    }
    return DownloadNetworkPolicy._(
      List.unmodifiable(hosts.cast<String>()),
      List.unmodifiable(schemes.cast<String>()),
      List.unmodifiable(ports.cast<int>()),
    );
  }

  Json toJson() => {'hosts': hosts, 'schemes': schemes, 'ports': ports};

  static bool validHost(String value) {
    final host = value.startsWith('*.') ? value.substring(2) : value;
    return host.length <= 253 &&
        RegExp(
          r'^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$',
        ).hasMatch(host) &&
        !RegExp(r'\.(local|localhost|internal|invalid|test)$').hasMatch(host);
  }

  static bool hostMatches(String host, String allowed) =>
      allowed.startsWith('*.')
      ? host.endsWith(allowed.substring(1)) && host != allowed.substring(2)
      : host == allowed;

  Uri checkedUrl(String value) {
    final uri = Uri.tryParse(value);
    if (value.length > 16384 ||
        RegExp(r'[\x00-\x20\x7f\\]').hasMatch(value) ||
        uri == null ||
        !schemes.contains(uri.scheme) ||
        uri.userInfo.isNotEmpty ||
        !ports.contains(uri.port) ||
        !hosts.any((h) => hostMatches(uri.host, h))) {
      throw const DownloadNetworkPolicyException();
    }
    return uri.replace(fragment: '');
  }

  static bool publicAddress(InternetAddress address) {
    final b = address.rawAddress;
    if (b.length == 16) {
      return b[0] & 0xe0 == 0x20 &&
          !(b[0] == 0x20 && b[1] == 2) &&
          !(b[0] == 0x20 &&
              b[1] == 1 &&
              (b[2] == 0 ||
                  b[2] == 0x0d && b[3] == 0xb8 ||
                  b[2] == 0x10 ||
                  b[2] == 0x20));
    }
    return b.length == 4 &&
        b[0] != 0 &&
        b[0] != 10 &&
        b[0] != 127 &&
        b[0] < 224 &&
        !(b[0] == 100 && b[1] >= 64 && b[1] <= 127) &&
        !(b[0] == 169 && b[1] == 254) &&
        !(b[0] == 172 && b[1] >= 16 && b[1] <= 31) &&
        !(b[0] == 192 &&
            (b[1] == 168 ||
                b[1] == 0 && (b[2] == 0 || b[2] == 2) ||
                b[1] == 88 && b[2] == 99)) &&
        !(b[0] == 198 &&
            (b[1] == 18 || b[1] == 19 || b[1] == 51 && b[2] == 100)) &&
        !(b[0] == 203 && b[1] == 0 && b[2] == 113);
  }

  HttpClient client() => HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..idleTimeout = const Duration(seconds: 3)
    ..userAgent = null
    ..findProxy = ((_) => 'DIRECT')
    ..connectionFactory = (uri, proxyHost, proxyPort) async {
      checkedUrl(uri.toString());
      final addresses = await InternetAddress.lookup(
        uri.host,
      ).timeout(const Duration(seconds: 10));
      if (proxyHost != null ||
          addresses.isEmpty ||
          addresses.any((a) => !publicAddress(a))) {
        throw const DownloadNetworkPolicyException();
      }
      final address =
          addresses
              .where((a) => a.type == InternetAddressType.IPv4)
              .firstOrNull ??
          addresses.first;
      // Keep the resolved hostname for TLS while connecting to this exact IP.
      return uri.scheme == 'https'
          ? SecureSocket.startConnect(address, uri.port)
          : Socket.startConnect(address, uri.port);
    };

  static Map<String, String> redirectedHeaders(
    Uri from,
    Uri to,
    Map<String, String> headers,
  ) {
    if (from.scheme == 'https' && to.scheme == 'http') {
      throw const DownloadNetworkPolicyException();
    }
    if (from.origin == to.origin) return Map.of(headers);
    return {
      for (final entry in headers.entries)
        if (const {
          'accept',
          'accept-language',
          'accept-encoding',
          'user-agent',
          'range',
          'if-range',
        }.contains(entry.key.toLowerCase()))
          entry.key: entry.value,
    };
  }
}
