import '../../core/json.dart';
import '../../domain/auth.dart';
import '../../domain/models.dart';
import '../http.dart';
import '../login_cookies.dart';
import 'quark.dart';

typedef QuarkCaptchaPrompt =
    Future<QuarkCaptchaProof?> Function({required bool useSlider});

/// Ephemeral fields from Quark's official SMS security verification page.
class QuarkCaptchaProof {
  QuarkCaptchaProof(
    Map<String, String> fields, [
    List<String> cookies = const [],
  ]) : fields = Map.unmodifiable(fields),
       cookies = List.unmodifiable(cookies);

  final Map<String, String> fields;
  final List<String> cookies;

  static const fieldNames = {
    'redirect_uri',
    'change_uid',
    'transmission_mode',
    'nc_scene',
    'nc_appkey',
    'nvc_appkey',
    'nvc_data',
    'captcha_data',
    'scene_v2',
    'sig',
    'session_id',
    'token',
    'key',
    'origin',
  };

  bool get valid =>
      fields['captcha_data']?.isNotEmpty == true &&
      fields['scene_v2']?.isNotEmpty == true &&
      fields.entries.every(
        (e) =>
            fieldNames.contains(e.key) &&
            e.value.length <= 32768 &&
            !RegExp(r'[\x00-\x1f\x7f]').hasMatch(e.value),
      );
}

class QuarkSmsChallenge {
  QuarkSmsChallenge._(this.mobile, this.expiresAt, this._attempt, this._proof);
  final String mobile;
  final int expiresAt;
  final _QuarkLoginAttempt _attempt;
  final QuarkCaptchaProof _proof;

  void close() => _attempt.close();
}

/// Where a scanned-login QR currently stands. Quark reports this itself through
/// the `status` field, so the client never has to guess from a local clock.
enum QuarkQrStage { waitingScan, scannedWaitConfirm, expired, ticket }

/// One answer of `getServiceTicketByQrcodeToken`.
class QuarkQrPoll {
  const QuarkQrPoll(this.stage, {this.status = 0, this.ticket = ''});
  final QuarkQrStage stage;
  final int status;
  final String ticket;
}

class QuarkQrChallenge {
  QuarkQrChallenge._(this.token, this.deadline, this._attempt);
  final String token;

  /// Backstop for the polling loop only. Expiration itself is decided by the
  /// server ([QuarkLoginService.qrTokenNotFound] / [QuarkLoginService.qrTokenExpired]),
  /// so a slow scan is never cut short by a local countdown.
  final int deadline;
  final _QuarkLoginAttempt _attempt;

  /// Built by plain concatenation, exactly like the official PC client renders
  /// it: `uc_biz_str` carries raw `|` and `@` characters that a URI encoder
  /// would escape, and the scan app rejects the encoded form.
  String get url =>
      'https://su.quark.cn/4_eMHBJ'
      '?token=${Uri.encodeComponent(token)}'
      '&client_id=${QuarkLoginService.clientId}'
      '&ssb=weblogin&uc_param_str='
      '&uc_biz_str=S:custom|OPT:SAREA@0|OPT:IMMERSIVE@1|OPT:BACK_BTN_STYLE@0';

  void close() => _attempt.close();
}

/// Raised when a QR can no longer lead to a login and a fresh code is needed.
class QuarkQrExpired extends AppException {
  const QuarkQrExpired() : super('二维码已过期，请重新获取');
}

/// Uses the same SMS, QR and service-ticket exchange as pan.quark.cn.
/// Every challenge owns a fresh cookie jar, separate from saved accounts.
class QuarkLoginService {
  QuarkLoginService(this.http, {int Function()? now})
    : now = now ?? (() => DateTime.now().millisecondsSinceEpoch);
  final JsonHttp http;
  final int Function() now;

  static const clientId = '532';
  static const accountOrigin = 'https://uop.quark.cn';

  /// `status` values of `getServiceTicketByQrcodeToken`.
  ///
  /// Quark reports the scan state here instead of relying on the ticket being
  /// empty, so these three codes are the whole truth about expiry:
  /// `50004001` still waiting for a scan, `50004002` token unknown (already
  /// consumed or never issued), `50004003` token expired.
  static const qrWaitingScan = 50004001;
  static const qrTokenNotFound = 50004002;
  static const qrTokenExpired = 50004003;

  /// Only a backstop for the polling loop: the server decides when a QR dies
  /// ([qrTokenNotFound] / [qrTokenExpired]), and 300 s matches the official PC
  /// client's scan window. Nothing expires locally before that.
  static const qrPollWindowSeconds = 300;
  static const mobilePage =
      '$accountOrigin/cas/custom/login?custom_login_type=mobile&client_id=$clientId&display=pc';
  static const serviceAgreement =
      'https://terms.alicdn.com/legal-agreement/terms/c_platform_service_agreement/20260130142844546/20260130142844546.html';
  static const privacyPolicy =
      'https://terms.alicdn.com/legal-agreement/terms/privacy_policy_full/20251218102539837/20251218102539837.html';

