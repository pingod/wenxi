import 'dart:convert';
import 'package:asterlink/core/crypto_box.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'support.dart';
import 'token_cloud_support.dart';

// Match the official H5 client independently of the production protocol helper.
Json wopanWebParam(RecordedRequest request) {
  final body = request.json;
  return asJson(
    jsonDecode(
      utf8.decode(
        CryptoBox.aesCbc(
          false,
          base64Decode(
            body.str('param').ifEmpty(body.obj('body').str('param')),
          ),
          utf8.encode('iELf0UL07o6I8eRK'),
          utf8.encode('wNSOYIB1k1DjY5lA'),
        ),
      ),
    ),
  );
}

HttpResult wopanLoginResponse(RecordedRequest request) {
  final key = request.json.obj('header').str('key');
  final Json data;
  if (request.uri.path == '/api-user/sendMessageCodeBase') {
    data = {};
  } else {
    data = switch (key) {
      'LoginByMobileV2' => {
        'access_token': accessToken,
        'refresh_token': refreshToken,
        'expires_in': 3600,
      },
      'AppRefreshToken' => {
        'access_token': renewedAccess,
        'refresh_token': renewedRefresh,
        'expires_in': 3600,
      },
      'AppQueryUser' => {'userId': 'wopan-user', 'userName': '短信登录账号'},
      'QueryCloudUsageInfo' => {
        'usageInfo': {'byteTotalSize': 2048, 'byteUsedSize': 512},
      },
      _ => throw StateError('Unexpected Wopan login request'),
    };
  }
  // The user-info endpoint encrypts its response; the login endpoint does not.
  final Object payload = key == 'AppQueryUser'
      ? base64Encode(
          CryptoBox.aesCbc(
            true,
            utf8.encode(jsonEncode(data)),
            utf8.encode('iELf0UL07o6I8eRK'),
            utf8.encode('wNSOYIB1k1DjY5lA'),
          ),
        )
      : data;
  return jsonResponse({
    'STATUS': '200',
    'RSP': {'RSP_CODE': '0000', 'DATA': payload},
  });
}
