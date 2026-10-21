import 'dart:convert';
import 'dart:io';

import 'package:posthog_api/posthog_api.dart';
import 'package:test/test.dart';

import '_support/recording_client.dart';

/// Replays every scenario of `test/fixtures/requests_golden.json`, captured
/// from the real `posthog-node`, and checks the requests sent are identical.
void main() {
  final golden = jsonDecode(
    File('test/fixtures/requests_golden.json').readAsStringSync(),
  ) as Map<String, Object?>;
  final flagsResponse = golden['flagsResponse']! as Map<String, Object?>;
  final cases = {
    for (final c
        in (golden['cases']! as List<Object?>).cast<Map<String, Object?>>())
      c['name']! as String: c['requests']! as List<Object?>,
  };

  final scenarios = <String, Future<void> Function(PostHog)>{
    'capture_with_set_and_groups': (ph) async => ph.capture(
          distinctId: 'user-1',
          event: 'program_created',
          properties: {
            r'$set': {'plan': 'pro'},
            r'$set_once': {'first_seen': '2026-01-01'},
            'exercises': 3,
          },
          groups: {'company': 'acme'},
        ),
    'capture_set_event': (ph) async => ph.capture(
          distinctId: 'user-1',
          event: r'$set',
          properties: {
            r'$set': {'name': 'Ada', 'isPatient': false},
          },
        ),
    'capture_with_geoip_enabled': (ph) async =>
        ph.capture(distinctId: 'user-1', event: 'opened', disableGeoip: false),
    'capture_without_distinct_id': (ph) async =>
        ph.capture(event: 'cron_ran', properties: {'jobs': 2}),
    'ai_generation': (ph) async => ph.capture(
          distinctId: 'user-1',
          event: r'$ai_generation',
          properties: {
            r'$ai_trace_id': 'trace-1',
            r'$ai_provider': 'anthropic',
            r'$ai_model': 'claude-sonnet-5-5',
            r'$ai_input_tokens': 120,
            r'$ai_output_tokens': 40,
            r'$ai_latency': 1.25,
            r'$ai_input': [
              {'role': 'user', 'content': 'hi'},
            ],
          },
        ),
    'identify_plain_properties': (ph) async => ph.identify(
          distinctId: 'user-1',
          properties: {
            'email': 'ada@example.com',
            r'$set_once': {'signup': 'web'},
          },
        ),
    'identify_explicit_set': (ph) async => ph.identify(
          distinctId: 'user-1',
          properties: {
            r'$set': {'plan': 'pro'},
            'ignored': true,
            r'$anon_distinct_id': 'anon-9',
          },
        ),
    'alias': (ph) async => ph.alias(distinctId: 'user-1', alias: 'legacy-42'),
    'group_identify': (ph) async => ph.groupIdentify(
          groupType: 'company',
          groupKey: 'acme',
          properties: {'seats': 12},
        ),
    'group_identify_with_distinct_id': (ph) async => ph.groupIdentify(
          groupType: 'company',
          groupKey: 'acme',
          distinctId: 'user-1',
        ),
    'capture_immediate': (ph) => ph.captureImmediate(
          distinctId: 'user-1',
          event: 'paid',
          properties: {'amount': 30},
        ),
    'two_events_one_batch': (ph) async {
      ph.capture(distinctId: 'user-1', event: 'a');
      ph.capture(distinctId: 'user-2', event: 'b');
    },
    'get_feature_flag_variant': (ph) async {
      final value = await ph.getFeatureFlag(
        'pricing-test',
        'user-1',
        groups: {'company': 'acme'},
        personProperties: {'plan': 'pro'},
        groupProperties: {
          'company': {'seats': '12'},
        },
      );
      expect(value, 'variant-b');
    },
    'get_feature_flag_disabled': (ph) async =>
        expect(await ph.getFeatureFlag('disabled-flag', 'user-1'), isFalse),
    'get_feature_flag_missing': (ph) async =>
        expect(await ph.getFeatureFlag('nope', 'user-1'), isNull),
    'get_feature_flag_called_once': (ph) async {
      await ph.getFeatureFlag('beta-feature', 'user-1');
      await ph.getFeatureFlag('beta-feature', 'user-1');
    },
    'get_feature_flag_payload': (ph) async => expect(
          await ph.getFeatureFlagPayload('beta-feature', 'user-1'),
          {'discount': 10},
        ),
    'get_all_flags_and_payloads': (ph) async {
      final all = await ph.getAllFlagsAndPayloads(
        'user-1',
        flagKeys: ['beta-feature', 'pricing-test'],
      );
      expect(all.featureFlags['pricing-test'], 'variant-b');
    },
    'capture_with_send_feature_flags': (ph) async => ph.capture(
          distinctId: 'user-1',
          event: 'checkout',
          sendFeatureFlags: true,
        ),
  };

  test('every captured scenario is replayed', () {
    expect(scenarios.keys.toSet(), cases.keys.toSet());
  });

  for (final MapEntry(key: name, value: run) in scenarios.entries) {
    test(name, () async {
      final fake = RecordingClient(flagsResponse: flagsResponse);
      final posthog = PostHog(
        'phc_test',
        host: Uri.parse('https://eu.i.posthog.com'),
        httpClient: fake.client,
        flushAt: 100,
        flushInterval: Duration.zero,
        disableCompression: true,
      );
      await run(posthog);
      await posthog.flush();
      await posthog.shutdown();

      final actual = [
        for (final r in fake.requests)
          {
            'path': r.pathAndQuery,
            'method': r.request.method,
            'contentType': r.request.headers['Content-Type'],
            'body': normalise(r.json),
          },
      ];
      expect(actual, cases[name]);
    });
  }
}