  static bool validMobile(String value) =>
      RegExp(r'^1[0-9]{10}$').hasMatch(value.trim());
  static bool validCode(String value) =>
      RegExp(r'^[0-9]{4}$').hasMatch(value.trim());
  static bool _validTicket(String value) =>
      value.isNotEmpty &&
      value.length <= 8192 &&
      !RegExp(r'[\s\x00-\x1f\x7f]').hasMatch(value);

  Future<QuarkSmsChallenge> sendSms(
    String mobile, {
    required QuarkCaptchaPrompt verifyCaptcha,
    void Function(String)? onStatus,
  }) async {
    mobile = mobile.trim();
    require(validMobile(mobile), '请输入正确的手机号');
    final attempt = _QuarkLoginAttempt(http, now);
    try {
      for (var step = 0; step < 2; step++) {
        onStatus?.call('请完成夸克安全验证');
        final proof = await RequestScope.cancellable(
          verifyCaptcha(useSlider: step > 0),
        );
        require(proof != null, '已取消安全验证');
        require(proof!.valid, '夸克安全验证未完成，请重试或切换网页登录');
        attempt.cookies.absorb(
          Uri.parse(mobilePage),
          HttpResult(200, '', {'set-cookie': proof.cookies}),
        );
        onStatus?.call('正在发送验证码…');
        final data = await attempt.form('sendSmsCode', {
          'display': 'pc',
          'client_id': clientId,
          'login_name': mobile,
          'captcha_id': '',
          'captcha_val': '',
          'sig': proof.fields['sig'] ?? '',
          'session_id': proof.fields['session_id'] ?? '',
          'token': proof.fields['token'] ?? '',
          'key': proof.fields['key'] ?? '',
          'cwk_data': '',
          'nvc_data': proof.fields['nvc_data'] ?? '',
          'scene': proof.fields['nc_scene'] ?? 'nvc_login',
          'captcha_data': proof.fields['captcha_data']!,
          'scene_v2': proof.fields['scene_v2']!,
        });
        // The official page falls back to a slider only after an explicit
        // captcha rejection; network errors must never replay an SMS send.
        if (data.integer('status') == 20180001 && step == 0) continue;
        require(
          data.integer('status') == 2000000,
          '夸克短信发送失败或请求过于频繁，请稍后重试或切换网页登录',
        );
        return QuarkSmsChallenge._(mobile, now() + 600000, attempt, proof);
      }
      throw const AppException('夸克安全验证未通过，请重试或切换网页登录');
    } catch (_) {
      attempt.close();
      rethrow;
    }
  }

  Future<Credential> sms(QuarkSmsChallenge challenge, String code) async {
    require(now() < challenge.expiresAt, '短信验证码已过期，请重新获取');
    require(validCode(code), '请输入4位短信验证码');
    final data = await challenge._attempt.form('commit', {
      ...challenge._proof.fields,
      'client_id': clientId,
      'display': 'pc',
      'transmission_mode': 'pm',
      'login_name': challenge.mobile,
      'sms_code': code.trim(),
    });
    require(
      data.integer('status') == 20000,
      '短信验证码错误、已过期或登录受限，请重新获取验证码或切换网页登录',
    );
    final ticket = data.str('data');
    require(_validTicket(ticket), '夸克未返回有效登录票据，请重新登录');
    return challenge._attempt.exchange(ticket, mobile: challenge.mobile);
  }

  Future<QuarkQrChallenge> createQr() async {
    final attempt = _QuarkLoginAttempt(http, now);
    try {
      final data = await attempt.qr('getTokenForQrcodeLogin');
      final token = data.obj('data').obj('members').str('token');
      require(
        data.integer('status') == 2000000 && _validTicket(token),
        '夸克登录二维码获取失败，请重试或切换网页登录',
      );
      return QuarkQrChallenge._(
        token,
        now() + qrPollWindowSeconds * 1000,
        attempt,
      );
    } catch (_) {
      attempt.close();
      rethrow;
    }
  }

  /// One polling round. The answer is classified the same way the official PC
  /// client does it: by `status`, never by a local clock.
  ///
  /// Quark keeps answering [qrWaitingScan] while nobody has scanned, switches to
  /// an unrecognised status (with a non-empty `data` but no ticket) once the
  /// phone has scanned, and only then returns the `service_ticket`. Treating
  /// every non-ticket answer as a failure — or expiring the QR locally —
  /// is what made a successful scan look like "已过期".
  Future<QuarkQrPoll> pollQr(QuarkQrChallenge challenge) async {
    final data = await challenge._attempt.qr('getServiceTicketByQrcodeToken', {
      'token': challenge.token,
    });
    final status = data.integer('status');
    final ticket = data.obj('data').obj('members').str('service_ticket');
    if (_validTicket(ticket)) {
      return QuarkQrPoll(QuarkQrStage.ticket, status: status, ticket: ticket);
    }
    if (status == qrTokenNotFound || status == qrTokenExpired) {
      return QuarkQrPoll(QuarkQrStage.expired, status: status);
    }
    if (status == qrWaitingScan) {
      return QuarkQrPoll(QuarkQrStage.waitingScan, status: status);
    }
    //任何其它状态都只可能是「手机已扫、尚未确认」这类中间态；即使以后多出新
    // 状态码，也只当作进度展示，绝不自行判定过期。
    return QuarkQrPoll(QuarkQrStage.scannedWaitConfirm, status: status);
  }

