import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'support.dart';
import 'uc_tv_support.dart';

Json ucPlayableItem({
  String resolution = 'low',
  Object accessible = true,
  int size = 120,
  int width = 270,
  int height = 480,
  String url = 'https://video-play.drive.uc.cn/video.mp4?sign=synthetic',
}) => {
  'resolution': resolution,
  'accessable': accessible,
  'trans_status': 'success',
  'supports_format': 'mp4',
  'video_info': {
    'size': size,
    'width': width,
    'height': height,
    'hls_type': 'none',
    'url': url,
  },
};

HttpResult ucPlayableResponse({
  List<Json>? items,
  int size = 400,
  String? fid,
}) => jsonResponse({
  'status': 200,
  'code': 0,
  'data': {
    'fid': ?fid,
    'size': size,
    'default_resolution': 'low',
    'video_list':
        items ??
        [
          ucPlayableItem(resolution: 'normal', accessible: false, size: 400),
          ucPlayableItem(),
        ],
  },
});

HttpResult ucPlayableRange([int size = 120]) => HttpResult(206, 'x', {
  'content-range': ['bytes 0-0/$size'],
  'content-length': ['1'],
});

UcTvFixture ucPlayableFixture() {
  final f = UcTvFixture(credential: ucTvCredential(authorized: false));
  f.respond = (r) {
    if (r.uri.path == '/1/clouddrive/file/v2/play') return ucPlayableResponse();
    if (r.uri.host == 'video-play.drive.uc.cn') return ucPlayableRange();
    return null;
  };
  return f;
}
