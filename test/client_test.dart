import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:posthog_api/posthog_api.dart';
import 'package:test/test.dart';

import '_support/recording_client.dart';

PostHog _client(
  RecordingClient fake, {
  int flushAt = 100,
  int maxBatchSize = 100,
  int maxQueueSize = 1000,
  int fetchRetryCount = 3,
  Duration flushInterval = Duration.zero,
  Duration requestTimeout = const Duration(seconds: 10),
  bool disableCompression = true,
  bool historicalMigration = false,
  bool disabled = false,
  List<BeforeSend> beforeSend = const [],
  PostHogErrorHandler? onError,
}) =>
    PostHog(
      'phc_test',
      host: Uri.parse('https://eu.i.posthog.com/'),
      httpClient: fake.client,
      flushAt: flushAt,
      maxBatchSize: maxBatchSize,
      maxQueueSize: maxQueueSize,
      fetchRetryCount: fetchRetryCount,
      fetchRetryDelay: Duration.zero,
      flushInterval: flushInterval,
      requestTimeout: requestTimeout,
      disableCompression: disableCompression,
      historicalMigration: historicalMigration,
      disabled: disabled,
      beforeSend: beforeSend,
      onError: onError ?? (error, stackTrace) => fail('Unexpected $error'),
    );

http.Response _status(int code) => http.Response('{"error":"x"}', code);

