import 'dart:io';
import 'package:flutter/services.dart';
import '../core/json.dart';
import 'native_engine.dart';

class DownloadProtectionStatus {
  const DownloadProtectionStatus({
    required this.batteryUnrestricted,
    required this.notificationsEnabled,
    required this.backgroundRestricted,
    this.powerSaveMode = false,
    this.serviceRunning = false,
    this.wakeLockHeld = false,
    this.recovering = false,
    this.keepAliveRunning = false,
    this.keepAliveNotificationsEnabled = false,
    this.desktop = false,
    this.foregroundOnly = false,
  });
  final bool batteryUnrestricted, notificationsEnabled, backgroundRestricted;
  final bool powerSaveMode, serviceRunning, wakeLockHeld, recovering;
  final bool keepAliveRunning, keepAliveNotificationsEnabled;
  final bool desktop;
  final bool foregroundOnly;

  factory DownloadProtectionStatus.fromJson(Json value) =>
      DownloadProtectionStatus(
        batteryUnrestricted: value.boolean('batteryUnrestricted'),
        notificationsEnabled: value.boolean('notificationsEnabled'),
        backgroundRestricted: value.boolean('backgroundRestricted'),
        powerSaveMode: value.boolean('powerSaveMode'),
        serviceRunning: value.boolean('serviceRunning'),
        wakeLockHeld: value.boolean('wakeLockHeld'),
        recovering: value.boolean('recovering'),
        keepAliveRunning: value.boolean('keepAliveRunning'),
        keepAliveNotificationsEnabled: value.boolean(
          'keepAliveNotificationsEnabled',
        ),
        desktop: value.boolean('desktop'),
        foregroundOnly: value.boolean('foregroundOnly'),
      );
}

class DownloadProtectionPlatform {
  const DownloadProtectionPlatform({String? operatingSystem})
    : _operatingSystem = operatingSystem;
  final String? _operatingSystem;
  String get operatingSystem => _operatingSystem ?? Platform.operatingSystem;
  Future<DownloadProtectionStatus> status() async {
    if (operatingSystem == 'ios') {
      return const DownloadProtectionStatus(
        batteryUnrestricted: false,
        notificationsEnabled: false,
        backgroundRestricted: true,
        foregroundOnly: true,
      );
    }
    return DownloadProtectionStatus.fromJson(
      asJson(
        await nativeChannel.invokeMethod<Object?>('downloadProtectionStatus'),
      ),
    );
  }

  Future<void> openSettings(String kind) async {
    try {
      await nativeChannel.invokeMethod<void>('downloadProtectionSettings', {
        'kind': kind,
      });
    } on MissingPluginException {
      // Linux has no equivalent system page; say so instead of letting an
      // unhandled platform error escape into the settings UI.
      throw const AppException('当前系统没有对应的后台下载设置页');
    } on PlatformException catch (error) {
      throw AppException(error.message ?? '无法打开系统后台设置');
    }
  }
}
