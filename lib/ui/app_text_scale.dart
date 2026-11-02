import 'package:flutter/material.dart';

/// Apply the user's preference after the system's potentially nonlinear scale.
class AppTextScaler extends TextScaler {
  const AppTextScaler(this.system, this.factor);

  final TextScaler system;
  final double factor;

  @override
  double scale(double fontSize) => system.scale(fontSize) * factor;

  @override
  double get textScaleFactor => scale(14) / 14;

  @override
  bool operator ==(Object other) =>
      other is AppTextScaler &&
      other.system == system &&
      other.factor == factor;

  @override
  int get hashCode => Object.hash(system, factor);
}

class AppTextScale extends StatelessWidget {
  const AppTextScale({required this.percent, required this.child, super.key});

  final int percent;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return MediaQuery(
      data: percent == 100
          ? media
          : media.copyWith(
              textScaler: AppTextScaler(media.textScaler, percent / 100),
            ),
      child: child,
    );
  }
}
