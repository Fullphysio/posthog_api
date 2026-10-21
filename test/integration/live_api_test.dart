@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:posthog_api/posthog_api.dart';
import 'package:test/test.dart';

/// Sends real events to a PostHog project and evaluates real flags.
///
/// Reads the project key from `POSTHOG_TEST_API_KEY` and the host from
/// `POSTHOG_TEST_HOST` (default `https://eu.i.posthog.com`), and skips itself
/// when the key is unset. CI points it at a dedicated project holding the
/// flags listed in [Flags]; a project without them fails the flag group.
void main() {
  final apiKey = Platform.environment['POSTHOG_TEST_API_KEY'] ?? '';
  final hostValue = Platform.environment['POSTHOG_TEST_HOST'] ?? '';
  final host = Uri.parse(
    hostValue.isEmpty ? 'https://eu.i.posthog.com' : hostValue,
  );

  if (apiKey.isEmpty) {
    test('live API', () {}, skip: 'POSTHOG_TEST_API_KEY not set');
    return;
  }

  const distinctId = 'posthog_api-integration-test';
  late _TeeClient tee;
  late List<Object> errors;
  late PostHog posthog;

  setUp(() {
    tee = _TeeClient();
    errors = [];
    posthog = PostHog(
      apiKey,
      host: host,
      flushInterval: Duration.zero,
      httpClient: tee,
      onError: (error, stackTrace) => errors.add(error),
    );
  });

  tearDown(() async {
    await posthog.shutdown();
    tee.close();
  });

  group('ingestion', () {
    test('captureImmediate is accepted', () async {
      await posthog.captureImmediate(
        distinctId: distinctId,
        event: 'posthog_api integration',
        properties: {'run': DateTime.now().toIso8601String()},
      );
    });

    test('a gzipped batch of every event type is accepted', () async {
      posthog
        ..capture(
          distinctId: distinctId,
          event: r'$set',
          properties: {
            r'$set': {'integration': true},
          },
        )
        ..capture(event: 'posthog_api personless', properties: {'n': 1})
        ..identify(distinctId: distinctId, properties: {'plan': 'test'})
        ..alias(distinctId: distinctId, alias: '$distinctId-alias')
        ..groupIdentify(
          groupType: 'company',
          groupKey: 'posthog_api',
          properties: {'integration': true},
        );
      await posthog.flush();
      expect(posthog.queueLength, 0);
      expect(tee.requests.single.headers['Content-Encoding'], 'gzip');
      expect(tee.requests.single.events, hasLength(5));
    });

    test('an uncompressed batch is accepted', () async {
      final client = PostHog(
        apiKey,
        host: host,
        flushInterval: Duration.zero,
        disableCompression: true,
      );
      client.capture(
        distinctId: distinctId,
        event: 'posthog_api uncompressed',
        properties: {'at': DateTime.now()},
      );
      await client.shutdown();
      expect(client.queueLength, 0);
    });

    test('an event PostHog rejects throws a 400 without retrying', () async {
      posthog.capture(distinctId: distinctId, event: '');
      await expectLater(
        posthog.flush(),
        throwsA(isA<PostHogHttpException>()
            .having((e) => e.statusCode, 'statusCode', 400)),
      );
      expect(tee.requests, hasLength(1));
      expect(posthog.queueLength, 0);
    });

    test('an unknown project key is accepted by /batch/ but not by /flags/',
        () async {
      final client = PostHog(
        'phc_posthogApiIntegrationTestUnknownKey000000000',
        host: host,
        onError: (error, stackTrace) => errors.add(error),
      );
      await client.captureImmediate(distinctId: distinctId, event: 'ignored');
      expect(
        await client.getFeatureFlag(Flags.boolean, distinctId,
            sendFeatureFlagEvents: false),
        isNull,
      );
      await client.shutdown();
      expect(
        errors.single,
        isA<PostHogHttpException>()
            .having((e) => e.statusCode, 'statusCode', 401),
      );
      errors.clear();
    });
  });

  group('feature flags', () {
    tearDown(() => expect(errors, isEmpty));

    test('a boolean flag and its payload', () async {
      final result = await posthog.getFeatureFlagResult(
        Flags.boolean,
        distinctId,
        sendFeatureFlagEvents: false,
      );
      expect(result?.enabled, isTrue);
      expect(result?.variant, isNull);
      expect(result?.payload, {'discount': 10});
      expect(
        await posthog.isFeatureEnabled(Flags.boolean, distinctId,
            sendFeatureFlagEvents: false),
        isTrue,
      );
    });

    test('a multivariate flag and its payload', () async {
      expect(
        await posthog.getFeatureFlag(Flags.multivariate, distinctId,
            sendFeatureFlagEvents: false),
        'variant-b',
      );
      expect(
        await posthog.getFeatureFlagPayload(Flags.multivariate, distinctId),
        {'color': 'blue'},
      );
    });

    test('person properties passed in the call are evaluated', () async {
      Future<Object?> withTier(String tier) => posthog.getFeatureFlag(
            Flags.personProperty,
            distinctId,
            personProperties: {'posthog_api_tier': tier},
            sendFeatureFlagEvents: false,
          );
      expect(await withTier('gold'), isTrue);
      expect(await withTier('silver'), isFalse);
    });

    test('groups and group properties are evaluated', () async {
      Future<Object?> withPlan(String plan) => posthog.getFeatureFlag(
            Flags.company,
            distinctId,
            groups: {'company': 'posthog_api-acme'},
            groupProperties: {
              'company': {'plan': plan},
            },
            sendFeatureFlagEvents: false,
          );
      expect(await withPlan('enterprise'), isTrue);
      expect(await withPlan('free'), isFalse);
    });

    test('an inactive or unknown flag evaluates to null', () async {
      for (final key in [Flags.inactive, 'posthog-api-does-not-exist']) {
        expect(
          await posthog.getFeatureFlag(key, distinctId,
              sendFeatureFlagEvents: false),
          isNull,
          reason: key,
        );
      }
    });

    test('getAllFlagsAndPayloads returns every active flag', () async {
      final all = await posthog.getAllFlagsAndPayloads(distinctId);
      expect(all.featureFlags, {
        Flags.boolean: true,
        Flags.multivariate: 'variant-b',
        Flags.personProperty: false,
        Flags.company: false,
      });
      expect(all.featureFlagPayloads, {
        Flags.boolean: {'discount': 10},
        Flags.multivariate: {'color': 'blue'},
      });
      expect(
        await posthog.getAllFlags(distinctId, flagKeys: [Flags.boolean]),
        {Flags.boolean: true},
      );
    });

    test('getFeatureFlag reports \$feature_flag_called once', () async {
      await posthog.getFeatureFlag(Flags.multivariate, distinctId);
      await posthog.getFeatureFlag(Flags.multivariate, distinctId);
      await posthog.flush();

      final called = tee.events
          .where((e) => e['event'] == r'$feature_flag_called')
          .toList();
      expect(called, hasLength(1));
      final properties = called.single['properties']! as Map;
      expect(properties[r'$feature_flag'], Flags.multivariate);
      expect(properties[r'$feature_flag_response'], 'variant-b');
      expect(properties[r'$feature_flag_id'], isA<int>());
      expect(properties[r'$feature_flag_version'], isA<int>());
      expect(properties[r'$feature_flag_request_id'], isA<String>());
      expect(properties, isNot(contains(r'$feature_flag_error')));
    });

    test('sendFeatureFlags attaches the evaluated flags to the event',
        () async {
      posthog.capture(
        distinctId: distinctId,
        event: 'posthog_api with flags',
        sendFeatureFlags: true,
      );
      await posthog.flush();

      final properties = tee.events.single['properties']! as Map;
      expect(properties['\$feature/${Flags.boolean}'], isTrue);
      expect(properties['\$feature/${Flags.multivariate}'], 'variant-b');
      expect(properties['\$feature/${Flags.personProperty}'], isFalse);
      expect(
        properties[r'$active_feature_flags'],
        [Flags.boolean, Flags.multivariate],
      );
    });
  });
}

