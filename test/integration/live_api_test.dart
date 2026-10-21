@Tags(['integration'])
library;

import 'dart:io';

import 'package:posthog_api/posthog_api.dart';
import 'package:test/test.dart';

/// Sends real events to a PostHog project and evaluates flags against it.
///
/// Reads the project key from `POSTHOG_TEST_API_KEY` and the host from
/// `POSTHOG_TEST_HOST` (default `https://eu.i.posthog.com`), and skips itself
/// when the key is unset. A project key can only write events and read flags,
/// so it is not a secret. Assertions are structural: PostHog accepted the
/// request and answered in the documented shape.
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
  late PostHog posthog;

  setUp(() {
    posthog = PostHog(apiKey, host: host, flushInterval: Duration.zero);
  });

  tearDown(() => posthog.shutdown());

  test('captureImmediate is accepted', () async {
    await posthog.captureImmediate(
      distinctId: distinctId,
      event: 'posthog_api integration',
      properties: {'run': DateTime.now().toIso8601String()},
    );
  });

  test('a batch of every event type is accepted', () async {
    posthog
      ..capture(
        distinctId: distinctId,
        event: r'$set',
        properties: {
          r'$set': {'integration': true},
        },
      )
      ..identify(distinctId: distinctId, properties: {'plan': 'test'})
      ..alias(distinctId: distinctId, alias: '$distinctId-alias')
      ..groupIdentify(
        groupType: 'company',
        groupKey: 'posthog_api',
        properties: {'integration': true},
      );
    await posthog.flush();
    expect(posthog.queueLength, 0);
  });

  test('evaluates flags remotely', () async {
    final errors = <Object>[];
    final client = PostHog(
      apiKey,
      host: host,
      onError: (error, stackTrace) => errors.add(error),
    );
    final flags = await client.getAllFlagsAndPayloads(distinctId);
    expect(flags.featureFlags.values,
        everyElement(anyOf(isA<bool>(), isA<String>())));
    expect(
      await client.getFeatureFlag(
        'posthog-api-flag-that-does-not-exist',
        distinctId,
        sendFeatureFlagEvents: false,
      ),
      isNull,
    );
    await client.shutdown();
    expect(errors, isEmpty);
  });
}
