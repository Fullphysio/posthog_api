import 'posthog.dart';

/// Base class of every error this package throws or reports.
sealed class PostHogException implements Exception {
  const PostHogException(this.message);

  /// A human-readable description of the failure.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// PostHog answered with a status outside `200..399`.
final class PostHogHttpException extends PostHogException {
  /// Creates an exception for a response with [statusCode] and [body].
  PostHogHttpException({
    required this.statusCode,
    required this.body,
    required this.requestByteLength,
  }) : super(
          'HTTP error while fetching PostHog: status=$statusCode, '
          'reqByteLength=$requestByteLength, body=${_truncate(body)}',
        );

  /// The HTTP status code PostHog returned.
  final int statusCode;

  /// The raw response body, often a JSON error description.
  final String body;

  /// The size in bytes of the request body that was rejected.
  final int requestByteLength;
}

/// No response was received: DNS failure, refused connection, reset, or the
/// request timed out.
final class PostHogNetworkException extends PostHogException {
  /// Creates an exception wrapping the underlying [cause].
  PostHogNetworkException(this.cause)
      : super('Network error while fetching PostHog: $cause');

  /// The error raised by the HTTP client, or a `TimeoutException`.
  final Object cause;
}

/// [PostHog.flush] or [PostHog.shutdown] did not finish sending queued
/// events within its `timeout`. The events stay queued.
final class PostHogTimeoutException extends PostHogException {
  /// Creates the exception, recording how many events were left unsent.
  const PostHogTimeoutException(this.unsentEvents)
      : super(
          'Timeout while sending events to PostHog. '
          '$unsentEvents event(s) may not have been sent.',
        );

  /// The number of events still queued when the deadline passed.
  final int unsentEvents;
}

String _truncate(String body) =>
    body.length <= 200 ? body : '${body.substring(0, 200)}…';
