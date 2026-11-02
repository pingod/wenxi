const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const {evaluation, firstPassword, ucEvaluation, ucUnsupportedEvaluation,
  ucResolvedEvaluation, recipe} = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
let assertions = 0;
function check(actual, expected) { assert.deepEqual(actual, expected); assertions++; }
function page() {
  let now = 1000;
  const nodes = Object.fromEntries(['stepTurnstile', 'stepPassword', 'stepResult', 'pwdValue',
    'pwdErrorBox', 'accessPwdInput', 'btnTurnstileNext', 'btnSubmitPwd', 'ucText'].map(id => [id, {
      style: {display: 'none'}, textContent: '', value: '', disabled: false, clicks: 0,
      classList: {contains: () => false}, dispatchEvent() {}, click() { this.clicks++; },
    }]));
  const token = {value: ''};
  const context = vm.createContext({Date: {now: () => now}, Event: class {},
    location: {protocol: 'https:', port: '', hostname: 'mmhq.dg22.top'},
    document: {body: {innerText: ''}, getElementById: id => nodes[id],
      querySelector: selector => selector.includes('cf-turnstile-response') ? token : null}});
  vm.runInContext('window = globalThis; window.top = window;', context);
  const run = (script = evaluation) => JSON.parse(vm.runInContext(script, context, {timeout: 1000}));
  function stage(id) {
    for (const key of ['stepTurnstile', 'stepPassword', 'stepResult']) nodes[key].style.display = key === id ? '' : 'none';
  }
  return {nodes, token, context, run, stage, time: value => { now = value; }};
}
{
  const p = page(); p.stage('stepTurnstile');
  p.run(); p.time(3000); p.run();
  check(p.nodes.btnTurnstileNext.clicks, 0);
  check(p.nodes.accessPwdInput.value, '');
  p.token.value = 'user-completed-token'; p.run(); p.run();
  check(p.nodes.btnTurnstileNext.clicks, 1);
  p.time(10000); p.run(); p.time(20000); p.run();
  check(p.nodes.btnTurnstileNext.clicks, 2);
  p.stage('stepPassword'); p.run();
  check(p.nodes.accessPwdInput.value, firstPassword);
  check(p.nodes.btnSubmitPwd.clicks, 1);
}
{
  const p = page(); p.stage('stepResult'); p.nodes.pwdValue.textContent = '••••••••';
  check(p.run().status, 'waiting');
  vm.runInContext('let currentParsePwd = "解密后的密码-A7!";', p.context);
  check(p.context.currentParsePwd, undefined);
  check(p.run().password, '解密后的密码-A7!');
  p.context.location.hostname = 'untrusted.example';
  check(p.run().status, 'waiting');
  p.context.location.hostname = 'mmhq.dg22.top'; p.context.window.top = {};
  check(p.run().status, 'waiting');
}
{
  const p = page(); p.stage('stepResult'); p.nodes.pwdValue.textContent = 'DOM备用密码';
  check(p.run().password, 'DOM备用密码');
  p.nodes.pwdValue.classList.contains = () => true;
  check(p.run().status, 'waiting');
  p.stage('stepPassword'); p.nodes.pwdErrorBox.style.display = '';
  p.nodes.pwdErrorBox.textContent = '访问密码错误';
  check(p.run().status, 'error');
}
{
  const p = page(); p.stage('stepTurnstile');
  p.nodes.ucText.textContent = '网页当前口令';
  check(p.run(ucEvaluation), {status: 'ucPassword', command: '网页当前口令'});
  check(p.nodes.btnTurnstileNext.clicks, 0);
  p.stage('stepPassword'); p.time(4000);
  check(p.run(ucEvaluation).status, 'ucPassword');
  check(p.nodes.btnSubmitPwd.clicks, 0);
  check(p.run(ucResolvedEvaluation).status, 'waiting');
  check(p.nodes.accessPwdInput.value, '动态访问密码');
  check(p.nodes.btnSubmitPwd.clicks, 1);
  p.nodes.ucText.textContent = '下一轮网页口令';
  check(p.run(ucResolvedEvaluation), {status: 'ucPassword', command: '下一轮网页口令'});
  check(p.nodes.btnSubmitPwd.clicks, 1);
  check(p.run(ucUnsupportedEvaluation).status, 'waiting');
  p.nodes.ucText.textContent = '';
  check(p.run(ucEvaluation).status, 'waiting');
}
{
  const p = page(); p.stage('stepPassword'); p.nodes.ucText.textContent = '网页当前口令';
  const legacy = `JSON.stringify((function(config){${recipe}})({firstPassword:''}))`;
  p.run(legacy); p.time(4000);
  check(p.run(legacy).status, 'waiting');
  check(p.nodes.btnSubmitPwd.clicks, 0);
  check(p.nodes.accessPwdInput.value, '');
}
{
  const p = page();
  p.context.document.body.innerText = 'Sorry, you have been blocked. Cloudflare Ray ID: 0123456789abcdef';
  p.nodes.ucText.textContent = '网页当前口令';
  p.stage('stepPassword');
  const result = p.run(ucResolvedEvaluation);
  check(result.status, 'error');
  check(result.code, 'CF_BLOCKED');
  check(result.cfRay, '0123456789abcdef');
  check(result.password, undefined);
  check(p.nodes.btnSubmitPwd.clicks, 0);
  check(p.nodes.btnTurnstileNext.clicks, 0);
  // The page and challenge widgets remain visible, including on older clients.
  check(p.nodes.stepPassword.style.display, '');
  const legacy = `JSON.stringify((function(config){${recipe}})({firstPassword:''}))`;
  check(p.run(legacy).status, 'error');
  p.context.document.body.innerText = 'Cloudflare Turnstile: 请完成人机验证';
  p.stage('stepTurnstile');
  check(p.run().status, 'waiting');
  check(p.nodes.btnTurnstileNext.clicks, 0);
}
console.log(`${assertions} browser-flow assertions passed`);
