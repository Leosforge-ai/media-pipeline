import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'memory_curator.dart';

class ImmichConnectionSettings {
  const ImmichConnectionSettings({
    required this.serverUrl,
    required this.apiKey,
  });

  final String serverUrl;
  final String apiKey;

  Uri get apiBaseUri => buildImmichApiBaseUri(serverUrl);
}

class ImmichConnectionReport {
  const ImmichConnectionReport({
    required this.serverUrl,
    required this.pingOk,
    required this.authenticated,
    this.version,
    this.licensed,
    this.photos,
    this.videos,
    this.usageBytes,
    this.message,
  });

  final String serverUrl;
  final bool pingOk;
  final bool authenticated;
  final String? version;
  final bool? licensed;
  final int? photos;
  final int? videos;
  final int? usageBytes;
  final String? message;

  String get statusLabel {
    if (!pingOk) {
      return 'Server not reachable';
    }
    if (!authenticated) {
      return 'Server reachable; API key not verified';
    }
    return 'Server reachable; API key verified';
  }
}

enum ImmichConnectionIssue {
  invalidServerUrl,
  serverUnavailable,
  invalidApiKey,
  missingPermission,
  unexpectedResponse,
}

class ImmichConnectionException implements Exception {
  const ImmichConnectionException(this.issue, this.message);

  final ImmichConnectionIssue issue;
  final String message;

  @override
  String toString() => message;
}

