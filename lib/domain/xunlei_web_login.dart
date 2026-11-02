class XunleiWebLogin {
  static const clientId = 'Xqp0kJBXWhwaTpB6';
  static const storageKey = 'credentials_$clientId';
  static const storageOrigin = 'https://pan.xunlei.com';
  static const accountOrigin = 'https://i.xunlei.com';
  static const accountClientId = 'XW5SkOhLDjnOZP7J';

  // The cloud's embedded auth page omits Xiaomi. The account center exposes
  // all official providers and returns to the cloud to issue its own token.
  static const loginUrl =
      '$accountOrigin/center/account/personal/login/'
      '?redirect_url=https%3A%2F%2Fpan.xunlei.com%2F';

  static const readScript = r'''(() => {
    try {
      const prefix = 'credentials_Xqp0kJBXWhwaTpB6';
      const sub = localStorage.getItem('current_sub');
      const raw = sub ? localStorage.getItem(prefix + '@' + sub) : localStorage.getItem(prefix);
      if (!raw) return '';
      const data = JSON.parse(raw);
      if (!data || typeof data !== 'object' || Array.isArray(data)) return '';
      if (sub && data.sub && String(data.sub) !== sub) return '';
      try {
        const captcha = JSON.parse(localStorage.getItem('captcha_Xqp0kJBXWhwaTpB6') || '{}');
        if (captcha && captcha.token && Date.parse(captcha.expires_at) > Date.now()) data.captcha_token = captcha.token;
      } catch (_) {}
      try {
        const cookie = document.cookie.split(';').map(s => s.trim()).find(s => s.startsWith('deviceid='));
        if (cookie) {
          const device = decodeURIComponent(cookie.slice(9));
          data.device_id = device.includes('.') && device.length > 32 ? device.split('.')[1].slice(0, 32) : device;
        }
      } catch (_) {}
      return JSON.stringify(data);
    } catch (_) { return ''; }
  })()''';

  static const clearScript =
      '''(() => {
    const client = location.origin === '$accountOrigin' ? '$accountClientId' : '$clientId';
    const prefix = 'credentials_' + client;
    for (const storage of [localStorage, sessionStorage]) {
      for (const key of Object.keys(storage)) {
        if (key === prefix || key.startsWith(prefix + '@') ||
            key === 'current_sub' || key === 'captcha_' + client ||
            key === 'oauth_sign_in_' + client) storage.removeItem(key);
      }
    }
  })()''';
}
