import 'dart:convert';

/// A small adapter around Baidu's live login SDK. Device signatures, captcha,
/// SMS delivery, QR polling and credential exchange stay in the official page.
abstract final class BaiduWebLogin {
  static const origin = 'https://pan.baidu.com';
  static bool trusted(String? value) {
    final uri = Uri.tryParse(value ?? '');
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host == 'pan.baidu.com' &&
        uri.port == 443 &&
        uri.userInfo.isEmpty &&
        (uri.path.isEmpty || uri.path == '/');
  }

  static bool validMobile(String value) =>
      RegExp(r'^1[3-9]\d{9}$').hasMatch(value.trim());
  static bool validCode(String value) => RegExp(r'^\d{6}$').hasMatch(value);

  static String qrImage(Object? value) {
    if (value is! String || value.length > 4096) return '';
    final uri = Uri.tryParse(value);
    return uri != null &&
            uri.scheme == 'https' &&
            uri.host == 'passport.baidu.com' &&
            uri.port == 443 &&
            uri.userInfo.isEmpty &&
            uri.path == '/v2/api/qrcode'
        ? value
        : '';
  }

  static Map<String, dynamic> decode(Object? value) {
    try {
      if (value is String) value = jsonDecode(value);
      return value is Map ? Map<String, dynamic>.from(value) : {};
    } catch (_) {
      return {};
    }
  }

  static String bootstrap(String session) =>
      _bootstrap.replaceFirst('__SESSION__', jsonEncode(session));

  static String command(
    String session,
    String action, [
    Map<String, Object?> data = const {},
  ]) =>
      '''(() => {
        if (!($_guard)) return 'blocked';
        const bridge = window.__asterlinkBaiduLogin;
        if (!bridge || bridge.session !== ${jsonEncode(session)}) return 'waiting';
        return bridge.command(${jsonEncode(action)}, ${jsonEncode(data)});
      })();''';

  static String read(String session) => command(session, 'read');

  static const _guard =
      r'''window.top === window && location.protocol === 'https:' &&
    location.hostname === 'pan.baidu.com' && (!location.port || location.port === '443') &&
    !new URL(location.href).username && !new URL(location.href).password && (location.pathname === '/' || location.pathname === '')''';