class ImmichHttpResponse {
  const ImmichHttpResponse({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}

typedef ImmichHttpGet =
    Future<ImmichHttpResponse> Function(Uri uri, Map<String, String> headers);
typedef ImmichHttpPost =
    Future<ImmichHttpResponse> Function(
      Uri uri,
      Map<String, String> headers,
      String body,
    );

class ImmichApiClient {
  ImmichApiClient({ImmichHttpGet? get, ImmichHttpPost? post})
    : _get = get ?? _defaultGet,
      _post = post ?? _defaultPost;

  final ImmichHttpGet _get;
  final ImmichHttpPost _post;

  Future<ImmichConnectionReport> check(
    ImmichConnectionSettings settings,
  ) async {
    final apiBase = _resolveApiBase(settings.serverUrl);
    final ping = await _request(apiBase.resolve('server/ping'), const {});
    if (ping.statusCode < 200 || ping.statusCode >= 300) {
      return ImmichConnectionReport(
        serverUrl: apiBase.toString(),
        pingOk: false,
        authenticated: false,
        message:
            'Immich server responded to ping with HTTP ${ping.statusCode}. Check the server URL and whether the Docker container is running.',
      );
    }

    if (settings.apiKey.trim().isEmpty) {
      return ImmichConnectionReport(
        serverUrl: apiBase.toString(),
        pingOk: true,
        authenticated: false,
        message:
            'Add an Immich API key to verify authenticated access and read server details.',
      );
    }

    final headers = {'x-api-key': settings.apiKey.trim()};
    final about = await _request(apiBase.resolve('server/about'), headers);
    if (about.statusCode == HttpStatus.unauthorized) {
      throw const ImmichConnectionException(
        ImmichConnectionIssue.invalidApiKey,
        'The Immich API key was rejected. Create a fresh key in the web app and make sure it can read server.about.',
      );
    }
    if (about.statusCode == HttpStatus.forbidden) {
      throw const ImmichConnectionException(
        ImmichConnectionIssue.missingPermission,
        'The Immich API key can reach the server, but it lacks permission to read server.about.',
      );
    }
    if (about.statusCode < 200 || about.statusCode >= 300) {
      throw ImmichConnectionException(
        ImmichConnectionIssue.unexpectedResponse,
        'Immich returned HTTP ${about.statusCode} for server info. Try the manual curl checks in the docs.',
      );
    }

    final aboutJson = (() {
      try {
        return _decodeObject(about.body, context: 'server/about');
      } on FormatException {
        throw const ImmichConnectionException(
          ImmichConnectionIssue.unexpectedResponse,
          'Immich returned an unexpected payload for server info. Try the manual curl checks in the docs.',
        );
      }
    })();
    Map<String, Object?> statisticsJson = const {};
    String? statisticsNote;
    try {
      final statistics = await _request(
        apiBase.resolve('server/statistics'),
        headers,
      );
      if (statistics.statusCode >= 200 && statistics.statusCode < 300) {
        statisticsJson = _decodeObject(
          statistics.body,
          context: 'server/statistics',
        );
      } else if (statistics.statusCode == HttpStatus.unauthorized) {
        statisticsNote =
            'Server info is verified, but this API key is invalid for server.statistics.';
      } else if (statistics.statusCode == HttpStatus.forbidden) {
        statisticsNote =
            'Server info is verified, but this API key lacks server.statistics permission.';
      } else {
        statisticsNote =
            'Server info is verified, but statistics returned HTTP ${statistics.statusCode}.';
      }
    } on ImmichConnectionException catch (error) {
      statisticsNote =
          'Server info is verified, but statistics are not available right now: ${error.message}';
    } on FormatException catch (_) {
      statisticsNote =
          'Server info is verified, but statistics could not be parsed from Immich.';
    } catch (_) {
      statisticsJson = const {};
      statisticsNote =
          'Server info is verified, but statistics are not available right now.';
    }

    return ImmichConnectionReport(
      serverUrl: apiBase.toString(),
      pingOk: true,
      authenticated: true,
      version: _stringValue(aboutJson['version']),
      licensed: aboutJson['licensed'] is bool
          ? aboutJson['licensed'] as bool
          : null,
      photos: _intValueFromKeys(statisticsJson, const [
        'photos',
        'photoCount',
        'photosCount',
      ]),
      videos: _intValueFromKeys(statisticsJson, const [
        'videos',
        'videoCount',
        'videosCount',
      ]),
      usageBytes: _intValueFromKeys(statisticsJson, const [
        'usage',
        'usageByUser',
        'usageBytes',
        'storageUsage',
        'storageUsageBytes',
      ]),
      message: statisticsJson.isEmpty
          ? statisticsNote ??
                'Server info verified. Statistics were not available with this key.'
          : 'Read-only Immich API check completed.',
    );
  }

  Future<List<MemoryPreviewAsset>> loadMemoryPreviewAssets(
    ImmichConnectionSettings settings, {
    int size = 100,
  }) async {
    final apiBase = _resolveApiBase(settings.serverUrl);
    final apiKey = settings.apiKey.trim();
    if (apiKey.isEmpty) {
      throw const ImmichConnectionException(
        ImmichConnectionIssue.invalidApiKey,
        'Add an Immich API key to load live memory preview assets.',
      );
    }

    final response = await _post(
      apiBase.resolve('search/metadata'),
      {
        'x-api-key': apiKey,
        HttpHeaders.contentTypeHeader: 'application/json',
      },
      jsonEncode({
        'size': size,
        'withDeleted': false,
        'withExif': true,
        'withPeople': true,
      }),
    );
    if (response.statusCode == HttpStatus.unauthorized) {
      throw const ImmichConnectionException(
        ImmichConnectionIssue.invalidApiKey,
        'The Immich API key was rejected while loading memory preview assets.',
      );
    }
    if (response.statusCode == HttpStatus.forbidden) {
      throw const ImmichConnectionException(
        ImmichConnectionIssue.missingPermission,
        'The Immich API key can reach Immich, but it lacks permission to read assets for the preview.',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ImmichConnectionException(
        ImmichConnectionIssue.unexpectedResponse,
        'Immich returned HTTP ${response.statusCode} while loading preview assets.',
      );
    }

    final decoded = _decodeObject(response.body, context: 'search/metadata');
    final assetsJson = decoded['assets'];
    if (assetsJson is! List) {
      throw const ImmichConnectionException(
        ImmichConnectionIssue.unexpectedResponse,
        'Immich returned an unexpected payload for search/metadata.',
      );
    }

    return [
      for (final item in assetsJson)
        if (item is Map)
          _memoryPreviewAssetFromJson(
            item.map((key, value) => MapEntry('$key', value)),
          ),
    ];
  }

  Future<ImmichHttpResponse> _request(
    Uri uri,
    Map<String, String> headers,
  ) async {
    try {
      return await _get(uri, headers);
    } on TimeoutException {
      throw const ImmichConnectionException(
        ImmichConnectionIssue.serverUnavailable,
        'Immich server timed out. Check the URL, your network, and any VPN or Docker port forwarding.',
      );
    } on SocketException catch (error) {
      throw ImmichConnectionException(
        ImmichConnectionIssue.serverUnavailable,
        'Immich server is not reachable: ${error.message}',
      );
    }
  }

  static Future<ImmichHttpResponse> _defaultGet(
    Uri uri,
    Map<String, String> headers,
  ) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 8));
      for (final header in headers.entries) {
        request.headers.set(header.key, header.value);
      }
      final response = await request.close().timeout(
        const Duration(seconds: 12),
      );
      final body = await utf8
          .decodeStream(response)
          .timeout(const Duration(seconds: 12));
      return ImmichHttpResponse(statusCode: response.statusCode, body: body);
    } on TimeoutException {
      throw const ImmichConnectionException(
        ImmichConnectionIssue.serverUnavailable,
        'Immich server timed out. Check the URL, your network, and any VPN or Docker port forwarding.',
      );
    } on SocketException catch (error) {
      throw ImmichConnectionException(
        ImmichConnectionIssue.serverUnavailable,
        'Immich server is not reachable: ${error.message}',
      );
    } finally {
      client.close(force: true);
    }
  }

  static Future<ImmichHttpResponse> _defaultPost(
    Uri uri,
    Map<String, String> headers,
    String body,
  ) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client
          .postUrl(uri)
          .timeout(const Duration(seconds: 8));
      for (final header in headers.entries) {
        request.headers.set(header.key, header.value);
      }
      request.write(body);
      final response = await request.close().timeout(
        const Duration(seconds: 12),
      );
      final responseBody = await utf8
          .decodeStream(response)
          .timeout(const Duration(seconds: 12));
      return ImmichHttpResponse(
        statusCode: response.statusCode,
        body: responseBody,
      );
    } on TimeoutException {
      throw const ImmichConnectionException(
        ImmichConnectionIssue.serverUnavailable,
        'Immich server timed out. Check the URL, your network, and any VPN or Docker port forwarding.',
      );
    } on SocketException catch (error) {
      throw ImmichConnectionException(
        ImmichConnectionIssue.serverUnavailable,
        'Immich server is not reachable: ${error.message}',
      );
    } finally {
      client.close(force: true);
    }
  }
}

