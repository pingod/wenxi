import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/uc_video_download.dart';
import 'uc_tv_support.dart';
import 'uc_video_download_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Web account downloads an explicitly labelled transcode without TV grant',
    () async {
      final f = ucPlayableFixture();
      const file = CloudFile(
        id: 'video-1',
        name: 'video.mp4',
        size: 400,
        hashType: 'md5',
        hashValue: '0123456789abcdef0123456789abcdef',
      );
      final spec = await f.repository.prepareUcPlayable(ucTvPersonal, file);
      expect(spec.expectedSize, 120);
      expect(spec.fileName, 'video（流畅 270×480）.mp4');
      expect(spec.checksumType, isNull);
      expect(spec.checksumValue, isNull);
      expect(spec.headers['Cookie'], f.credential.primary);
      final quality = UcVideoDownload.fromSpec(spec)!;
      expect(quality.resolution, 'low');
      expect(spec.source!['accountRevision'], 7);
      expect(spec.source!['ucVideo'], quality.toJson());
      expect(DownloadOrigin.fromJson(spec.source!).file.size, 400);
      final request = f.calls('/1/clouddrive/file/v2/play').single;
      expect(request.method, 'POST');
      expect(request.uri.queryParameters, {'pr': 'UCBrowser', 'fr': 'pc'});
      expect(request.json, {
        'fid': file.id,
        'resolutions': 'low,normal,high,super,2k,4k',
        'supports': 'fmp4_av,m3u8',
      });
      expect(request.headers['User-Agent'], contains('Chrome/120.0'));
      expect(f.calls('/file'), isEmpty);
      expect(f.calls('/1/clouddrive/file/download'), isEmpty);
    },
  );

  test(
    'The highest available MP4 is chosen, locked and HLS tracks are excluded',
    () async {
      final f = ucPlayableFixture();
      f.respond = (r) {
        if (r.uri.path.endsWith('/v2/play')) {
          return ucPlayableResponse(
            items: [
              ucPlayableItem(),
              ucPlayableItem(resolution: 'high', accessible: '1'),
              ucPlayableItem(resolution: '4k', accessible: false),
              {...ucPlayableItem(resolution: '2k'), 'supports_format': 'm3u8'},
            ],
          );
        }
        if (r.uri.host == 'video-play.drive.uc.cn') return ucPlayableRange();
        return null;
      };
      final spec = await f.repository.prepareUcPlayable(
        ucTvPersonal,
        ucTvVideo,
      );
      expect(UcVideoDownload.fromSpec(spec)!.resolution, 'high');
    },
  );

  test(
    'Persisted task refresh keeps its chosen quality even when a better track appears',
    () async {
      final f = ucPlayableFixture();
      final spec = await f.repository.prepareUcPlayable(
        ucTvPersonal,
        ucTvVideo,
      );
      final saved = DownloadSpec.fromJson(
        asJson(jsonDecode(jsonEncode(spec.toJson()))),
      );
      f.respond = (r) {
        if (r.uri.path.endsWith('/v2/play')) {
          return ucPlayableResponse(
            items: [
              ucPlayableItem(
                url: 'https://video-play.drive.uc.cn/video.mp4?sign=renewed',
              ),
              ucPlayableItem(resolution: 'super', size: 350),
            ],
          );
        }
        if (r.uri.host == 'video-play.drive.uc.cn') return ucPlayableRange();
        return null;
      };
      final fresh = await f.repository.refresh(saved);
      expect(fresh.expectedSize, 120);
      expect(fresh.fileName, spec.fileName);
      expect(fresh.url, contains('sign=renewed'));
      expect(fresh.source!['ucVideo'], spec.source!['ucVideo']);
      expect(fresh.checksumValue, isNull);
      expect(f.calls('/1/clouddrive/file/download'), isEmpty);
    },
  );

  for (final change in ['missing', 'size', 'dimensions']) {
    test(
      'Refresh rejects $change rather than combining incompatible video bytes',
      () async {
        final f = ucPlayableFixture();
        final spec = await f.repository.prepareUcPlayable(
          ucTvPersonal,
          ucTvVideo,
        );
        f.respond = (r) {
          if (r.uri.path.endsWith('/v2/play')) {
            return ucPlayableResponse(
              items: [
                ucPlayableItem(
                  resolution: change == 'missing' ? 'high' : 'low',
                  size: change == 'size' ? 121 : 120,
                  width: change == 'dimensions' ? 320 : 270,
                ),
              ],
            );
          }
          if (r.uri.host == 'video-play.drive.uc.cn') {
            return ucPlayableRange(change == 'size' ? 121 : 120);
          }
          return null;
        };
        await expectLater(
          f.repository.refresh(spec),
          throwsA(isA<AppException>()),
        );
        expect(f.calls('/1/clouddrive/file/download'), isEmpty);
      },
    );
  }

  test(
    'A shared video uses one temporary transfer and cleans it after release',
    () async {
      final f = ucPlayableFixture();
      final response = f.respond!;
      f.respond = (r) {
        if (r.uri.path.endsWith('/v2/play')) {
          expect(r.json['fid'], 'saved-video');
          return ucPlayableResponse(fid: 'saved-video');
        }
        return response(r);
      };
      final spec = await f.repository.prepareUcPlayable(ucTvShare, ucTvVideo);
      expect(f.calls('/1/clouddrive/share/sharepage/save'), hasLength(1));
      expect(spec.cleanup, isNotNull);
      expect(f.cleanups.pendingCount, 1);
      await f.cleanups.ready(spec.cleanup);
      await f.cleanups.drain();
      expect(f.calls('/1/clouddrive/file/delete'), isEmpty);
      await f.cleanups.release(spec.cleanup);
      await f.cleanups.ready(spec.cleanup);
      await f.cleanups.drain();
      expect(f.calls('/1/clouddrive/file/delete').single.json['filelist'], [
        'temporary',
      ]);
      expect(f.cleanups.pendingCount, 0);
    },
  );

  test(
    'Failed shared media checks release only this attempt temporary directory',
    () async {
      final f = ucPlayableFixture();
      f.respond = (r) {
        if (r.uri.path.endsWith('/v2/play')) {
          return ucPlayableResponse(items: []);
        }
        return null;
      };
      await expectLater(
        f.repository.prepareUcPlayable(ucTvShare, ucTvVideo),
        throwsA(isA<AppException>()),
      );
      await f.cleanups.drain();
      expect(f.calls('/1/clouddrive/file/delete'), isNotEmpty);
      for (final call in f.calls('/1/clouddrive/file/delete')) {
        expect(call.json['filelist'], ['temporary']);
      }
      expect(f.cleanups.pendingCount, 0);
    },
  );

  for (final address in [
    'https://evil.test/video.mp4',
    'https://uc.cn.evil.test/v',
    'http://video.uc.cn/v',
    'https://user:secret@video.uc.cn/v',
    'file:///video.mp4',
  ]) {
    test(
      'Invalid media address is rejected before sending a Cookie: $address',
      () async {
        final f = ucPlayableFixture();
        f.respond = (r) => r.uri.path.endsWith('/v2/play')
            ? ucPlayableResponse(items: [ucPlayableItem(url: address)])
            : null;
        await expectLater(
          f.repository.prepareUcPlayable(ucTvPersonal, ucTvVideo),
          throwsA(isA<AppException>()),
        );
        expect(
          f.http.calls.where(
            (r) => r.method == 'GET' && r.headers.containsKey('Range'),
          ),
          isEmpty,
        );
      },
    );
  }

  for (final variant in [
    'wrong-size',
    'no-width',
    'wrong-fid',
    'hls',
    'malformed-range',
    'encoded',
    'redirect',
  ]) {
    test(
      'Malformed or inconsistent media cannot enter the download queue: $variant',
      () async {
        final f = ucPlayableFixture();
        f.respond = (r) {
          if (r.uri.path.endsWith('/v2/play')) {
            return ucPlayableResponse(
              size: variant == 'wrong-size' ? 999 : 400,
              fid: variant == 'wrong-fid' ? 'another-file' : null,
              items: [
                {
                  ...ucPlayableItem(width: variant == 'no-width' ? 0 : 270),
                  if (variant == 'hls') 'supports_format': 'm3u8',
                },
              ],
            );
          }
          if (r.uri.host == 'video-play.drive.uc.cn') {
            return switch (variant) {
              'malformed-range' => const HttpResult(206, 'x', {
                'content-range': ['bytes 1-1/120'],
              }),
              'encoded' => const HttpResult(206, 'x', {
                'content-range': ['bytes 0-0/120'],
                'content-encoding': ['gzip'],
              }),
              'redirect' => const HttpResult(302, '', {
                'location': ['https://evil.test/video.mp4'],
              }),
              _ => ucPlayableRange(),
            };
          }
          return null;
        };
        await expectLater(
          f.repository.prepareUcPlayable(ucTvPersonal, ucTvVideo),
          throwsA(isA<AppException>()),
        );
        if (variant == 'redirect') {
          expect(f.http.redirectPolicies.last, isFalse);
        }
      },
    );
  }

  test('No account asks for login before transferring anything', () async {
    final f = ucPlayableFixture();
    await expectLater(
      f.connector.downloadPlayable(ucTvShare, ucTvVideo, null),
      throwsA(isA<AccountLoginRequired>()),
    );
    expect(f.http.calls, isEmpty);
  });

  for (final cancel in [true, false]) {
    test(
      'A late response after ${cancel ? 'cancellation' : 'account removal'} returns no media',
      () async {
        final f = ucPlayableFixture(), scope = RequestScope();
        f.respond = (r) {
          if (r.uri.path.endsWith('/v2/play')) {
            return () async {
              if (cancel) {
                scope.cancel();
              } else {
                await f.vault.removeCredential(CloudPlatform.uc);
              }
              return ucPlayableResponse();
            }();
          }
          return null;
        };
        await expectLater(
          scope.run(
            () => f.repository.prepareUcPlayable(ucTvPersonal, ucTvVideo),
          ),
          throwsA(isA<AppException>()),
        );
        expect(
          f.http.calls.where((r) => r.headers.containsKey('Range')),
          isEmpty,
        );
      },
    );
  }

  test(
    'Original web video without a checksum still rejects the membership notice',
    () async {
      final f = ucPlayableFixture();
      f.respond = (r) {
        if (r.uri.host == 'media.example') return ucPlayableRange(15340287);
        return null;
      };
      await expectLater(
        f.repository.prepare(ucTvPersonal, ucTvVideo),
        throwsA(isA<UcTvAuthorizationRequired>()),
      );
      expect(f.calls('/1/clouddrive/file/v2/play'), isEmpty);
    },
  );
}
