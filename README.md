# posthog_api

[![pub package](https://img.shields.io/pub/v/posthog_api.svg)](https://pub.dev/packages/posthog_api)
[![CI](https://github.com/Fullphysio/posthog_api/actions/workflows/ci.yml/badge.svg)](https://github.com/Fullphysio/posthog_api/actions/workflows/ci.yml)

A pure Dart server-side client for [PostHog](https://posthog.com). Capture
events, identify users, alias ids and update groups through a batched,
retrying queue, and evaluate feature flags — from Dart servers, Cloud Run,
Cloud Functions and CLIs.

**No Flutter dependency.** The official Dart SDK, `posthog_flutter`, and the
other packages on pub.dev all depend on Flutter, which pub refuses to resolve
inside a plain Dart project. This is a port of the official Node.js SDK,
`posthog-node`, instead.

Built by [Fullphysio](https://www.fullphysio.com) for its Dart Cloud
Functions. Bug reports are welcome — see
[CONTRIBUTING.md](CONTRIBUTING.md).

```dart
import 'package:posthog_api/posthog_api.dart';

final posthog = PostHog(
  'phc_...',
  host: Uri.parse('https://eu.i.posthog.com'),
);

posthog.capture(
  distinctId: 'user-123',
  event: 'program_created',
  properties: {
    'exercises': 6,
    r'$set': {'plan': 'pro'},
    r'$set_once': {'first_program_at': '2026-10-21'},
  },
  groups: {'company': 'acme'},
);

posthog.identify(distinctId: 'user-123', properties: {'email': 'ada@example.com'});
posthog.alias(distinctId: 'user-123', alias: 'legacy-42');
posthog.groupIdentify(groupType: 'company', groupKey: 'acme', properties: {'seats': 12});

await posthog.flush();
```

## On servers and serverless

`capture`, `identify`, `alias` and `groupIdentify` only queue. The queue is
sent in the background once `flushAt` events (default 20) are waiting, or
`flushInterval` (default 10 s) after the first one.

On Cloud Run and Cloud Functions the CPU can be throttled as soon as a request
returns, so **`await posthog.flush()` before returning**. `flush()` also waits
for captures still evaluating `sendFeatureFlags`. Give it a timeout so a
PostHog outage cannot hold the request open; unsent events stay queued for the
next flush:

```dart
await posthog.flush(timeout: const Duration(seconds: 5));
``` Create one client per
process and reuse it across requests:

```dart
PostHog? _posthog;
PostHog posthog() => _posthog ??= PostHog(apiKey, host: Uri.parse('https://eu.i.posthog.com'));
```

Call `shutdown()` once before the process exits. A CLI that skips it lingers
until the flush timer fires.

`captureImmediate`, `identifyImmediate` and `aliasImmediate` send one event in
one request and complete once PostHog has accepted it.

## Feature flags

Flags are evaluated remotely through `/flags/`:

```dart
final variant = await posthog.getFeatureFlag('pricing-test', 'user-123');
final enabled = await posthog.isFeatureEnabled('new-editor', 'user-123',
    personProperties: {'plan': 'pro'});
final payload = await posthog.getFeatureFlagPayload('pricing-test', 'user-123');
final all = await posthog.getAllFlags('user-123');

posthog.capture(distinctId: 'user-123', event: 'checkout', sendFeatureFlags: true);
```

`getFeatureFlag` sends a `$feature_flag_called` event once per user and value,
as `posthog-node` does; pass `sendFeatureFlagEvents: false` to skip it.

## LLM analytics

LLM analytics events are ordinary captures:

```dart
posthog.capture(
  distinctId: userId,
  event: r'$ai_generation',
  properties: {
    r'$ai_trace_id': traceId,
    r'$ai_provider': 'anthropic',
    r'$ai_model': model,
    r'$ai_input_tokens': usage.inputTokens,
    r'$ai_output_tokens': usage.outputTokens,
    r'$ai_latency': latency.inMilliseconds / 1000,
  },
);
```

## Errors

| Exception | When |
|---|---|
| `PostHogHttpException` | PostHog answered outside `200..399` |
| `PostHogNetworkException` | no response: DNS, refused or reset connection, timeout |
| `PostHogTimeoutException` | `flush(timeout:)` or `shutdown()` deadline passed with events still queued |

`flush()` and the `*Immediate` methods throw them once retries are exhausted.
Nothing else throws for delivery problems: background flushes, flag requests
and the flush inside `shutdown()` report to `onError`, which prints by default.
Flag methods return `null` when PostHog cannot be reached.

`capture` never throws over its input either. A property that cannot be
encoded as JSON (a `double.nan`, an object without `toJson`) or a `beforeSend`
hook that throws drops that one event and reports the error to `onError`.
`DateTime` properties are sent as ISO-8601 strings, as in `posthog-node`.

After a network error the unsent events stay queued for the next flush. After
an HTTP error the rejected batch is dropped, since resending it would fail the
same way.

PostHog's `/batch/` endpoint answers `200` to an unknown project key and drops
the events later, so a wrong key never fails a capture. A flag call does fail
with `401`, which makes `isFeatureEnabled` a cheap startup check.

## Scope

Covered: capture (with `$set` / `$set_once`, groups, custom timestamp and
uuid), identify, alias, group identify, the `*Immediate` variants, batching via
`/batch/` with gzip, retries, `413` batch halving, `beforeSend` hooks,
`flush()` / `shutdown()`, and remote feature flag evaluation with
`$feature_flag_called` events.

Not covered: historical migration batches, local flag evaluation (polling definitions with a personal API
key), flag overrides, `captureException` / error tracking, encrypted remote
config payloads, super properties (`register`), and request context
(`withContext`). Open an issue if you need one of these.

## Relationship to posthog-node

This is a Dart port of `posthog-node` 5.29.2. Event payloads, `$identify`
property handling, batching, `413` halving, shutdown, and flag requests and
`$feature_flag_called` events follow that implementation, and the test suite
replays scenarios captured from the real SDK and compares every request body
(bar uuids, timestamps and the library name). See
`THIRD_PARTY_NOTICES`.

Deliberate differences:

- **Only transient failures are retried.** `posthog-node` retries every
  failed request, including a `400`. This package retries network errors,
  `408`, `429` and `5xx`, with the same fixed `fetchRetryDelay`.
- **`captureImmediate`, `identifyImmediate` and `aliasImmediate` throw** on
  failure; `posthog-node` reports the error and resolves.
- **`flush()` waits for captures still evaluating `sendFeatureFlags`**, so a
  serverless handler never returns with an event still in flight.
- **Calls after `shutdown()` throw a `StateError`**, since the HTTP client has
  been released.
- **Events identify this package**: `$lib` is `posthog_api`, not
  `posthog-node`.