void main() {
  group('construction', () {
    test('rejects a blank api key', () {
      expect(() => PostHog('  '), throwsArgumentError);
    });

    test('strips trailing slashes from the host', () {
      expect(
        PostHog('phc_test', host: Uri.parse('https://eu.i.posthog.com//')).host,
        Uri.parse('https://eu.i.posthog.com'),
      );
    });

    test('keeps a reverse-proxy path in the host', () async {
      final fake = RecordingClient();
      final posthog = PostHog(
        'phc_test',
        host: Uri.parse('https://example.com/ingest'),
        httpClient: fake.client,
      );
      await posthog.captureImmediate(distinctId: 'u', event: 'e');
      expect(fake.requests.single.request.url.toString(),
          'https://example.com/ingest/batch/');
    });

    test('version constant matches the pubspec', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final declared =
          RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(pubspec)!;
      expect(posthogApiVersion, declared.group(1));
    });
  });

  group('event shape', () {
    test('uuid is a v7 UUID and timestamp an ISO-8601 UTC string in ms',
        () async {
      final fake = RecordingClient();
      final posthog = _client(fake);
      posthog.capture(distinctId: 'u', event: 'e');
      posthog.capture(distinctId: 'u', event: 'e');
      await posthog.flush();

      final events = fake.events;
      expect(
        events.map((e) => e['uuid']),
        everyElement(matches(RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ))),
      );
      expect(events[0]['uuid'], isNot(events[1]['uuid']));
      expect(
        events.first['timestamp'],
        matches(RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$')),
      );
    });

    test('caller timestamp and uuid are sent as given', () async {
      final fake = RecordingClient();
      final posthog = _client(fake);
      posthog.capture(
        distinctId: 'u',
        event: 'e',
        timestamp: DateTime.utc(2026, 3, 4, 5, 6, 7, 89),
        uuid: 'my-uuid',
      );
      await posthog.flush();
      expect(fake.events.single['timestamp'], '2026-03-04T05:06:07.089Z');
      expect(fake.events.single['uuid'], 'my-uuid');
    });

    test('library identifies itself', () async {
      final fake = RecordingClient();
      final posthog = _client(fake);
      await posthog.captureImmediate(distinctId: 'u', event: 'e');
      final event = fake.events.single;
      expect(event['library'], 'posthog_api');
      expect(event['library_version'], posthogApiVersion);
      expect((event['properties']! as Map)[r'$lib'], 'posthog_api');
      expect(fake.requests.single.request.headers['User-Agent'],
          'posthog_api/$posthogApiVersion');
    });

    test('historicalMigration marks the batch', () async {
      final fake = RecordingClient();
      final posthog = _client(fake, historicalMigration: true);
      posthog.capture(distinctId: 'u', event: 'e');
      await posthog.flush();
      expect(fake.batches.single.json['historical_migration'], isTrue);
    });

    test('gzips the batch body by default', () async {
      final fake = RecordingClient();
      final posthog = _client(fake, disableCompression: false);
      posthog.capture(distinctId: 'u', event: 'e');
      await posthog.flush();
      final request = fake.requests.single.request;
      expect(request.headers['Content-Encoding'], 'gzip');
      final decoded = jsonDecode(utf8.decode(gzip.decode(request.bodyBytes)));
      expect((decoded as Map)['api_key'], 'phc_test');
    });
  });

  group('beforeSend', () {
    test('transforms events in order', () async {
      final fake = RecordingClient();
      final posthog = _client(fake, beforeSend: [
        (e) => e.copyWith(properties: {...e.properties, 'a': 1}),
        (e) => e.copyWith(event: '${e.event}_renamed'),
      ]);
      posthog.capture(distinctId: 'u', event: 'e');
      await posthog.flush();
      final event = fake.events.single;
      expect(event['event'], 'e_renamed');
      expect((event['properties']! as Map)['a'], 1);
    });

    test('drops an event when a hook returns null', () async {
      final fake = RecordingClient();
      final posthog = _client(fake, beforeSend: [(e) => null]);
      posthog.capture(distinctId: 'u', event: 'e');
      await posthog.flush();
      expect(fake.requests, isEmpty);
    });
  });

  group('batching', () {
    test('flushes in the background once flushAt events are queued', () async {
      final fake = RecordingClient();
      final posthog = _client(fake, flushAt: 2);
      posthog.capture(distinctId: 'u', event: 'a');
      expect(fake.requests, isEmpty);
      posthog.capture(distinctId: 'u', event: 'b');
      await pumpEventQueue();
      expect(fake.batches.single.batch, hasLength(2));
      expect(posthog.queueLength, 0);
    });

    test('flushes after flushInterval', () async {
      final fake = RecordingClient();
      final posthog = _client(
        fake,
        flushInterval: const Duration(milliseconds: 20),
      );
      posthog.capture(distinctId: 'u', event: 'a');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(fake.events, hasLength(1));
    });

    test('splits the queue into batches of maxBatchSize', () async {
      final fake = RecordingClient();
      final posthog = _client(fake, flushAt: 2, maxBatchSize: 2);
      for (var i = 0; i < 5; i++) {
        posthog.capture(distinctId: 'u', event: 'e$i');
      }
      await posthog.flush();
      expect(fake.batches.map((b) => b.batch.length), [2, 2, 1]);
      expect(posthog.queueLength, 0);
    });

    test('drops the oldest event once maxQueueSize is reached', () async {
      final fake = RecordingClient();
      final posthog = _client(fake, flushAt: 2, maxQueueSize: 3);
      for (var i = 0; i < 5; i++) {
        posthog.capture(distinctId: 'u', event: 'e$i');
      }
      await posthog.flush();
      expect(fake.events.map((e) => e['event']), ['e2', 'e3', 'e4']);
      expect(posthog.queueLength, 0);
    });

    test('halves the batch on 413 and resends', () async {
      final fake = RecordingClient(
        responder: (request, attempt) async =>
            attempt == 1 ? _status(413) : null,
      );
      final posthog = _client(fake, flushAt: 1000, maxBatchSize: 4);
      for (var i = 0; i < 4; i++) {
        posthog.capture(distinctId: 'u', event: 'e$i');
      }
      await posthog.flush();
      expect(fake.batches.map((b) => b.batch.length), [4, 2, 2]);
      expect(posthog.queueLength, 0);
    });

    test('flush waits for a capture that is evaluating feature flags',
        () async {
      final release = Completer<void>();
      final fake = RecordingClient(
        flagsResponse: {'flags': <String, Object?>{}},
        responder: (request, attempt) async {
          if (request.url.path.startsWith('/flags')) await release.future;
          return null;
        },
      );
      final posthog = _client(fake);
      posthog.capture(distinctId: 'u', event: 'e', sendFeatureFlags: true);
      final flushed = posthog.flush();
      await pumpEventQueue();
      expect(fake.batches, isEmpty);
      release.complete();
      await flushed;
      expect(fake.events.single['event'], 'e');
    });

    test('concurrent flushes send each event once', () async {
      final fake = RecordingClient();
      final posthog = _client(fake);
      posthog.capture(distinctId: 'u', event: 'a');
      await Future.wait([posthog.flush(), posthog.flush(), posthog.flush()]);
      expect(fake.events, hasLength(1));
    });
  });

  group('retries', () {
    test('retries 5xx then succeeds', () async {
      final fake = RecordingClient(
        responder: (request, attempt) async =>
            attempt < 3 ? _status(503) : null,
      );
      final posthog = _client(fake);
      posthog.capture(distinctId: 'u', event: 'e');
      await posthog.flush();
      expect(fake.requests, hasLength(3));
      expect(posthog.queueLength, 0);
    });

    test('retries 429 and 408', () async {
      final fake = RecordingClient(
        responder: (request, attempt) async => switch (attempt) {
          1 => _status(429),
          2 => _status(408),
          _ => null,
        },
      );
      final posthog = _client(fake);
      posthog.capture(distinctId: 'u', event: 'e');
      await posthog.flush();
      expect(fake.requests, hasLength(3));
    });

    test('gives up after fetchRetryCount and keeps no rejected batch',
        () async {
      final fake =
          RecordingClient(responder: (request, attempt) async => _status(500));
      final posthog = _client(fake, fetchRetryCount: 2);
      posthog.capture(distinctId: 'u', event: 'e');
      await expectLater(
        posthog.flush(),
        throwsA(isA<PostHogHttpException>()
            .having((e) => e.statusCode, 'statusCode', 500)),
      );
      expect(fake.requests, hasLength(3));
      expect(posthog.queueLength, 0);
    });

    test('does not retry other 4xx', () async {
      final fake =
          RecordingClient(responder: (request, attempt) async => _status(400));
      final posthog = _client(fake);
      posthog.capture(distinctId: 'u', event: 'e');
      await expectLater(posthog.flush(), throwsA(isA<PostHogHttpException>()));
      expect(fake.requests, hasLength(1));
    });

    test('keeps events queued after a network error', () async {
      final fake = RecordingClient(
        responder: (request, attempt) async =>
            throw http.ClientException('connection reset'),
      );
      final posthog = _client(fake, fetchRetryCount: 1);
      posthog.capture(distinctId: 'u', event: 'e');
      await expectLater(
        posthog.flush(),
        throwsA(isA<PostHogNetworkException>()),
      );
      expect(fake.requests, hasLength(2));
      expect(posthog.queueLength, 1);
    });

    test('a request past requestTimeout is a network error', () async {
      final fake = RecordingClient(responder: (request, attempt) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return null;
      });
      final posthog = _client(
        fake,
        fetchRetryCount: 0,
        requestTimeout: const Duration(milliseconds: 20),
      );
      await expectLater(
        posthog.captureImmediate(distinctId: 'u', event: 'e'),
        throwsA(isA<PostHogNetworkException>()
            .having((e) => e.cause, 'cause', isA<TimeoutException>())),
      );
    });

    test('background flush failures go to onError, never the zone', () async {
      final errors = <Object>[];
      final fake =
          RecordingClient(responder: (request, attempt) async => _status(400));
      final posthog = _client(
        fake,
        flushAt: 1,
        onError: (error, stackTrace) => errors.add(error),
      );
      posthog.capture(distinctId: 'u', event: 'e');
      await pumpEventQueue();
      expect(errors.single, isA<PostHogHttpException>());
    });
  });

  group('feature flags', () {
    test('a failed /flags/ call returns null and reports the error', () async {
      final errors = <Object>[];
      final fake =
          RecordingClient(responder: (request, attempt) async => _status(500));
      final posthog = _client(
        fake,
        onError: (error, stackTrace) => errors.add(error),
      );
      expect(
        await posthog.getFeatureFlag('f', 'u', sendFeatureFlagEvents: false),
        isNull,
      );
      expect(fake.requests, hasLength(1));
      expect(errors.single, isA<PostHogHttpException>());
    });

    test('quota limited flags evaluate to nothing', () async {
      final fake = RecordingClient(flagsResponse: {
        'flags': {
          'f': {'key': 'f', 'enabled': true},
        },
        'quotaLimited': ['feature_flags'],
      });
      final posthog = _client(fake);
      expect(await posthog.getAllFlags('u'), isEmpty);
      expect(
        await posthog.isFeatureEnabled('f', 'u', sendFeatureFlagEvents: false),
        isNull,
      );
    });

    test('reads the legacy v1 response shape', () async {
      final fake = RecordingClient(flagsResponse: {
        'featureFlags': {'a': true, 'b': 'blue', 'c': false},
        'featureFlagPayloads': {'b': '{"x":1}'},
      });
      final posthog = _client(fake);
      final all = await posthog.getAllFlagsAndPayloads('u');
      expect(all.featureFlags, {'a': true, 'b': 'blue', 'c': false});
      expect(all.featureFlagPayloads, {
        'b': {'x': 1},
      });
    });

    test('getFeatureFlagResult tells a missing payload from a missing flag',
        () async {
      final fake = RecordingClient(flagsResponse: {
        'flags': {
          'on': {'key': 'on', 'enabled': true, 'metadata': <String, Object?>{}},
          'raw': {
            'key': 'raw',
            'enabled': true,
            'metadata': {'payload': 'not json'},
          },
        },
      });
      final posthog = _client(fake);
      final on = await posthog.getFeatureFlagResult('on', 'u',
          sendFeatureFlagEvents: false);
      expect(on?.enabled, isTrue);
      expect(on?.payload, isNull);
      expect(
        await posthog.getFeatureFlagResult('off', 'u',
            sendFeatureFlagEvents: false),
        isNull,
      );
      expect(await posthog.getFeatureFlagPayload('raw', 'u'), 'not json');
    });
  });

  group('lifecycle', () {
    test('disabled turns every call into a no-op', () async {
      final fake = RecordingClient();
      final posthog = _client(fake, disabled: true);
      posthog.capture(distinctId: 'u', event: 'e');
      posthog.identify(distinctId: 'u');
      await posthog.captureImmediate(distinctId: 'u', event: 'e');
      expect(await posthog.getFeatureFlag('f', 'u'), isNull);
      await posthog.flush();
      await posthog.shutdown();
      expect(posthog.isDisabled, isTrue);
      expect(fake.requests, isEmpty);
    });

    test('shutdown sends the queue, then the client refuses new calls',
        () async {
      final fake = RecordingClient();
      final posthog = _client(fake);
      posthog.capture(distinctId: 'u', event: 'e');
      await posthog.shutdown();
      expect(fake.events, hasLength(1));
      expect(
        () => posthog.capture(distinctId: 'u', event: 'e'),
        throwsStateError,
      );
    });

    test('shutdown reports delivery errors to onError', () async {
      final errors = <Object>[];
      final fake =
          RecordingClient(responder: (request, attempt) async => _status(400));
      final posthog = _client(
        fake,
        onError: (error, stackTrace) => errors.add(error),
      );
      posthog.capture(distinctId: 'u', event: 'e');
      await posthog.shutdown();
      expect(errors.single, isA<PostHogHttpException>());
    });

    test('shutdown throws once its deadline passes', () async {
      final fake = RecordingClient(responder: (request, attempt) async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return null;
      });
      final posthog = _client(fake, onError: (error, stackTrace) {});
      posthog.capture(distinctId: 'u', event: 'e');
      await expectLater(
        posthog.shutdown(timeout: const Duration(milliseconds: 20)),
        throwsA(isA<PostHogShutdownTimeoutException>()
            .having((e) => e.unsentEvents, 'unsentEvents', 1)),
      );
    });
  });
}
