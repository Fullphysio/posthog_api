import 'posthog.dart';

/// The evaluation of one feature flag for one user.
final class FeatureFlagResult {
  /// Creates a result for flag [key].
  const FeatureFlagResult({
    required this.key,
    required this.enabled,
    this.variant,
    this.payload,
  });

  /// The flag key.
  final String key;

  /// Whether the flag is on for this user.
  final bool enabled;

  /// The multivariate variant, or `null` for a boolean flag.
  final String? variant;

  /// The decoded JSON payload attached to the matched value, or `null` when
  /// none is configured. A payload that is not valid JSON is returned as the
  /// raw string.
  final Object? payload;

  /// The flag's value as `posthog-node` reports it: `false` when disabled,
  /// otherwise the [variant], otherwise `true`.
  Object get value => enabled ? (variant ?? true) : false;

  @override
  String toString() =>
      'FeatureFlagResult(key: $key, enabled: $enabled, variant: $variant, '
      'payload: $payload)';
}

/// Every flag value and payload for one user, as returned by
/// [PostHog.getAllFlagsAndPayloads].
final class PostHogFlagsAndPayloads {
  /// Creates the pair of maps.
  const PostHogFlagsAndPayloads({
    required this.featureFlags,
    required this.featureFlagPayloads,
  });

  /// Flag key to value: `true`, `false` or a variant `String`.
  final Map<String, Object> featureFlags;

  /// Flag key to decoded payload, for enabled flags that have one.
  final Map<String, Object?> featureFlagPayloads;
}
