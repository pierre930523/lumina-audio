part of '../deezer_provider.dart';

void _throwIfGatewayError(Map<String, dynamic> json) {
  final err = json['error'];
  String? errSummary;
  if (err is Map && err.isNotEmpty) {
    errSummary = err.entries.map((e) => '${e.key}: ${e.value}').join(', ');
  } else if (err is List && err.isNotEmpty) {
    errSummary = err.join(', ');
  }
  if (errSummary == null || errSummary.isEmpty) return;

  final classified = StreamingException.classifyKind(message: errSummary);
  if (classified == StreamingErrorKind.regionRestricted ||
      classified == StreamingErrorKind.trackUnavailable) {
    throw StreamingException(
      'Deezer Gateway 錯誤：$errSummary',
      kind: classified,
    );
  }
  throw StreamingException(
    'Deezer Gateway 錯誤：$errSummary',
    statusCode: 401,
    isTokenExpired: true,
  );
}

extension _DeezerGatewayApi on DeezerProvider {
  Future<StreamingAccountInfo> _verifyArlLive({
    CancellationToken? cancel,
  }) async {
    final uri = BaseStreamingProvider.buildUri(
      gwUrl,
      '',
      const <String, String>{
        'method': 'deezer.getUserData',
        'input': '3',
        'api_version': '1.0',
        'api_token': '',
      },
    );

    final json = await http.requestJson(
      method: 'POST',
      uri: uri,
      headers: <String, String>{
        'Cookie': 'arl=${_arl ?? ''}',
        'Accept': 'application/json',
      },
      jsonBody: const <String, dynamic>{},
      cancel: cancel,
    );

    _throwIfGatewayError(json);

    final results = json['results'];
    if (results is! Map) {
      throw const StreamingException(
        'Deezer getUserData 未回傳 results 欄位',
        statusCode: 401,
      );
    }

    final user = results['USER'];
    if (user is! Map) {
      throw const StreamingException(
        'Deezer getUserData 未回傳 USER 資料',
        statusCode: 401,
      );
    }

    final rawUid = user['USER_ID'];
    final uid = rawUid is num ? rawUid.toInt() : int.tryParse('$rawUid') ?? 0;
    if (uid == 0) {
      throw const StreamingException(
        'Deezer ARL Cookie 無效或已過期（USER_ID == 0，未登入任何帳號）',
        statusCode: 401,
        isTokenExpired: true,
      );
    }

    _userId = uid.toString();
    _apiToken = results['checkForm']?.toString();

    final options = user['OPTIONS'] ?? results['OPTIONS'];
    if (options is Map) {
      _licenseToken = options['license_token']?.toString().trim();
      _webLossless = options['web_lossless'] == true;
      _webHq = options['web_hq'] == true;
    } else {
      _licenseToken = null;
      _webLossless = false;
      _webHq = false;
    }

    final blogName = user['BLOG_NAME']?.toString().trim();
    final inscription = user['INSCRIPTION'] is Map
        ? (user['INSCRIPTION'] as Map)['FULL_NAME']?.toString().trim()
        : null;
    final displayName = (blogName != null && blogName.isNotEmpty)
        ? blogName
        : ((inscription != null && inscription.isNotEmpty)
              ? inscription
              : 'Deezer #$uid');

    final offerName = results['OFFER_NAME']?.toString().trim() ??
        user['OFFER_NAME']?.toString().trim();
    final planTier = (offerName != null && offerName.isNotEmpty)
        ? offerName
        : (_webLossless
              ? 'Deezer HiFi (Lossless)'
              : (_webHq ? 'Deezer Premium' : 'Deezer Free'));

    return StreamingAccountInfo(
      displayName: displayName,
      planTier: planTier,
      userId: _userId,
      email: user['EMAIL']?.toString(),
      countryCode:
          results['COUNTRY']?.toString() ?? user['COUNTRY']?.toString(),
    );
  }

  Future<StreamingAccountInfo> _verifyOAuthLive({
    CancellationToken? cancel,
    int? expiresInSec,
  }) async {
    final json = await _callPublicApi(
      '/user/me',
      cancel: cancel,
    );
    final uid = json['id']?.toString().trim() ?? '';
    if (uid.isEmpty || uid == '0') {
      throw const StreamingException(
        'Deezer /user/me 未回傳有效帳號 ID',
        statusCode: 401,
        isTokenExpired: true,
      );
    }
    _userId = uid;

    final name = json['name']?.toString().trim();
    return StreamingAccountInfo(
      displayName: (name != null && name.isNotEmpty) ? name : 'Deezer #$uid',
      planTier: 'Deezer OAuth (Preview)',
      userId: uid,
      email: json['email']?.toString(),
      countryCode: json['country']?.toString(),
      expiresAt: expiresInSec != null && expiresInSec > 0
          ? clock().add(Duration(seconds: expiresInSec))
          : null,
    );
  }

  Future<Map<String, dynamic>> _callPublicApi(
    String path, {
    Map<String, String> query = const {},
    bool forceRefresh = false,
    CancellationToken? cancel,
    Duration? timeout,
  }) async {
    final qp = <String, String>{
      ...query,
      if (_authMode == 'oauth' &&
          _accessToken != null &&
          _accessToken!.isNotEmpty)
        'access_token': _accessToken!,
    };
    final uri = BaseStreamingProvider.buildUri(apiBaseUrl, path, qp);
    final json = await http.requestJson(
      method: 'GET',
      uri: uri,
      headers: BaseStreamingProvider.withNoCacheHeaders(
        const <String, String>{'Accept': 'application/json'},
        forceRefresh: forceRefresh,
      ),
      cancel: cancel,
      timeout: timeout,
    );

    final err = json['error'];
    if (err is Map) {
      final code = (err['code'] as num?)?.toInt();
      final msg = err['message']?.toString() ?? 'Deezer API 錯誤';
      throw StreamingException(
        'Deezer API 錯誤：$msg',
        statusCode: code == 300 || code == 200 ? 401 : 400,
        isTokenExpired: code == 300 || msg.toLowerCase().contains('token'),
      );
    }
    return json;
  }
}
