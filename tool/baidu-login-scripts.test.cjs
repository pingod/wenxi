'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const scripts = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));

function fixture(url = 'https://pan.baidu.com/', framed = false) {
  const nodes = new Map(), requests = [], channels = [], qrRequests = [], listeners = {};
  let sends = 0, submits = 0, refreshes = 0, accepted = 0, opened = 0;
  class Input {
    constructor() { this._value = ''; this.checked = false; this.disabled = false; this.visible = true; }
    set value(value) { this._value = value; }
    get value() { return this._value; }
    dispatchEvent() {}
    getClientRects() { return this.visible ? [{}] : []; }
    click() { this.checked = !this.checked; }
  }
  for (const name of ['smsPhone', 'smsVerifyCode', 'smsIsAgree', 'smsTimer', 'smsSubmit']) nodes.set(name, new Input());
  nodes.get('smsPhone').id = 'TANGRAM__PSP_37__smsPhone';
  const image = {src: ''};
  nodes.set('qrcodeContent', {querySelector: () => image});
  for (const name of ['QrcodeSuccess', 'QrcodeRefresh', 'QrcodeError', 'QrcodeRisk']) {
    const node = new Input(); node.visible = false; nodes.set(name, node);
  }
  const sdk = {
    data: {jsonp(url, data) {
      const callbacks = [];
      const request = {url, data, success(callback) { callbacks.push(callback); return this; }, resolve(value) { for (const callback of callbacks) callback(value); }};
      requests.push(request); return request;
    }},
    tangramInst: {lang: {instance: id => id === 'TANGRAM__PSP_37' ? instance : null}, ajax(options) {
      if (new URL(options.url).pathname === '/v2/api/getqrcode') qrRequests.push(options);
      else channels.push(options);
    }},
    'TANGRAM__PSP_37__spareWData': {channelimg: 'cached-image'},
  };
  sdk.tangramInst.ajax.setup = () => 'official-helper';
  sdk.data.jsonp.helper = 'official-helper';
  const instance = {
    bdPsWtoken: 'private-device-token', config: {channelType: 'qrcode'},
    getElement: name => nodes.get(name), $getId: name => `TANGRAM__PSP_37__${name}`,
    on(name, callback) { (listeners[name] ??= []).push(callback); },
    _stopChannel() {},
    _createChannel() { sdk.tangramInst.ajax({url: 'https://passport.baidu.com/channel/unicast', success() { accepted++; }}); },
    _changeLoginType(type) {
      for (const callback of listeners.changeLoginType || []) callback({loginType: type});
      this.currentLoginType = type;
      if (type === 'qrcode' && !sdk[this.$getId('spareWData')].channelimg) this.refreshQrcode();
    },
    refreshQrcode() {
      refreshes++; this.config.channelType = 'qrcode'; image.src = '';
      sdk.tangramInst.ajax({url: 'https://passport.baidu.com/v2/api/getqrcode', success() {
        sdk[instance.$getId('spareWData')].sign = 'private-qr-sign';
        image.src = 'https://passport.baidu.com/v2/api/qrcode?fixture=qr';
        sdk.tangramInst.ajax({url: 'https://passport.baidu.com/channel/unicast', success() { accepted++; }});
      }});
    },
  };
  nodes.get('smsTimer').click = () => { sends++; sdk.data.jsonp('https://passport.baidu.com/v2/api/senddpass', {}).success(() => {}); };
  nodes.get('smsSubmit').click = () => { submits++; };
  const headNodes = new Map();
  const document = {
    head: {appendChild(node) { headNodes.set(node.id || node.name, node); }},
    getElementById: id => headNodes.get(id),
    createElement: () => ({}),
    querySelector(selector) {
      if (selector === '[id$="__smsPhone"]') return nodes.get('smsPhone');
      if (selector === 'meta[name="viewport"]') return headNodes.get('viewport');
      return null;
    },
    querySelectorAll: () => [{textContent: '去登录', click() { opened++; }}],
  };
  const window = {passport: sdk}; window.top = framed ? {} : window;
  const context = vm.createContext({window, document, location: new URL(url), URL, HTMLInputElement: Input, Event: class {},
    getComputedStyle: () => ({visibility: 'visible'}), Date});
  return {context, instance, sdk, requests, channels, qrRequests, nodes, image, listeners,
    run: source => vm.runInContext(source, context),
    command: (action, data) => window.__asterlinkBaiduLogin.command(action, data),
    read: () => JSON.parse(vm.runInContext(scripts.read, context)),
    counts: () => ({sends, submits, refreshes, accepted, opened}),
  };
}

