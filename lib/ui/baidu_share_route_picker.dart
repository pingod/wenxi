import 'package:flutter/material.dart';
import '../domain/baidu_share_route.dart';
import '../domain/models.dart';
import 'common.dart';

class BaiduShareRoutePicker extends StatelessWidget {
  const BaiduShareRoutePicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.platform = CloudPlatform.baidu,
    this.publicAllowed = true,
  });

  final BaiduShareRoute value;
  final ValueChanged<BaiduShareRoute>? onChanged;
  final CloudPlatform platform;
  final bool publicAllowed;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            '解析方式',
            style: TextStyle(fontSize: 12, color: secondary(context)),
          ),
          for (final route in BaiduShareRoute.values)
            if (publicAllowed || route == BaiduShareRoute.account)
              ChoiceChip(
                key: ValueKey('${platform.name}-route-${route.key}'),
                label: Text(
                  platform != CloudPlatform.baidu &&
                          route == BaiduShareRoute.account
                      ? '常规解析'
                      : route.label,
                ),
                selected: value == route,
                onSelected: onChanged == null ? null : (_) => onChanged!(route),
                selectedColor: themeAccent(context).withValues(alpha: .14),
                side: BorderSide(
                  color: value == route
                      ? themeAccent(context).withValues(alpha: .3)
                      : border(context),
                ),
                labelStyle: TextStyle(
                  color: value == route ? themeAccent(context) : null,
                  fontSize: 13,
                  fontWeight: value == route
                      ? FontWeight.w600
                      : FontWeight.w400,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
        ],
      ),
      const SizedBox(height: 2),
      Text(
        !publicAllowed
            ? '公益解析暂未开放，请切换${platform == CloudPlatform.baidu ? '账号下载' : '常规解析'}'
            : platform == CloudPlatform.baidu
            ? value == BaiduShareRoute.publicParser
                  ? '无需登录百度账号，支持多线程下载'
                  : '使用已登录的百度网盘账号下载'
            : value == BaiduShareRoute.publicParser
            ? '通过所选通道解析分享，可能需要解析密码或受额度限制'
            : '使用原有网盘解析和下载方式',
        style: TextStyle(fontSize: 12, height: 1.5, color: secondary(context)),
      ),
    ],
  );
}
