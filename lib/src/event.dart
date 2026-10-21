import 'posthog.dart';

/// An event about to be queued by [PostHog.capture], as handed to a
/// [BeforeSend] hook.
final class PostHogEvent {
  /// Creates an event.
  const PostHogEvent({
    required this.distinctId,
    required this.event,
    this.properties = const {},
    this.groups,
    this.timestamp,
    this.uuid,
    this.disableGeoip,
  });

  /// The user or entity the event belongs to.
  final String distinctId;

  /// The event name, e.g. `user_signed_up` or `$ai_generation`.
  final String event;

  /// Event properties, including `$set` / `$set_once` person updates.
  final Map<String, Object?> properties;

  /// Group type to group key, sent as `$groups`.
  final Map<String, Object>? groups;

  /// When the event happened. Defaults to the time it is queued.
  final DateTime? timestamp;

  /// A caller-chosen event id. Defaults to a fresh UUIDv7; PostHog
  /// deduplicates events that share one.
  final String? uuid;

  /// Overrides the client's `disableGeoip` setting for this event.
  final bool? disableGeoip;

  /// Returns a copy with the given fields replaced.
  PostHogEvent copyWith({
    String? distinctId,
    String? event,
    Map<String, Object?>? properties,
    Map<String, Object>? groups,
    DateTime? timestamp,
    String? uuid,
    bool? disableGeoip,
  }) =>
      PostHogEvent(
        distinctId: distinctId ?? this.distinctId,
        event: event ?? this.event,
        properties: properties ?? this.properties,
        groups: groups ?? this.groups,
        timestamp: timestamp ?? this.timestamp,
        uuid: uuid ?? this.uuid,
        disableGeoip: disableGeoip ?? this.disableGeoip,
      );
}

/// Transforms an event before it is queued, or drops it by returning `null`.
///
/// Runs for [PostHog.capture] and [PostHog.captureImmediate] only, as in
/// `posthog-node`. Typical uses are scrubbing personal data and sampling.
typedef BeforeSend = PostHogEvent? Function(PostHogEvent event);

/// Receives errors that cannot be thrown to a caller: background flushes,
/// feature flag requests, and the final flush in [PostHog.shutdown].
typedef PostHogErrorHandler = void Function(
    Object error, StackTrace stackTrace);
