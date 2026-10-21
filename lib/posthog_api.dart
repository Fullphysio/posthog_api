/// A pure Dart server-side client for PostHog.
///
/// Capture events, identify users, alias ids and update groups through a
/// batched, retrying queue, and evaluate feature flags remotely. A port of
/// the official `posthog-node` SDK with no Flutter dependency.
library;

export 'src/event.dart';
export 'src/exceptions.dart';
export 'src/feature_flags.dart' show FeatureFlagResult, FeatureFlagsAndPayloads;
export 'src/posthog.dart';
export 'src/version.dart' show posthogApiVersion;
