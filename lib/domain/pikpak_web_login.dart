class PikPakWebLogin {
  // Verified against the official drive frontend (build d254e901).
  static const clientId = 'YUMx5nI8ZU8Ap8pm';
  static const storageKey = 'credentials_$clientId';

  static const readScript = r'''(() => {
    const client = 'YUMx5nI8ZU8Ap8pm';
    const prefix = 'credentials_' + client;
    const stores = [];
    for (const name of ['localStorage', 'sessionStorage']) {
      try { if (window[name]) stores.push(window[name]); } catch (_) {}
    }
    const read = (store, key) => {
      try {
        let value = store.getItem(key);
        for (let depth = 0; depth < 3 && typeof value === 'string'; depth++) {
          // Identifiers can be long decimal strings; parsing them as numbers
          // would round the account/device ID before matching it.
          if (!['"', '{', '['].includes(value.trim().charAt(0))) break;
          try { value = JSON.parse(value); } catch (_) { break; }
        }
        return value;
      } catch (_) { return null; }
    };
    const text = value => typeof value === 'string' || typeof value === 'number'
      ? String(value).trim() : '';
    const subject = data => text(data.sub || data.user_id || data.userId);
    const sub = stores.map(store => text(read(store, 'current_sub'))).find(Boolean) || '';
    const decode = value => {
      for (let depth = 0; depth < 5; depth++) {
        if (typeof value === 'string') {
          try { value = JSON.parse(value); } catch (_) { return null; }
        } else if (value && typeof value === 'object' && !Array.isArray(value)) {
          if (value.access_token || value.accessToken || value.refresh_token || value.refreshToken) return value;
          value = value.credentials || value.token || value.data;
        } else { return null; }
      }
      return null;
    };
    for (const store of stores) {
      const keys = sub ? [prefix + '@' + sub, prefix, 'credentials@' + sub, 'credentials', 'token']
        : [prefix, 'credentials', 'token'];
      for (const key of keys) {
        const data = decode(read(store, key));
        if (!data) continue;
        const owner = subject(data);
        // A generic/old key is never evidence that a different account signed in.
        if (sub && owner !== sub) continue;
        const declaredClient = text(data.client_id || data.clientId);
        if (declaredClient && declaredClient !== client) continue;
        const result = {
          access_token: data.access_token || data.accessToken || '',
          refresh_token: data.refresh_token || data.refreshToken || '',
          sub: owner,
          client_id: client,
          expires_at: data.expires_at || data.expiresAt || data.expire_time || '',
          name: text(data.name || data.nickname),
          device_id: text(data.device_id || data.deviceId),
        };
        if (!result.device_id) {
          for (const source of [store, ...stores.filter(item => item !== store)]) {
            const device = text(read(source, 'deviceid')) || text(read(source, '_deviceid'));
            if (device) { result.device_id = device.split('.').pop().slice(0, 32); break; }
          }
        }
        const captcha = decode(read(store, 'captcha_' + client)) || read(store, 'captcha_' + client);
        if (captcha && typeof captcha === 'object' && !Array.isArray(captcha) &&
            (!subject(captcha) || subject(captcha) === owner) &&
            Date.parse(captcha.expires_at || captcha.expiresAt || '') > Date.now()) {
          result.captcha_token = captcha.captcha_token || captcha.token || '';
        }
        return JSON.stringify(result);
      }
    }
    return '';
  })()''';

  static const clearScript = r'''(() => {
    const client = 'YUMx5nI8ZU8Ap8pm';
    const prefix = 'credentials_' + client;
    for (const name of ['localStorage', 'sessionStorage']) {
      try {
        const store = window[name];
        for (const key of Object.keys(store)) {
          if (key === prefix || key.startsWith(prefix + '@') ||
              key === 'credentials' || key.startsWith('credentials@') ||
              key === 'current_sub' || key === 'token' ||
              key === 'captcha_' + client || key === 'oauth_sign_in_' + client) {
            store.removeItem(key);
          }
        }
      } catch (_) {}
    }
  })()''';
}