  static const _bootstrap = r'''(() => {
    if (!(window.top === window && location.protocol === 'https:' &&
        location.hostname === 'pan.baidu.com' && (!location.port || location.port === '443') &&
        !new URL(location.href).username && !new URL(location.href).password && (location.pathname === '/' || location.pathname === ''))) return 'blocked';
    const session = __SESSION__;
    if (window.__asterlinkBaiduLogin) {
      return window.__asterlinkBaiduLogin.session === session ? 'ready' : 'blocked';
    }
    let instance, mode = 'sms', phase = '', sentAt = 0, startedAt = 0;
    let generation = 0, smsGeneration = 0, paused = false, closed = false, opened = false, channelPending = false;
    let deferredQr = null;
    const used = new Set();
    const element = name => instance?.getElement(name);
    const shown = node => !!node && node.getClientRects().length > 0 &&
      getComputedStyle(node).visibility !== 'hidden';
    const stop = () => { generation++; channelPending = false; deferredQr = null; instance?._stopChannel?.(); };
    const clear = () => {
      for (const name of ['smsPhone', 'smsVerifyCode']) {
        const input = element(name);
        if (input) input.value = '';
      }
    };
    const fill = (input, value) => {
      const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set;
      if (setter) setter.call(input, value); else input.value = value;
      input.dispatchEvent(new Event('input', {bubbles:true}));
      input.dispatchEvent(new Event('change', {bubbles:true}));
    };
    const layout = () => {
      if (!document.head) return;
      let viewport = document.querySelector('meta[name="viewport"]');
      if (!viewport) {
        viewport = document.createElement('meta'); viewport.name = 'viewport';
        document.head.appendChild(viewport);
      }
      viewport.content = 'width=520,minimum-scale=0.3,maximum-scale=8,user-scalable=yes';
      if (!document.getElementById('aster-baidu-login-layout')) {
        const style = document.createElement('style'); style.id = 'aster-baidu-login-layout';
        style.textContent = '#passport-login-pop{position:fixed!important;left:50%!important;top:24px!important;transform:translateX(-50%);width:400px!important}' +
          '#passport-login-pop>.tang-foreground{width:400px!important}' +
          '#passport-login-pop .pass-login-pop-content{padding-left:0!important;background:none!important}';
        document.head.appendChild(style);
      }
    };
    const attach = () => {
      if (closed || paused) return false;
      layout();
      if (instance) return true;
      const phone = document.querySelector('[id$="__smsPhone"]');
      const sdk = window.passport;
      if (!phone || !sdk?.tangramInst?.lang?.instance) {
        if (!opened) {
          const button = [...document.querySelectorAll('button,a')].find(e => e.textContent.trim() === '去登录');
          if (button) { opened = true; button.click(); }
        }
        return false;
      }
      instance = sdk.tangramInst.lang.instance(phone.id.replace(/__smsPhone$/, ''));
      if (!instance || typeof instance._changeLoginType !== 'function') { instance = null; return false; }
      // Observe only result codes. Never return SDK responses, login tickets,
      // phone numbers or verification codes through the bridge.
      const jsonp = sdk.data.jsonp;
      sdk.data.jsonp = function(url, ...args) {
        const path = new URL(url, 'https://passport.baidu.com').pathname;
        const qr = path === '/v2/api/getqrcode' || path === '/v3/login/main/qrbdusslogin';
        const epoch = generation, smsEpoch = smsGeneration;
        if (path === '/v3/login/main/qrbdusslogin' && !closed) phase = 'completing';
        const request = jsonp.call(this, url, ...args);
        if (qr && request && typeof request.success === 'function') {
          const success = request.success;
          request.success = function(callback) {
            return success.call(this, function(...values) {
              if (!closed && (!paused || path === '/v3/login/main/qrbdusslogin') && epoch === generation && mode === 'qrcode') return callback.apply(this, values);
            });
          };
        }
        if (path === '/v2/api/senddpass' && request && typeof request.success === 'function') {
          request.success(result => {
            if (closed || smsEpoch !== smsGeneration || mode !== 'sms') return;
            if (Number(result?.data?.errno) === 0) { sentAt = Date.now(); phase = 'sent'; }
            else phase = 'verify';
          });
        }
        return request;
      };
      Object.assign(sdk.data.jsonp, jsonp);
      const ajax = sdk.tangramInst.ajax;
      sdk.tangramInst.ajax = function(options, ...args) {
        const path = typeof options?.url === 'string' ? new URL(options.url, 'https://passport.baidu.com').pathname : '';
        if (path === '/v2/api/getqrcode' || (path === '/channel/unicast' && instance.config.channelType === 'qrcode')) {
          if (closed || paused || mode !== 'qrcode') return;
          const epoch = generation, success = options.success, error = options.error;
          const channel = path === '/channel/unicast';
          if (channel) channelPending = true;
          options = {...options, success: function(...values) {
            if (channel && epoch === generation) channelPending = false;
            if (channel && paused && !closed && epoch === generation && mode === 'qrcode') {
              // A confirmation may be delivered only once. Keep it inside the
              // official document until resume rather than discarding it.
              deferredQr = () => {
                if (!closed && !paused && epoch === generation && mode === 'qrcode') return success?.apply(this, values);
              };
              return;
            }
            if (!closed && !paused && epoch === generation && mode === 'qrcode') return success?.apply(this, values);
          }, error: function(...values) {
            if (channel && epoch === generation) channelPending = false;
            if (!closed && !paused && epoch === generation && mode === 'qrcode') return error?.apply(this, values);
          }};
        }
        return ajax.call(this, options, ...args);
      };
      Object.assign(sdk.tangramInst.ajax, ajax);
      instance.on('loginError', () => { if (!closed) phase = 'verify'; });
      instance.on('loginSuccess', () => { if (!closed) phase = 'completing'; });
      instance.on('loginQrcodeCancel', () => { if (!closed) phase = 'cancelled'; });
      instance.on('changeLoginType', event => {
        if (closed || !['sms', 'qrcode', 'normal'].includes(event.loginType) || event.loginType === mode) return;
        stop(); smsGeneration++; phase = ''; mode = event.loginType;
        if (mode === 'qrcode') {
          const spare = sdk[instance.$getId('spareWData')];
          if (spare) spare.channelimg = '';
        }
      });
      stop();
      instance._changeLoginType('sms');
      return true;
    };
    const snapshot = () => {
      const ready = attach() && !!instance.bdPsWtoken;
      if ((phase === 'sending' || phase === 'submitting') && Date.now() - startedAt > 60000) phase = 'verify';
      let qrState = 'loading', qrUrl = '';
      if (mode === 'qrcode' && instance) {
        const img = element('qrcodeContent')?.querySelector('.tang-pass-qrcode-img');
        try {
          const url = new URL(img?.src || '');
          if (url.protocol === 'https:' && url.hostname === 'passport.baidu.com' &&
              (!url.port || url.port === '443') && !url.username && !url.password && url.pathname === '/v2/api/qrcode') qrUrl = url.href;
        } catch (_) {}
        if (shown(element('QrcodeSuccess'))) qrState = 'scanned';
        else if (shown(element('QrcodeRefresh')) || shown(element('QrcodeError')) || shown(element('QrcodeRisk')) || phase === 'cancelled') qrState = 'expired';
        else if (qrUrl) qrState = 'waiting';
      }
      return JSON.stringify({ready, mode, phase, sentAt, qrState, qrUrl});
    };
    window.__asterlinkBaiduLogin = {session, command(action, data = {}) {
      if (action === 'close') { closed = true; smsGeneration++; stop(); clear(); return 'closed'; }
      if (closed) return 'closed';
      // Leave the current QR valid while its user is in the Baidu app. A long
      // poll that finishes in the background is consumed without scheduling
      // another; resume continues that same channel, without duplicate polls.
      if (action === 'pause') { paused = true; return 'paused'; }
      if (action === 'resume') {
        paused = false;
        if (deferredQr) {
          const callback = deferredQr; deferredQr = null; callback();
          return 'ready';
        }
        if (attach() && mode === 'qrcode' && phase !== 'completing' && !channelPending) {
          const spare = window.passport[instance.$getId('spareWData')];
          if (spare?.sign && phase !== 'cancelled') instance._createChannel(spare.sign);
          else { stop(); phase = ''; instance.refreshQrcode(); }
        }
        return 'ready';
      }
      if (action === 'read') return snapshot();
      if (paused || !attach() || !instance.bdPsWtoken) return 'waiting';
      if (phase === 'completing' || phase === 'sending' || phase === 'submitting') return 'busy';
      if (action === 'mode') {
        if (!['sms', 'qrcode'].includes(data.mode)) return 'invalid';
        stop(); smsGeneration++; clear(); phase = ''; mode = data.mode;
        // _actionQrcode can reuse a cached image with a stopped channel.
        // Force a new channel when switching back to QR mode.
        if (mode === 'qrcode') {
          const spare = window.passport[instance.$getId('spareWData')];
          if (spare) spare.channelimg = '';
        }
        instance._changeLoginType(mode);
        return 'ready';
      }
      if (action === 'refresh') {
        if (mode !== 'qrcode') return 'invalid';
        stop(); phase = ''; instance.refreshQrcode(); return 'ready';
      }
      if (action !== 'send' && action !== 'submit') return 'invalid';
      if (typeof data.id !== 'string' || !data.id || used.has(data.id)) return 'used';
      used.add(data.id);
      if (used.size > 64) return 'used';
      if (mode !== 'sms' || !/^1[3-9]\d{9}$/.test(data.mobile || '') || data.agreed !== true) return 'invalid';
      if (action === 'send' && Date.now() - sentAt < 60000) return 'cooldown';
      if (action === 'submit' && !/^\d{6}$/.test(data.code || '')) return 'invalid';
      const phone = element('smsPhone'), code = element('smsVerifyCode');
      const agree = element('smsIsAgree');
      const country = element('smsPhoneCountryLabel')?.getAttribute('data-countrycode') || '';
      const button = element(action === 'send' ? 'smsTimer' : 'smsSubmit');
      if (!phone || !code || !agree || !button || button.disabled || !shown(button)) return 'waiting';
      if (!['', '86', '+86', '0086'].includes(country)) return 'waiting';
      fill(phone, data.mobile);
      fill(code, action === 'submit' ? data.code : '');
      if (!agree.checked) agree.click();
      if (!agree.checked) return 'invalid';
      startedAt = Date.now(); phase = action === 'send' ? 'sending' : 'submitting';
      button.click();
      return 'started';
    }};
    attach();
    return 'ready';
  })();''';
}
