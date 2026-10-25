const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const scripts = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));

function page() {
  const inputs = {
    scene_v2: {value: '1ml1ondj'},
    nc_scene: {value: 'nvc_login'},
    login_name: {value: '13800000000'},
    sms_code: {value: '1234'},
  };
  let sent = 0, committed = 0, started = 0, sliders = 0;
  const context = vm.createContext({URLSearchParams, location: {
    origin: 'https://uop.quark.cn', pathname: '/cas/custom/login',
    search: '?custom_login_type=mobile&client_id=532&display=pc',
  }, document: {
    body: {}, head: {appendChild() {}}, createElement: () => ({}),
    querySelector: selector => inputs[selector.match(/name="([^"]+)"/)?.[1]] ?? null,
  }, sendSmsCode() { sent++; }, submitForm() { committed++; },
  AliyunCaptchaV2: {
    captchaVerifyParam: null,
    captchaInstance: {startTracelessVerification() { started++; }},
    triggerFail() { sliders++; this.captchaVerifyParam = null; inputs.scene_v2.value = 'y9x7vx0s'; },
  }});
  vm.runInContext('window = globalThis; window.top = window;', context);
  return {context, inputs, run: (script = scripts.capture) => vm.runInContext(script, context),
    counts: () => ({sent, committed, started, sliders})};
}

{
  const p = page();
  assert.equal(p.run(), '');
  p.run(); p.context.sendSmsCode(); p.context.submitForm();
  assert.deepEqual(p.counts(), {sent: 0, committed: 0, started: 1, sliders: 0});
  p.context.AliyunCaptchaV2.captchaVerifyParam = 'official-proof';
  assert.deepEqual(JSON.parse(p.run()), {
    captcha_data: 'official-proof', scene_v2: '1ml1ondj', nc_scene: 'nvc_login',
  });
}
{
  const p = page();
  p.context.AliyunCaptchaV2.captchaVerifyParam = 'rejected-proof';
  assert.equal(p.run(scripts.slider), '');
  p.run(scripts.slider);
  assert.equal(p.counts().sliders, 1);
  p.context.AliyunCaptchaV2.captchaVerifyParam = 'slider-proof';
  assert.equal(JSON.parse(p.run(scripts.slider)).scene_v2, 'y9x7vx0s');
}
for (const change of [
  p => { p.context.window.top = {}; },
  p => { p.context.location.origin = 'http://uop.quark.cn'; },
  p => { p.context.location.origin = 'https://untrusted.example'; },
  p => { p.context.location.pathname = '/other'; },
  p => { p.context.location.search += '&client_id=532'; },
  p => { p.context.location.search = '?custom_login_type=common&client_id=532'; },
]) {
  const p = page(); change(p);
  assert.equal(p.run(), '');
  assert.equal(p.counts().started, 0);
  assert.equal(p.context.__asterQuarkCaptcha, undefined);
}
console.log('Quark captcha: native-only SMS sending, official proof, slider fallback and page guards passed.');
