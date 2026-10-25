import 'dart:async';
import 'package:flutter/services.dart';
import 'native_engine.dart';

enum DownloadNetwork { mobile, other, unknown }

Future<DownloadNetwork> readDownloadNetwork() async {
  try {
    final value = await nativeChannel
        .invokeMethod<String>('downloadNetwork')
        .timeout(const Duration(seconds: 3));
    return switch (value) {
      'mobile' => DownloadNetwork.mobile,
      'other' => DownloadNetwork.other,
      _ => DownloadNetwork.unknown,
    };
  } on PlatformException {
    return DownloadNetwork.unknown;
  } on MissingPluginException {
    return DownloadNetwork.unknown;
  } on TimeoutException {
    return DownloadNetwork.unknown;
  }
}