  bool qrTimedOut(QuarkQrChallenge challenge) => now() >= challenge.deadline;

  Future<Credential> finishQr(QuarkQrChallenge challenge, String ticket) {
    require(_validTicket(ticket), '夸克登录票据无效，请重新扫码');
    return challenge._attempt.exchange(ticket);
  }
}

class _QuarkLoginAttempt {
  _QuarkLoginAttempt(this.http, this.now)
    : cookies = LoginCookieJar({
        'quark.cn',
        'uop.quark.cn',
        'pan.quark.cn',
        'drive-pc.quark.cn',
      }, clock: () => DateTime.fromMillisecondsSinceEpoch(now()));
  final JsonHttp http;
  final int Function() now;
  final LoginCookieJar cookies;
  bool _closed = false;

  void close() {
    _closed = true;
    cookies.clear();
  }

  Future<HttpResult> request(Uri uri, {Map<String, String>? form}) async {
    RequestScope.checkpoint();
    require(!_closed, '登录已取消，请重新登录');
    final response = await http.mutationRequest(
      form == null ? 'GET' : 'POST',
      uri.toString(),
      body: form == null ? null : Uri(queryParameters: form).query,
      contentType: form == null
          ? null
          : 'application/x-www-form-urlencoded; charset=utf-8',
      headers: {
        'User-Agent': uri.host == 'drive-pc.quark.cn'
            ? QuarkConnector.cloudUa
            : QuarkConnector.webUa,
        'Origin': uri.host == 'uop.quark.cn' && form != null
            ? QuarkLoginService.accountOrigin
            : 'https://pan.quark.cn',
        'Referer': uri.host == 'uop.quark.cn' && form != null
            ? QuarkLoginService.mobilePage
            : 'https://pan.quark.cn/',
        'Accept': 'application/json, text/plain, */*',
        if (cookies.header(uri).isNotEmpty) 'Cookie': cookies.header(uri),
      },
      followRedirects: false,
    );
    RequestScope.checkpoint();
    require(!_closed, '登录已取消，请重新登录');
    require(response.status != 429, '夸克登录请求过于频繁，请稍后重试');
    require(response.successful, '夸克登录服务暂时不可用，请重试或切换网页登录');
    cookies.absorb(uri, response);
    return response;
  }

  Future<Json> form(
    String action,
    Map<String, String> fields,
  ) async => (await request(
    Uri.parse(
      '${QuarkLoginService.accountOrigin}/cas/custom/login/$action?custom_login_type=mobile',
    ),
    form: fields,
  )).json;

  Future<Json> qr(
    String action, [
    Map<String, String> extra = const {},
  ]) async => (await request(
    Uri.parse('${QuarkLoginService.accountOrigin}/cas/ajax/$action').replace(
      queryParameters: {
        'client_id': QuarkLoginService.clientId,
        'v': '1.2',
        // The official client sends a fresh request id per call; reusing one
        // makes the second and later polls look like a duplicate request.
        'request_id': newId().replaceAll('-', ''),
        ...extra,
      },
    ),
  )).json;

  Future<Credential> exchange(String ticket, {String? mobile}) async {
    final info = (await request(
      Uri.https('pan.quark.cn', '/account/info', {'st': ticket}),
    )).json;
    require(info.boolean('success'), '夸克登录票据已失效，请重新登录');
    final configUri = Uri.parse(
      'https://drive-pc.quark.cn/1/clouddrive/config?pr=ucpro&fr=pc',
    );
    final config = (await request(configUri)).json;
    require(
      config.integer('status') == 200 && config.integer('code') == 0,
      '夸克网盘登录状态获取失败，请重新登录',
    );
    final cookie = LoginCredentials.mergeCookies([
      cookies.header(Uri.parse('https://pan.quark.cn/')),
      cookies.header(configUri),
    ]);
    require(
      LoginCredentials.plausible(CloudPlatform.quark, cookie),
      '夸克未返回完整网盘登录信息，请重试或切换网页登录',
    );
    final user = info.obj('data');
    return Credential(CloudPlatform.quark.label, {
      'primary': cookie,
      'authType': mobile == null ? 'qrCookie' : 'smsCookie',
      'username': ?mobile,
      if (user.str('uid').isNotEmpty) 'userId': user.str('uid'),
      if (user.str('nickname').isNotEmpty) 'nickname': user.str('nickname'),
      'quarkSessionRefreshedAt': '${now()}',
    });
  }
}
