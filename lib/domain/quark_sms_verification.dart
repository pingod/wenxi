import 'dart:convert';
import '../data/providers/quark_login.dart';

/// The official page owns its captcha SDK. This adapter only collects the
/// verification proof; SMS sending and code submission stay in the native form.
class QuarkSmsVerification {
  static bool trustedPage(String? value) {
    final uri = Uri.tryParse(value ?? '');
    return uri != null &&
        uri.scheme == 'https' &&
        uri.port == 443 &&
        uri.userInfo.isEmpty &&
        uri.host == 'uop.quark.cn' &&
        uri.path == '/cas/custom/login' &&
        uri.queryParametersAll['custom_login_type']?.length == 1 &&
        uri.queryParametersAll['client_id']?.length == 1 &&
        uri.queryParameters['custom_login_type'] == 'mobile' &&
        uri.queryParameters['client_id'] == QuarkLoginService.clientId;
  }

  static String captureScript({required bool useSlider}) =>
      '''(() => {
    if (window !== window.top || location.origin !== 'https://uop.quark.cn' ||
        location.pathname !== '/cas/custom/login') return '';
    const query = new URLSearchParams(location.search);
    if (query.getAll('client_id').length !== 1 || query.getAll('custom_login_type').length !== 1 ||
        query.get('client_id') !== '532' || query.get('custom_login_type') !== 'mobile') return '';
    if (!document.body) return '';
    if (!window.__asterQuarkCaptcha) {
      window.__asterQuarkCaptcha = {instance: null, slider: false};
      const style = document.createElement('style');
      style.textContent = 'html,body{min-width:0!important;background:transparent!important}' +
        '.u_form{width:100%!important;max-width:480px!important;margin:24px auto!important;padding:16px!important;box-sizing:border-box}' +
        '.input-container>.line,#button,.u_other,#embedCont{display:none!important}' +
        '#nocaptcha{width:100%!important;min-height:48px}';
      document.head.appendChild(style);
      window.sendSmsCode = function() {};
      window.submitForm = function() {};
    }
    const sdk = window.AliyunCaptchaV2;
    const state = window.__asterQuarkCaptcha;
    if (!sdk) return '';
    if ($useSlider && sdk.captchaInstance && !state.slider) {
      state.slider = true;
      sdk.triggerFail({code: 'SERVER_VERIFY_FAILED'});
      return '';
    }
    if (sdk.captchaVerifyParam) {
      const fields = {};
      for (const name of ${jsonEncode(QuarkCaptchaProof.fieldNames.toList())}) {
        const input = document.querySelector('input[name="' + name + '"]');
        if (input) fields[name] = input.value;
      }
      fields.captcha_data = sdk.captchaVerifyParam;
      return JSON.stringify(fields);
    }
    if (!state.slider && sdk.captchaInstance && state.instance !== sdk.captchaInstance) {
      state.instance = sdk.captchaInstance;
      if (typeof sdk.captchaInstance.startTracelessVerification === 'function') {
        sdk.captchaInstance.startTracelessVerification();
      }
    }
    return '';
  })();''';
}