Uri buildImmichApiBaseUri(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) {
    throw const FormatException(
      'Enter an Immich server URL such as http://localhost:2283.',
    );
  }

  final withScheme = trimmed.contains('://') ? trimmed : 'http://$trimmed';
  final uri = Uri.parse(withScheme);
  if (!uri.hasScheme || uri.host.isEmpty || uri.host.contains(' ')) {
    throw const FormatException(
      'Enter a valid Immich server URL such as http://localhost:2283.',
    );
  }
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    throw const FormatException('Immich URL must use http or https.');
  }

  final segments = uri.pathSegments.where((segment) => segment.isNotEmpty);
  final normalizedSegments = [
    ...segments,
    if (segments.isEmpty || segments.last != 'api') 'api',
    '',
  ];
  return uri.replace(pathSegments: normalizedSegments);
}

Uri _resolveApiBase(String serverUrl) {
  try {
    return buildImmichApiBaseUri(serverUrl);
  } on FormatException {
    throw const ImmichConnectionException(
      ImmichConnectionIssue.invalidServerUrl,
      'Enter a valid Immich server URL such as http://localhost:2283.',
    );
  }
}

Map<String, Object?> _decodeObject(String body, {required String context}) {
  final decoded = jsonDecode(body);
  if (decoded is Map<String, Object?>) {
    return decoded;
  }
  throw FormatException('Unexpected JSON payload for $context.');
}

String? _stringValue(Object? value) => value == null ? null : '$value';

int? _intValue(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.round();
  }
  if (value is String) {
    return int.tryParse(value.trim());
  }
  return null;
}

int? _intValueFromKeys(
  Map<String, Object?> map,
  List<String> keys,
) {
  for (final key in keys) {
    final value = _intValue(map[key]);
    if (value != null) {
      return value;
    }
  }
  return null;
}

MemoryPreviewAsset _memoryPreviewAssetFromJson(Map<String, Object?> json) {
  final exifInfo = _mapValue(json['exifInfo']);
  final assetPeople = _listValue(json['people'])
      .expand((entry) {
        final map = _mapValue(entry);
        final names = <String>[];
        final directName = _stringValue(map?['name']);
        if (directName != null && directName.trim().isNotEmpty) {
          names.add(directName.trim());
        }
        final nestedName = _stringValue(_mapValue(map?['person'])?['name']);
        if (nestedName != null && nestedName.trim().isNotEmpty) {
          names.add(nestedName.trim());
        }
        return names;
      })
      .toSet()
      .toList();
  final albumNames = _listValue(json['albums'])
      .expand((entry) {
        final map = _mapValue(entry);
        return [
          _stringValue(map?['name']),
          _stringValue(map?['albumName']),
          _stringValue(map?['title']),
        ].whereType<String>().map((value) => value.trim()).where(
          (value) => value.isNotEmpty,
        );
      })
      .toSet()
      .toList();

  return MemoryPreviewAsset(
    id: _stringValue(json['id']) ?? 'unknown',
    takenAt:
        _dateTimeValue(json['localDateTime']) ??
        _dateTimeValue(json['fileCreatedAt']) ??
        _dateTimeValue(json['createdAt']) ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    isFavorite: json['isFavorite'] == true,
    albumNames: albumNames,
    peopleNames: assetPeople,
    city:
        _stringValue(exifInfo?['city']) ??
        _stringValue(json['city']) ??
        _stringValue(exifInfo?['state']),
    isNearDuplicate: _stringValue(json['duplicateId']) != null,
  );
}

Map<String, Object?>? _mapValue(Object? value) {
  if (value is Map<String, Object?>) {
    return value;
  }
  if (value is Map) {
    return value.map((key, value) => MapEntry('$key', value));
  }
  return null;
}

List<Object?> _listValue(Object? value) {
  if (value is List<Object?>) {
    return value;
  }
  if (value is List) {
    return value.cast<Object?>();
  }
  return const [];
}

DateTime? _dateTimeValue(Object? value) {
  if (value is DateTime) {
    return value;
  }
  if (value is String) {
    return DateTime.tryParse(value);
  }
  return null;
}
