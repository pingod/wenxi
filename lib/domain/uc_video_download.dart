import '../core/json.dart';
import 'models.dart';

/// Describes the downloaded transcode, independently of the original file.
class UcVideoDownload {
  const UcVideoDownload({
    required this.resolution,
    required this.width,
    required this.height,
    required this.size,
  });

  static const labels = {
    'low': '流畅',
    'normal': '标清',
    'high': '高清',
    'super': '超清',
    '2k': '2K',
    '4k': '4K',
  };
  final String resolution;
  final int width, height, size;
  String get label => labels[resolution]!;
  String get dimensions => '$width×$height';
  bool sameAs(UcVideoDownload other) =>
      resolution == other.resolution &&
      width == other.width &&
      height == other.height &&
      size == other.size;

  String fileName(String original) {
    final dot = original.lastIndexOf('.');
    final stem = dot > 0 ? original.substring(0, dot) : original;
    return '$stem（$label $dimensions）.mp4';
  }

  Json toJson() => {
    'resolution': resolution,
    'width': width,
    'height': height,
    'size': size,
  };

  factory UcVideoDownload.fromJson(Json json) {
    final resolution = json.str('resolution'),
        width = json.integer('width'),
        height = json.integer('height'),
        size = json.integer('size');
    require(
      labels.containsKey(resolution) &&
          width > 0 &&
          width <= 32768 &&
          height > 0 &&
          height <= 32768 &&
          size > 0,
      'UC 可播放版本的画质或大小信息不完整，请重新打开文件列表',
    );
    return UcVideoDownload(
      resolution: resolution,
      width: width,
      height: height,
      size: size,
    );
  }

  static UcVideoDownload? fromSpec(DownloadSpec spec) =>
      spec.source?.containsKey('ucVideo') == true
      ? UcVideoDownload.fromJson(asJson(spec.source!['ucVideo']))
      : null;
}
