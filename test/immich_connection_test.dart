import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_pipeline_app/src/immich_connection.dart';

void main() {
  group('buildImmichApiBaseUri', () {
    test('adds scheme and api path to host-only input', () {
      expect(
        buildImmichApiBaseUri('localhost:2283').toString(),
        'http://localhost:2283/api/',
      );
    });

    test('keeps existing api path without duplicating it', () {
      expect(
        buildImmichApiBaseUri('https://photos.example.test/api').toString(),
        'https://photos.example.test/api/',
      );
    });

    test('rejects unsupported schemes', () {
      expect(
        () => buildImmichApiBaseUri('ftp://photos.example.test'),
        throwsFormatException,
      );
    });
  });

  group('ImmichApiClient', () {
    test('rejects a bad server URL before making requests', () async {
      final client = ImmichApiClient(
        get: (uri, headers) async =>
            const ImmichHttpResponse(statusCode: 200, body: '{"res":"pong"}'),
      );

      await expectLater(
        client.check(
          const ImmichConnectionSettings(serverUrl: '', apiKey: 'secret'),
        ),
        throwsA(
          isA<ImmichConnectionException>().having(
            (error) => error.issue,
            'issue',
            ImmichConnectionIssue.invalidServerUrl,
          ),
        ),
      );
    });

    test(
      'reports the server as unavailable when ping cannot connect',
      () async {
        final client = ImmichApiClient(
          get: (uri, headers) async {
            throw const SocketException('Connection refused');
          },
        );

        await expectLater(
          client.check(
            const ImmichConnectionSettings(
              serverUrl: 'http://localhost:2283',
              apiKey: 'secret',
            ),
          ),
          throwsA(
            isA<ImmichConnectionException>().having(
              (error) => error.issue,
              'issue',
              ImmichConnectionIssue.serverUnavailable,
            ),
          ),
        );
      },
    );

    test(
      'checks ping, about, and statistics using read-only GET requests',
      () async {
        final calls = <Uri>[];
        final headersByPath = <String, Map<String, String>>{};
        final client = ImmichApiClient(
          get: (uri, headers) async {
            calls.add(uri);
            headersByPath[uri.path] = headers;
            return switch (uri.path) {
              '/api/server/ping' => const ImmichHttpResponse(
                statusCode: 200,
                body: '{"res":"pong"}',
              ),
              '/api/server/about' => ImmichHttpResponse(
                statusCode: 200,
                body: jsonEncode({'version': '1.140.0', 'licensed': false}),
              ),
              '/api/server/statistics' => ImmichHttpResponse(
                statusCode: 200,
                body: jsonEncode({
                  'photos': 1200,
                  'videos': 45,
                  'usage': 987654321,
                }),
              ),
              _ => const ImmichHttpResponse(statusCode: 404, body: '{}'),
            };
          },
        );

        final report = await client.check(
          const ImmichConnectionSettings(
            serverUrl: 'http://immich.local:2283',
            apiKey: 'secret',
          ),
        );

        expect(calls.map((uri) => uri.path), [
          '/api/server/ping',
          '/api/server/about',
          '/api/server/statistics',
        ]);
        expect(headersByPath['/api/server/ping'], isEmpty);
        expect(headersByPath['/api/server/about'], {'x-api-key': 'secret'});
        expect(report.pingOk, isTrue);
        expect(report.authenticated, isTrue);
        expect(report.version, '1.140.0');
        expect(report.photos, 1200);
        expect(report.videos, 45);
        expect(report.usageBytes, 987654321);
      },
    );

    test('accepts alternate statistics keys and ignores null or invalid values', () async {
      final client = ImmichApiClient(
        get: (uri, headers) async {
          return switch (uri.path) {
            '/api/server/ping' => const ImmichHttpResponse(
              statusCode: 200,
              body: '{"res":"pong"}',
            ),
            '/api/server/about' => ImmichHttpResponse(
              statusCode: 200,
              body: jsonEncode({'version': '1.140.0'}),
            ),
            '/api/server/statistics' => ImmichHttpResponse(
              statusCode: 200,
              body: jsonEncode({
                'photos': null,
                'photoCount': '1200',
                'videoCount': 'not-a-number',
                'usageBytes': null,
                'storageUsageBytes': 987654321.0,
              }),
            ),
            _ => const ImmichHttpResponse(statusCode: 404, body: '{}'),
          };
        },
      );

      final report = await client.check(
        const ImmichConnectionSettings(
          serverUrl: 'http://localhost:2283',
          apiKey: 'secret',
        ),
      );

      expect(report.photos, 1200);
      expect(report.videos, isNull);
      expect(report.usageBytes, 987654321);
    });

    test('supports ping-only connection without an API key', () async {
      final calls = <Uri>[];
      final client = ImmichApiClient(
        get: (uri, headers) async {
          calls.add(uri);
          return const ImmichHttpResponse(
            statusCode: 200,
            body: '{"res":"pong"}',
          );
        },
      );

      final report = await client.check(
        const ImmichConnectionSettings(
          serverUrl: 'http://localhost:2283',
          apiKey: '',
        ),
      );

      expect(calls.map((uri) => uri.path), ['/api/server/ping']);
      expect(report.pingOk, isTrue);
      expect(report.authenticated, isFalse);
      expect(report.message, contains('Add an Immich API key'));
    });

    test('rejects a bad API key with a specific error', () async {
      final client = ImmichApiClient(
        get: (uri, headers) async {
          return switch (uri.path) {
            '/api/server/ping' => const ImmichHttpResponse(
              statusCode: 200,
              body: '{"res":"pong"}',
            ),
            '/api/server/about' => const ImmichHttpResponse(
              statusCode: 401,
              body: '{}',
            ),
            _ => const ImmichHttpResponse(statusCode: 404, body: '{}'),
          };
        },
      );

      await expectLater(
        client.check(
          const ImmichConnectionSettings(
            serverUrl: 'http://localhost:2283',
            apiKey: 'bad-key',
          ),
        ),
        throwsA(
          isA<ImmichConnectionException>().having(
            (error) => error.issue,
            'issue',
            ImmichConnectionIssue.invalidApiKey,
          ),
        ),
      );
    });

    test('reports missing permission for a forbidden about request', () async {
      final client = ImmichApiClient(
        get: (uri, headers) async {
          return switch (uri.path) {
            '/api/server/ping' => const ImmichHttpResponse(
              statusCode: 200,
              body: '{"res":"pong"}',
            ),
            '/api/server/about' => const ImmichHttpResponse(
              statusCode: 403,
              body: '{}',
            ),
            _ => const ImmichHttpResponse(statusCode: 404, body: '{}'),
          };
        },
      );

      await expectLater(
        client.check(
          const ImmichConnectionSettings(
            serverUrl: 'http://localhost:2283',
            apiKey: 'secret',
          ),
        ),
        throwsA(
          isA<ImmichConnectionException>().having(
            (error) => error.issue,
            'issue',
            ImmichConnectionIssue.missingPermission,
          ),
        ),
      );
    });

    test(
      'reports missing statistics permission without failing the check',
      () async {
        final client = ImmichApiClient(
          get: (uri, headers) async {
            return switch (uri.path) {
              '/api/server/ping' => const ImmichHttpResponse(
                statusCode: 200,
                body: '{"res":"pong"}',
              ),
              '/api/server/about' => ImmichHttpResponse(
                statusCode: 200,
                body: jsonEncode({'version': '1.140.0', 'licensed': false}),
              ),
              '/api/server/statistics' => const ImmichHttpResponse(
                statusCode: 403,
                body: '{}',
              ),
              _ => const ImmichHttpResponse(statusCode: 404, body: '{}'),
            };
          },
        );

        final report = await client.check(
          const ImmichConnectionSettings(
            serverUrl: 'http://localhost:2283',
            apiKey: 'secret',
          ),
        );

        expect(report.pingOk, isTrue);
        expect(report.authenticated, isTrue);
        expect(report.photos, isNull);
        expect(report.videos, isNull);
        expect(report.message, contains('lacks server.statistics permission'));
      },
    );

    test('handles unavailable statistics without failing connection', () async {
      final client = ImmichApiClient(
        get: (uri, headers) async {
          return switch (uri.path) {
            '/api/server/ping' => const ImmichHttpResponse(
              statusCode: 200,
              body: '{"res":"pong"}',
            ),
            '/api/server/about' => ImmichHttpResponse(
              statusCode: 200,
              body: jsonEncode({'version': '1.140.0'}),
            ),
            '/api/server/statistics' => const ImmichHttpResponse(
              statusCode: 503,
              body: '{}',
            ),
            _ => const ImmichHttpResponse(statusCode: 404, body: '{}'),
          };
        },
      );

      final report = await client.check(
        const ImmichConnectionSettings(
          serverUrl: 'http://localhost:2283',
          apiKey: 'secret',
        ),
      );

      expect(report.pingOk, isTrue);
      expect(report.authenticated, isTrue);
      expect(report.version, '1.140.0');
      expect(report.photos, isNull);
      expect(report.videos, isNull);
      expect(report.usageBytes, isNull);
      expect(report.message, contains('statistics returned HTTP 503'));
    });

    test('loads memory preview assets from read-only search metadata', () async {
      final calls = <Uri>[];
      final headersByPath = <String, Map<String, String>>{};
      final bodies = <String>[];
      final client = ImmichApiClient(
        post: (uri, headers, body) async {
          calls.add(uri);
          headersByPath[uri.path] = headers;
          bodies.add(body);
          return ImmichHttpResponse(
            statusCode: 200,
            body: jsonEncode({
              'assets': [
                {
                  'id': 'asset-1',
                  'localDateTime': '2024-05-27T12:00:00Z',
                  'isFavorite': true,
                  'albums': [
                    {'name': 'Lisbon Week'},
                  ],
                  'people': [
                    {'person': {'name': 'Leo'}},
                  ],
                  'exifInfo': {'city': 'Lisbon'},
                },
                {
                  'id': 'asset-2',
                  'fileCreatedAt': '2024-05-29T12:00:00Z',
                  'duplicateId': 'dup-1',
                  'people': [
                    {'name': 'Ana'},
                  ],
                  'exifInfo': {'city': 'Lisbon'},
                },
              ],
            }),
          );
        },
      );

      final assets = await client.loadMemoryPreviewAssets(
        const ImmichConnectionSettings(
          serverUrl: 'http://immich.local:2283',
          apiKey: 'secret',
        ),
      );

      expect(calls.map((uri) => uri.path), ['/api/search/metadata']);
      expect(headersByPath['/api/search/metadata'], {
        'x-api-key': 'secret',
        'content-type': 'application/json',
      });
      expect(bodies, hasLength(1));
      expect(jsonDecode(bodies.single), {
        'size': 100,
        'withDeleted': false,
        'withExif': true,
        'withPeople': true,
      });
      expect(assets, hasLength(2));
      expect(assets.first.id, 'asset-1');
      expect(assets.first.isFavorite, isTrue);
      expect(assets.first.albumNames, ['Lisbon Week']);
      expect(assets.first.peopleNames, ['Leo']);
      expect(assets.first.city, 'Lisbon');
      expect(assets.first.isNearDuplicate, isFalse);
      expect(assets.last.id, 'asset-2');
      expect(assets.last.peopleNames, ['Ana']);
      expect(assets.last.isNearDuplicate, isTrue);
    });
  });
}