/// Flags that must exist in the test project, as created for the
/// "posthog_api CI" project on PostHog EU.
abstract final class Flags {
  /// Active, 100% rollout, payload `{"discount":10}`.
  static const boolean = 'posthog-api-boolean';

  /// Active, variants `control` 0% and `variant-b` 100%, payload
  /// `{"color":"blue"}` on `variant-b`.
  static const multivariate = 'posthog-api-multivariate';

  /// Active, on when the person property `posthog_api_tier` is `gold`.
  static const personProperty = 'posthog-api-person-property';

  /// Active, aggregated by the `company` group type, on when the group
  /// property `plan` is `enterprise`.
  static const company = 'posthog-api-company';

  /// Inactive, 100% rollout.
  static const inactive = 'posthog-api-inactive';
}

class _SentRequest {
  _SentRequest(this.headers, this.json);

  final Map<String, String> headers;
  final Map<String, Object?> json;

  List<Map<String, Object?>> get events =>
      (json['batch'] as List<Object?>? ?? const [])
          .cast<Map<String, Object?>>();
}

class _TeeClient extends http.BaseClient {
  final http.Client _inner = http.Client();
  final List<_SentRequest> requests = [];

  List<Map<String, Object?>> get events =>
      [for (final r in requests) ...r.events];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request is http.Request && request.url.path == '/batch/') {
      final bytes = request.headers['Content-Encoding'] == 'gzip'
          ? gzip.decode(request.bodyBytes)
          : request.bodyBytes;
      requests.add(_SentRequest(
        Map.of(request.headers),
        jsonDecode(utf8.decode(bytes)) as Map<String, Object?>,
      ));
    }
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