for (const url of ['http://pan.baidu.com/', 'https://pan.baidu.com.evil.example/', 'https://pan.baidu.com:444/', 'https://user@pan.baidu.com/', 'https://pan.baidu.com/disk/main']) {
  const f = fixture(url); assert.equal(f.run(scripts.bootstrap), 'blocked'); assert.equal(f.counts().sends, 0);
}
assert.equal(fixture(undefined, true).run(scripts.bootstrap), 'blocked');
{
  const f = fixture(); f.run(scripts.bootstrap); f.run(scripts.bootstrap);
  assert.equal(f.read().ready, true);
  assert.equal(f.sdk.tangramInst.ajax.setup(), 'official-helper');
  assert.equal(f.sdk.data.jsonp.helper, 'official-helper');
  assert.equal(f.run(scripts.wrongSession), 'waiting');
  assert.equal(f.command('send', {id: 'no-consent', mobile: '13800138000'}), 'invalid');
  assert.equal(f.command('submit', {id: 'short-code', mobile: '13800138000', agreed: true, code: '1234'}), 'invalid');
  assert.equal(f.run(scripts.send), 'started');
  assert.equal(f.run(scripts.send), 'busy');
  assert.equal(f.nodes.get('smsPhone').value, '13800138000');
  assert.equal(f.nodes.get('smsIsAgree').checked, true);
  assert.equal(f.counts().sends, 1);
  assert.equal(f.read().phase, 'sending'); assert.equal(f.read().sentAt, 0);
  f.requests.at(-1).resolve({data: {errno: 18, isslide: '1', private: 'private-captcha'}});
  assert.equal(f.read().phase, 'verify'); assert.equal(f.read().sentAt, 0);
  assert.equal(f.run(scripts.send), 'used');
  // The user completes the official captcha; its own continuation sends again.
  const verified = f.sdk.data.jsonp('/v2/api/senddpass'); verified.success(() => {});
  verified.resolve({data: {errno: 0}});
  assert.equal(f.read().phase, 'sent'); assert.ok(f.read().sentAt > 0);
  assert.equal(f.command('send', {id: 'resend', mobile: '13800138000', agreed: true}), 'cooldown');
  assert.equal(f.command('submit', {id: 'submit', mobile: '13800138000', agreed: true, code: '012345'}), 'started');
  assert.equal(f.counts().submits, 1);
  assert.equal(f.nodes.get('smsVerifyCode').value, '012345');
  const serialized = JSON.stringify(f.read());
  for (const secret of ['13800138000', '012345', 'private-device-token', 'private-captcha']) assert.ok(!serialized.includes(secret));
  f.command('close');
  assert.equal(f.nodes.get('smsPhone').value, ''); assert.equal(f.nodes.get('smsVerifyCode').value, '');
  assert.equal(f.run(scripts.send), 'closed');
}
{
  const f = fixture(); f.run(scripts.bootstrap); f.run(scripts.send);
  f.command('pause'); f.requests.at(-1).resolve({data: {errno: 0}}); f.command('resume');
  assert.equal(f.read().phase, 'sent'); assert.equal(f.counts().sends, 1);
}
{
  const f = fixture(); f.run(scripts.bootstrap);
  assert.equal(f.command('mode', {mode: 'qrcode'}), 'ready');
  assert.equal(f.counts().refreshes, 1); f.qrRequests.at(-1).success({});
  assert.equal(f.read().qrState, 'waiting'); assert.ok(f.read().qrUrl.startsWith('https://passport.baidu.com/'));
  const staleChannel = f.channels.at(-1); f.command('pause'); staleChannel.success({channel_v: 'private-ticket'});
  assert.equal(f.counts().accepted, 0);
  f.command('resume'); assert.equal(f.counts().refreshes, 1);
  assert.equal(f.counts().accepted, 1); assert.equal(f.channels.length, 1);
  f.command('resume');
  const inFlight = f.channels.at(-1); const polls = f.channels.length;
  f.command('pause'); f.command('resume'); assert.equal(f.channels.length, polls);
  inFlight.success({}); assert.equal(f.counts().accepted, 2);
  f.nodes.get('QrcodeSuccess').visible = true; assert.equal(f.read().qrState, 'scanned');
  f.nodes.get('QrcodeSuccess').visible = false;
  f.nodes.get('QrcodeRefresh').visible = true; assert.equal(f.read().qrState, 'expired');
  f.image.src = 'https://evil.example/track'; assert.equal(f.read().qrUrl, '');
  f.command('refresh'); const staleImage = f.qrRequests.at(-1);
  f.command('mode', {mode: 'sms'}); staleImage.success({});
  assert.equal(f.image.src, '');
  // Navigation between the native precheck and script execution is rejected.
  f.context.location = new URL('https://untrusted.example/');
  assert.equal(f.run(scripts.send), 'blocked'); assert.equal(f.counts().sends, 0);
}
console.log('Baidu official SDK adapter: origin/frame guards, consent, one-shot SMS, captcha continuation, six-digit code, QR refresh, pause, cancellation and secret isolation passed.');
