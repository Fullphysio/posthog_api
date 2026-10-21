import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'event.dart';
import 'exceptions.dart';
import 'feature_flags.dart';
import 'platform.dart';
import 'version.dart';

part 'flags_response.dart';
part 'uuid_v7.dart';

/// A server-side PostHog client: captures events into an in-memory queue and
/// sends them to `/batch/` in the background, and evaluates feature flags
/// through `/flags/`.
///
/// Create one per process and reuse it. On serverless runtimes (Cloud Run,
/// Cloud Functions) the CPU may be throttled once a request returns, so
/// `await` [flush] before returning:
///
/// ```dart
/// final posthog = PostHog('phc_...', host: Uri.parse('https://eu.i.posthog.com'));
///
/// posthog.capture(distinctId: 'user-1', event: 'program_created');
/// await posthog.flush();
/// ```
///
/// Call [shutdown] once before the process exits.
class PostHog {
  /// Creates a client for the project identified by [apiKey] (`phc_...`).
  ///
  /// - [host]: the ingestion host, e.g. `https://eu.i.posthog.com` or a
  ///   reverse proxy. Defaults to `https://us.i.posthog.com`.
  /// - [flushAt]: queue length that triggers a background flush.
  /// - [flushInterval]: delay after the first queued event before a background
  ///   flush. [Duration.zero] disables the timer.
  /// - [maxBatchSize]: events per `/batch/` request. Halved automatically when
  ///   PostHog answers `413 Payload Too Large`.
  /// - [maxQueueSize]: once reached, the oldest event is dropped.
  /// - [requestTimeout]: per-attempt deadline for `/batch/` requests.
  /// - [featureFlagsRequestTimeout]: deadline for `/flags/` requests, which
  ///   are never retried.
  /// - [fetchRetryCount] and [fetchRetryDelay]: retries for network errors and
  ///   `408`, `429` and `5xx` responses, with a fixed delay between attempts.
  /// - [disableGeoip]: adds `$geoip_disable: true` to events and skips GeoIP in
  ///   flag evaluation, so the server's IP is not mistaken for the user's.
  /// - [disabled]: turns every call into a no-op, e.g. in tests or emulators.
  /// - [disableCompression]: sends `/batch/` bodies uncompressed. Bodies are
  ///   gzipped by default on platforms with `dart:io`.
  /// - [sendFeatureFlagEvents]: default for the same parameter on
  ///   [getFeatureFlag] and friends.
  /// - [beforeSend]: hooks applied in order to every captured event. A hook
  ///   that throws drops the event and reports the error to [onError].
  /// - [onError]: receives errors that have no caller to be thrown to.
  ///   Defaults to printing them. If it throws, the error goes to the
  ///   current zone's uncaught-error handler.
  /// - [httpClient]: a client to reuse. When omitted the client creates one
  ///   and closes it in [shutdown].
  PostHog(
    String apiKey, {
    Uri? host,
    int flushAt = 20,
    Duration flushInterval = const Duration(seconds: 10),
    int maxBatchSize = 100,
    int maxQueueSize = 1000,
    Duration requestTimeout = const Duration(seconds: 10),
    Duration featureFlagsRequestTimeout = const Duration(seconds: 3),
    int fetchRetryCount = 3,
    Duration fetchRetryDelay = const Duration(seconds: 3),
    bool disableGeoip = true,
    bool disabled = false,
    bool disableCompression = false,
    bool sendFeatureFlagEvents = true,
    List<BeforeSend> beforeSend = const [],
    PostHogErrorHandler? onError,
    http.Client? httpClient,
  })  : _apiKey = _requireApiKey(apiKey),
        host = Uri.parse(
          (host?.toString() ?? 'https://us.i.posthog.com')
              .replaceFirst(RegExp(r'/+$'), ''),
        ),
        _flushAt = max(flushAt, 1),
        _maxBatchSize = max(max(flushAt, 1), maxBatchSize),
        _maxQueueSize = max(max(flushAt, 1), maxQueueSize),
        _flushInterval = flushInterval,
        _requestTimeout = requestTimeout,
        _featureFlagsRequestTimeout = featureFlagsRequestTimeout,
        _fetchRetryCount = max(fetchRetryCount, 0),
        _fetchRetryDelay = fetchRetryDelay,
        _disableGeoip = disableGeoip,
        _disabled = disabled,
        _disableCompression = disableCompression,
        _sendFeatureFlagEvents = sendFeatureFlagEvents,
        _beforeSend = List.unmodifiable(beforeSend),
        _onError = onError ?? _printError,
        _httpClient = httpClient ?? http.Client(),
        _ownsHttpClient = httpClient == null;

  /// The ingestion host, without a trailing slash.
  final Uri host;

  final String _apiKey;
  final int _flushAt;
  int _maxBatchSize;
  final int _maxQueueSize;
  final Duration _flushInterval;
  final Duration _requestTimeout;
  final Duration _featureFlagsRequestTimeout;
  final int _fetchRetryCount;
  final Duration _fetchRetryDelay;
  final bool _disableGeoip;
  final bool _disabled;
  final bool _disableCompression;
  final bool _sendFeatureFlagEvents;
  final List<BeforeSend> _beforeSend;
  final PostHogErrorHandler _onError;
  final http.Client _httpClient;
  final bool _ownsHttpClient;

  final List<_QueuedEvent> _queue = [];
  final Set<Future<void>> _pending = {};
  final Map<String, Set<String>> _sentFlagCalls = {};
  Timer? _flushTimer;
  Future<void>? _flushFuture;
  Future<void>? _backgroundFlush;
  Future<void>? _shutdownFuture;
  bool _isShutDown = false;
  bool _isClosing = false;

  /// Whether the client was created with `disabled: true`.
  bool get isDisabled => _disabled;

  /// The number of events waiting to be sent.
  int get queueLength => _queue.length;

  /// Queues an event.
  ///
  /// [properties] may carry person updates under `$set` and `$set_once`.
  /// [groups] maps a group type to a group key and is sent as `$groups`.
  /// Without a [distinctId] the event is personless: it gets a random id and
  /// `$process_person_profile: false`.
  ///
  /// With [sendFeatureFlags], the user's flags are evaluated remotely first
  /// and attached as `$feature/<key>` and `$active_feature_flags`. [flush]
  /// waits for that evaluation, so the event is never left behind.
  ///
  /// Never throws for delivery problems, a throwing `beforeSend` hook or a
  /// property that cannot be encoded as JSON: those go to `onError` and the
  /// event is dropped. A [DateTime] property is sent as an ISO-8601 string.
  void capture({
    String? distinctId,
    required String event,
    Map<String, Object?>? properties,
    Map<String, String>? groups,
    DateTime? timestamp,
    String? uuid,
    bool? disableGeoip,
    bool sendFeatureFlags = false,
  }) {
    _checkNotShutDown();
    if (_disabled) return;
    final prepared = _prepareEvent(
      distinctId: distinctId,
      event: event,
      properties: properties,
      groups: groups,
      timestamp: timestamp,
      uuid: uuid,
      disableGeoip: disableGeoip,
    );
    if (prepared == null) return;
    if (!sendFeatureFlags) {
      _enqueue('capture', _eventPayload(prepared, const {}), prepared);
      return;
    }
    _track(() async {
      final flagProperties = await _flagPropertiesForEvent(prepared);
      _enqueue('capture', _eventPayload(prepared, flagProperties), prepared);
    }());
  }

  /// Sends one event right away, bypassing the queue, and completes once
  /// PostHog has accepted it.
  ///
  /// Throws [PostHogHttpException] or [PostHogNetworkException] once retries
  /// are exhausted, and a [JsonUnsupportedObjectError] for a property that
  /// cannot be encoded. Prefer [capture] plus [flush] when sending several
  /// events.
  Future<void> captureImmediate({
    String? distinctId,
    required String event,
    Map<String, Object?>? properties,
    Map<String, String>? groups,
    DateTime? timestamp,
    String? uuid,
    bool? disableGeoip,
    bool sendFeatureFlags = false,
  }) async {
    _checkNotShutDown();
    if (_disabled) return;
    final prepared = _prepareEvent(
      distinctId: distinctId,
      event: event,
      properties: properties,
      groups: groups,
      timestamp: timestamp,
      uuid: uuid,
      disableGeoip: disableGeoip,
    );
    if (prepared == null) return;
    final flagProperties = sendFeatureFlags
        ? await _flagPropertiesForEvent(prepared)
        : const <String, Object?>{};
    await _sendImmediate(
      _prepareMessage(
        'capture',
        _eventPayload(prepared, flagProperties),
        prepared,
      ),
    );
  }

  /// Queues an `$identify` event that sets person properties.
  ///
  /// When [properties] contains `$set`, only `$set`, `$set_once` and
  /// `$anon_distinct_id` are used. Otherwise every property except
  /// `$set_once` and `$anon_distinct_id` is treated as `$set`.
  void identify({
    required String distinctId,
    Map<String, Object?> properties = const {},
    bool? disableGeoip,
  }) {
    _checkNotShutDown();
    if (_disabled) return;
    _enqueue(
      'identify',
      _identifyPayload(distinctId, properties),
      PostHogEvent(
        distinctId: distinctId,
        event: r'$identify',
        disableGeoip: disableGeoip,
      ),
    );
  }

  /// Sends an `$identify` event right away. See [identify] and
  /// [captureImmediate].
  Future<void> identifyImmediate({
    required String distinctId,
    Map<String, Object?> properties = const {},
    bool? disableGeoip,
  }) async {
    _checkNotShutDown();
    if (_disabled) return;
    await _sendImmediate(
      _prepareMessage(
        'identify',
        _identifyPayload(distinctId, properties),
        PostHogEvent(
          distinctId: distinctId,
          event: r'$identify',
          disableGeoip: disableGeoip,
        ),
      ),
    );
  }

  /// Queues a `$create_alias` event linking [alias] to [distinctId].
  void alias({
    required String distinctId,
    required String alias,
    bool? disableGeoip,
  }) {
    _checkNotShutDown();
    if (_disabled) return;
    _enqueue(
      'alias',
      _aliasPayload(distinctId, alias),
      PostHogEvent(
        distinctId: distinctId,
        event: r'$create_alias',
        disableGeoip: disableGeoip,
      ),
    );
  }

  /// Sends a `$create_alias` event right away. See [alias] and
  /// [captureImmediate].
  Future<void> aliasImmediate({
    required String distinctId,
    required String alias,
    bool? disableGeoip,
  }) async {
    _checkNotShutDown();
    if (_disabled) return;
    await _sendImmediate(
      _prepareMessage(
        'alias',
        _aliasPayload(distinctId, alias),
        PostHogEvent(
          distinctId: distinctId,
          event: r'$create_alias',
          disableGeoip: disableGeoip,
        ),
      ),
    );
  }

  /// Queues a `$groupidentify` event that sets properties on a group.
  ///
  /// [distinctId] defaults to `$<groupType>_<groupKey>`.
  void groupIdentify({
    required String groupType,
    required String groupKey,
    Map<String, Object?>? properties,
    String? distinctId,
    bool? disableGeoip,
  }) {
    _checkNotShutDown();
    if (_disabled) return;
    final resolvedDistinctId = distinctId ?? '\$${groupType}_$groupKey';
    _enqueue(
      'capture',
      _basePayload(resolvedDistinctId, r'$groupidentify', {
        r'$group_type': groupType,
        r'$group_key': groupKey,
        r'$group_set': properties ?? const <String, Object?>{},
      }),
      PostHogEvent(
        distinctId: resolvedDistinctId,
        event: r'$groupidentify',
        disableGeoip: disableGeoip,
      ),
    );
  }

  /// Evaluates one flag for [distinctId] and returns `false`, `true` or the
  /// variant `String`, or `null` when the flag does not exist or PostHog could
  /// not be reached.
  ///
  /// Sends a `$feature_flag_called` event once per user and value unless
  /// [sendFeatureFlagEvents] (default: the client's setting) is `false`.
  Future<Object?> getFeatureFlag(
    String key,
    String distinctId, {
    Map<String, String>? groups,
    Map<String, Object?>? personProperties,
    Map<String, Map<String, Object?>>? groupProperties,
    bool? sendFeatureFlagEvents,
    bool? disableGeoip,
  }) async {
    final result = await _featureFlagResult(
      key,
      distinctId,
      groups: groups,
      personProperties: personProperties,
      groupProperties: groupProperties,
      sendFeatureFlagEvents: sendFeatureFlagEvents ?? _sendFeatureFlagEvents,
      disableGeoip: disableGeoip,
    );
    return result?.value;
  }

  /// Whether the flag is on for [distinctId]: any variant counts as on.
  /// `null` when the flag does not exist or PostHog could not be reached.
  Future<bool?> isFeatureEnabled(
    String key,
    String distinctId, {
    Map<String, String>? groups,
    Map<String, Object?>? personProperties,
    Map<String, Map<String, Object?>>? groupProperties,
    bool? sendFeatureFlagEvents,
    bool? disableGeoip,
  }) async {
    final value = await getFeatureFlag(
      key,
      distinctId,
      groups: groups,
      personProperties: personProperties,
      groupProperties: groupProperties,
      sendFeatureFlagEvents: sendFeatureFlagEvents,
      disableGeoip: disableGeoip,
    );
    if (value == null) return null;
    return value != false;
  }

  /// The decoded payload of the flag's matched value for [distinctId], or
  /// `null` when there is none. Never sends `$feature_flag_called`.
  ///
  /// Use [getFeatureFlagResult] to tell "no payload" apart from "flag
  /// missing".
  Future<Object?> getFeatureFlagPayload(
    String key,
    String distinctId, {
    Map<String, String>? groups,
    Map<String, Object?>? personProperties,
    Map<String, Map<String, Object?>>? groupProperties,
    bool? disableGeoip,
  }) async {
    final result = await _featureFlagResult(
      key,
      distinctId,
      groups: groups,
      personProperties: personProperties,
      groupProperties: groupProperties,
      sendFeatureFlagEvents: false,
      disableGeoip: disableGeoip,
    );
    return result?.payload;
  }

  /// Evaluates one flag and returns its value and payload together, or
  /// `null` when the flag does not exist or PostHog could not be reached.
  Future<FeatureFlagResult?> getFeatureFlagResult(
    String key,
    String distinctId, {
    Map<String, String>? groups,
    Map<String, Object?>? personProperties,
    Map<String, Map<String, Object?>>? groupProperties,
    bool? sendFeatureFlagEvents,
    bool? disableGeoip,
  }) =>
      _featureFlagResult(
        key,
        distinctId,
        groups: groups,
        personProperties: personProperties,
        groupProperties: groupProperties,
        sendFeatureFlagEvents: sendFeatureFlagEvents ?? _sendFeatureFlagEvents,
        disableGeoip: disableGeoip,
      );

  /// Every flag value for [distinctId], or only [flagKeys] when given.
  /// Empty when PostHog could not be reached.
  Future<Map<String, Object>> getAllFlags(
    String distinctId, {
    Map<String, String>? groups,
    Map<String, Object?>? personProperties,
    Map<String, Map<String, Object?>>? groupProperties,
    List<String>? flagKeys,
    bool? disableGeoip,
  }) async {
    final all = await getAllFlagsAndPayloads(
      distinctId,
      groups: groups,
      personProperties: personProperties,
      groupProperties: groupProperties,
      flagKeys: flagKeys,
      disableGeoip: disableGeoip,
    );
    return all.featureFlags;
  }

  /// Every flag value and payload for [distinctId], or only [flagKeys] when
  /// given. Empty when PostHog could not be reached.
  Future<FeatureFlagsAndPayloads> getAllFlagsAndPayloads(
    String distinctId, {
    Map<String, String>? groups,
    Map<String, Object?>? personProperties,
    Map<String, Map<String, Object?>>? groupProperties,
    List<String>? flagKeys,
    bool? disableGeoip,
  }) async {
    final response = await _fetchFlags(
      distinctId,
      groups: groups ?? const {},
      personProperties: {'distinct_id': distinctId, ...?personProperties},
      groupProperties: _groupPropertiesWithKeys(groups, groupProperties),
      disableGeoip: disableGeoip,
      flagKeys: flagKeys,
    );
    return FeatureFlagsAndPayloads(
      featureFlags: response?.values ?? const {},
      featureFlagPayloads: response?.payloads ?? const {},
    );
  }

  /// Sends every queued event, in batches of at most `maxBatchSize`, and
  /// completes once PostHog has accepted them.
  ///
  /// Waits for captures still evaluating `sendFeatureFlags`, and for any
  /// flush already in flight. Throws [PostHogHttpException] or
  /// [PostHogNetworkException] once retries are exhausted. After a network
  /// error the unsent events stay queued; after an HTTP error the rejected
  /// batch is dropped, since resending it would fail the same way.
  ///
  /// With a [timeout], throws [PostHogTimeoutException] once it passes; the
  /// flush carries on in the background and unsent events stay queued. Set
  /// one on serverless runtimes so an outage cannot hold a request open.
  Future<void> flush({Duration? timeout}) {
    final previous = _flushFuture;
    final next = () async {
      if (previous != null) await previous.then((_) {}, onError: (_) {});
      await _awaitPending();
      await _flushQueue();
    }();
    _flushFuture = next;
    next.whenComplete(() {
      if (identical(_flushFuture, next)) _flushFuture = null;
    }).ignore();
    if (timeout == null) return next;
    return next.timeout(
      timeout,
      onTimeout: () => throw PostHogTimeoutException(_queue.length),
    );
  }

  /// Sends every queued event and releases the HTTP client. Call it once,
  /// before the process exits; use [flush] between requests instead.
  ///
  /// Delivery errors go to `onError`. Throws [PostHogTimeoutException] when
  /// events are still queued after [timeout]; requests still in flight are
  /// then abandoned without retrying. Any call on this client afterwards
  /// throws a [StateError].
  Future<void> shutdown({Duration timeout = const Duration(seconds: 30)}) {
    return _shutdownFuture ??= _shutdown(timeout);
  }

  Future<void> _shutdown(Duration timeout) async {
    _cancelFlushTimer();
    var timedOut = false;
    try {
      await () async {
        try {
          await _awaitPending();
          while (_queue.isNotEmpty && !timedOut) {
            await flush();
          }
        } on PostHogException catch (error, stackTrace) {
          _report(error, stackTrace);
        }
      }()
          .timeout(timeout);
    } on TimeoutException {
      timedOut = true;
      throw PostHogTimeoutException(_queue.length);
    } finally {
      _isClosing = true;
      _isShutDown = true;
      _cancelFlushTimer();
      if (_ownsHttpClient) _httpClient.close();
    }
  }

  PostHogEvent? _prepareEvent({
    required String? distinctId,
    required String event,
    required Map<String, Object?>? properties,
    required Map<String, String>? groups,
    required DateTime? timestamp,
    required String? uuid,
    required bool? disableGeoip,
  }) {
    final mergedProperties = <String, Object?>{...?properties};
    var resolvedDistinctId = distinctId;
    if (resolvedDistinctId == null || resolvedDistinctId.isEmpty) {
      resolvedDistinctId = _uuidV7();
      mergedProperties[r'$process_person_profile'] = false;
    }
    PostHogEvent? prepared = PostHogEvent(
      distinctId: resolvedDistinctId,
      event: event,
      properties: mergedProperties,
      groups: groups,
      timestamp: timestamp,
      uuid: uuid,
      disableGeoip: disableGeoip,
    );
    for (final hook in _beforeSend) {
      try {
        prepared = hook(prepared!);
      } on Object catch (error, stackTrace) {
        _report(error, stackTrace);
        return null;
      }
      if (prepared == null) return null;
    }
    return prepared;
  }

  Map<String, Object?> _eventPayload(
    PostHogEvent event,
    Map<String, Object?> flagProperties,
  ) =>
      _basePayload(event.distinctId, event.event, {
        ...flagProperties,
        ...event.properties,
        if (event.groups != null) r'$groups': event.groups,
      });

  Map<String, Object?> _identifyPayload(
    String distinctId,
    Map<String, Object?> properties,
  ) {
    final rest = Map.of(properties)
      ..remove(r'$set')
      ..remove(r'$set_once')
      ..remove(r'$anon_distinct_id');
    final anonDistinctId = properties[r'$anon_distinct_id'];
    return _basePayload(distinctId, r'$identify', {
      r'$set': properties[r'$set'] ?? rest,
      r'$set_once': properties[r'$set_once'] ?? const <String, Object?>{},
      if (anonDistinctId != null) r'$anon_distinct_id': anonDistinctId,
    });
  }

  Map<String, Object?> _aliasPayload(String distinctId, String alias) =>
      _basePayload(distinctId, r'$create_alias', {
        'distinct_id': distinctId,
        'alias': alias,
      });

  Map<String, Object?> _basePayload(
    String distinctId,
    String event,
    Map<String, Object?> properties,
  ) =>
      {
        'distinct_id': distinctId,
        'event': event,
        'properties': {
          ...properties,
          r'$lib': posthogApiLibraryId,
          r'$lib_version': posthogApiVersion,
        },
      };

  Map<String, Object?> _prepareMessage(
    String type,
    Map<String, Object?> payload,
    PostHogEvent event,
  ) {
    final message = <String, Object?>{
      ...payload,
      'type': type,
      'library': posthogApiLibraryId,
      'library_version': posthogApiVersion,
      'timestamp': _isoTimestamp(event.timestamp ?? DateTime.now()),
      'uuid': event.uuid ?? _uuidV7(),
    };
    if (event.disableGeoip ?? _disableGeoip) {
      message['properties'] = {
        ...message['properties']! as Map<String, Object?>,
        r'$geoip_disable': true,
      };
    }
    return message;
  }

  void _enqueue(
    String type,
    Map<String, Object?> payload,
    PostHogEvent event,
  ) {
    if (_isShutDown) return;
    final _QueuedEvent queued;
    try {
      queued = _QueuedEvent(_encode(_prepareMessage(type, payload, event)));
    } on Object catch (error, stackTrace) {
      _report(error, stackTrace);
      return;
    }
    if (_queue.length >= _maxQueueSize) _queue.removeAt(0);
    _queue.add(queued);
    if (_queue.length >= _flushAt) _flushInBackground();
    _scheduleFlushTimer();
  }

  Future<void> _sendImmediate(Map<String, Object?> message) async {
    await _postBatch([_QueuedEvent(_encode(message))]);
  }

  void _flushInBackground() {
    if (_backgroundFlush != null) return;
    _backgroundFlush = flush().then((_) => true, onError: (
      Object error,
      StackTrace stackTrace,
    ) {
      _report(error, stackTrace);
      return false;
    }).then((succeeded) {
      _backgroundFlush = null;
      if (_isShutDown) return;
      if (succeeded && _queue.length >= _flushAt) {
        _flushInBackground();
      } else if (_queue.isNotEmpty) {
        _scheduleFlushTimer();
      }
    });
  }

  void _scheduleFlushTimer() {
    if (_flushInterval > Duration.zero && _flushTimer == null) {
      _flushTimer = Timer(_flushInterval, _flushInBackground);
    }
  }

  void _cancelFlushTimer() {
    _flushTimer?.cancel();
    _flushTimer = null;
  }

  void _track(Future<void> future) {
    _pending.add(future);
    future
        .catchError(_report)
        .whenComplete(() => _pending.remove(future))
        .ignore();
  }

  Future<void> _awaitPending() async {
    while (_pending.isNotEmpty) {
      await Future.wait(
        _pending.map((future) => future.catchError((Object _) {})),
      );
    }
  }

  Future<void> _flushQueue() async {
    _cancelFlushTimer();
    if (_queue.isEmpty) return;

    var sentCount = 0;
    final originalLength = _queue.length;
    while (_queue.isNotEmpty && sentCount < originalLength) {
      final batch = _queue.take(_maxBatchSize).toList();
      try {
        await _postBatch(batch);
      } on PostHogHttpException catch (error) {
        if (error.statusCode == 413 && batch.length > 1) {
          _maxBatchSize = max(1, batch.length ~/ 2);
          continue;
        }
        _removeFromQueue(batch);
        rethrow;
      }
      _removeFromQueue(batch);
      sentCount += batch.length;
    }
  }

  void _removeFromQueue(List<_QueuedEvent> batch) {
    final sent = Set<_QueuedEvent>.identity()..addAll(batch);
    _queue.removeWhere(sent.contains);
  }

  Future<void> _postBatch(List<_QueuedEvent> batch) async {
    final body = '{"api_key":${jsonEncode(_apiKey)},'
        '"batch":[${batch.map((event) => event.json).join(',')}],'
        '"sent_at":"${_isoTimestamp(DateTime.now())}"}';
    final bytes = utf8.encode(body);
    final compressed = _disableCompression ? null : gzipEncode(bytes);
    await _fetchWithRetry(
      Uri.parse('$host/batch/'),
      bytes: compressed ?? bytes,
      headers: {
        'Content-Type': 'application/json',
        if (compressed != null) 'Content-Encoding': 'gzip',
      },
      retryCount: _fetchRetryCount,
      timeout: _requestTimeout,
    );
  }

  Future<http.Response> _fetchWithRetry(
    Uri url, {
    required List<int> bytes,
    required Map<String, String> headers,
    required int retryCount,
    required Duration timeout,
  }) async {
    for (var attempt = 0;; attempt++) {
      try {
        return await _fetch(url,
            bytes: bytes, headers: headers, timeout: timeout);
      } on PostHogException catch (error) {
        if (attempt >= retryCount || !_isRetriable(error) || _isClosing) {
          rethrow;
        }
      }
      await Future<void>.delayed(_fetchRetryDelay);
    }
  }

  static bool _isRetriable(PostHogException error) => switch (error) {
        PostHogNetworkException() => true,
        PostHogHttpException(:final statusCode) =>
          statusCode == 408 || statusCode == 429 || statusCode >= 500,
        PostHogTimeoutException() => false,
      };

  Future<http.Response> _fetch(
    Uri url, {
    required List<int> bytes,
    required Map<String, String> headers,
    required Duration timeout,
  }) async {
    final abort = Completer<void>();
    final request =
        http.AbortableRequest('POST', url, abortTrigger: abort.future)
          ..headers.addAll({
            if (canSetUserAgent)
              'User-Agent': '$posthogApiLibraryId/$posthogApiVersion',
            ...headers,
          })
          ..bodyBytes = bytes;
    final http.Response response;
    try {
      response = await _httpClient
          .send(request)
          .then(http.Response.fromStream)
          .timeout(timeout, onTimeout: () {
        abort.complete();
        throw TimeoutException('No response from $url', timeout);
      });
    } on Object catch (error) {
      throw PostHogNetworkException(error);
    }
    if (response.statusCode < 200 || response.statusCode >= 400) {
      throw PostHogHttpException(
        statusCode: response.statusCode,
        body: response.body,
        requestByteLength: bytes.length,
      );
    }
    return response;
  }

  Future<_FlagsResponse?> _fetchFlags(
    String distinctId, {
    required Map<String, String> groups,
    required Map<String, Object?> personProperties,
    required Map<String, Map<String, Object?>> groupProperties,
    required bool? disableGeoip,
    List<String>? flagKeys,
  }) async {
    if (_disabled) return null;
    _checkNotShutDown();
    final deviceId = personProperties[r'$device_id'];
    final body = <String, Object?>{
      'token': _apiKey,
      'distinct_id': distinctId,
      'groups': groups,
      'person_properties': personProperties,
      'group_properties': groupProperties,
      if (disableGeoip ?? _disableGeoip) 'geoip_disable': true,
      if (flagKeys != null) 'flag_keys_to_evaluate': flagKeys,
      if (deviceId != null) r'$device_id': deviceId,
    };
    final _FlagsResponse response;
    try {
      final httpResponse = await _fetchWithRetry(
        Uri.parse('$host/flags/?v=2'),
        bytes: utf8.encode(jsonEncode(body)),
        headers: const {'Content-Type': 'application/json'},
        retryCount: 0,
        timeout: _featureFlagsRequestTimeout,
      );
      final decoded = jsonDecode(httpResponse.body);
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('The /flags/ response is not an object');
      }
      response = _FlagsResponse.fromJson(decoded);
    } on Object catch (error, stackTrace) {
      _report(error, stackTrace);
      return null;
    }

    if (response.errorsWhileComputingFlags) {
      _print('[FEATURE FLAGS] Error while computing feature flags, some flags '
          'may be missing or incorrect. Learn more at '
          'https://posthog.com/docs/feature-flags/best-practices');
    }
    if (response.isFeatureFlagQuotaLimited) {
      _print('[FEATURE FLAGS] Feature flags quota limit exceeded - feature '
          'flags unavailable. Learn more about billing limits at '
          'https://posthog.com/docs/billing/limits-alerts');
      return _FlagsResponse(
        flags: const {},
        quotaLimited: response.quotaLimited,
        requestId: response.requestId,
        evaluatedAt: response.evaluatedAt,
      );
    }
    return response;
  }

  Future<FeatureFlagResult?> _featureFlagResult(
    String key,
    String distinctId, {
    required Map<String, String>? groups,
    required Map<String, Object?>? personProperties,
    required Map<String, Map<String, Object?>>? groupProperties,
    required bool sendFeatureFlagEvents,
    required bool? disableGeoip,
  }) async {
    if (_disabled) return null;
    final response = await _fetchFlags(
      distinctId,
      groups: groups ?? const {},
      personProperties: {'distinct_id': distinctId, ...?personProperties},
      groupProperties: _groupPropertiesWithKeys(groups, groupProperties),
      disableGeoip: disableGeoip,
      flagKeys: [key],
    );

    FeatureFlagResult? result;
    _FlagDetail? detail;
    final errors = <String>[];
    if (response == null) {
      errors.add('unknown_error');
    } else {
      if (response.errorsWhileComputingFlags) {
        errors.add('errors_while_computing_flags');
      }
      if (response.isFeatureFlagQuotaLimited) errors.add('quota_limited');
      detail = response.flags[key];
      if (detail == null) {
        errors.add('flag_missing');
      } else {
        result = FeatureFlagResult(
          key: key,
          enabled: detail.enabled,
          variant: detail.variant,
          payload: detail.decodedPayload,
        );
      }
    }

    if (sendFeatureFlagEvents) {
      _reportFlagCalled(
        key,
        distinctId,
        result: result,
        detail: detail,
        response: response,
        error: errors.isEmpty ? null : errors.join(','),
        groups: groups,
        disableGeoip: disableGeoip,
      );
    }
    return result;
  }

  void _reportFlagCalled(
    String key,
    String distinctId, {
    required FeatureFlagResult? result,
    required _FlagDetail? detail,
    required _FlagsResponse? response,
    required String? error,
    required Map<String, String>? groups,
    required bool? disableGeoip,
  }) {
    if (_isShutDown) return;
    final value = result?.value;
    final reportedKey = '${key}_$value';
    final reported = _sentFlagCalls[distinctId];
    if (reported != null && reported.contains(reportedKey)) return;
    if (reported == null && _sentFlagCalls.length >= _maxFlagCallCacheSize) {
      _sentFlagCalls.clear();
    }
    _sentFlagCalls.putIfAbsent(distinctId, () => {}).add(reportedKey);

    final reason = detail?.reasonDescription ?? detail?.reasonCode;
    capture(
      distinctId: distinctId,
      event: r'$feature_flag_called',
      properties: {
        r'$feature_flag': key,
        if (value != null) r'$feature_flag_response': value,
        if (detail?.id != null) r'$feature_flag_id': detail!.id,
        if (detail?.version != null) r'$feature_flag_version': detail!.version,
        if (reason != null) r'$feature_flag_reason': reason,
        'locally_evaluated': false,
        if (value != null) '\$feature/$key': value,
        if (response?.requestId != null)
          r'$feature_flag_request_id': response!.requestId,
        if (response?.evaluatedAt != null)
          r'$feature_flag_evaluated_at': response!.evaluatedAt,
        if (error != null) r'$feature_flag_error': error,
      },
      groups: groups,
      disableGeoip: disableGeoip,
    );
  }

  Future<Map<String, Object?>> _flagPropertiesForEvent(
    PostHogEvent event,
  ) async {
    final response = await _fetchFlags(
      event.distinctId,
      groups: event.groups ?? const {},
      personProperties: const {},
      groupProperties: const {},
      disableGeoip: event.disableGeoip,
    );
    final flags = response?.values ?? const <String, Object>{};
    final active = [
      for (final entry in flags.entries)
        if (entry.value != false) entry.key,
    ]..sort();
    return {
      for (final entry in flags.entries) '\$feature/${entry.key}': entry.value,
      if (active.isNotEmpty) r'$active_feature_flags': active,
    };
  }

  Map<String, Map<String, Object?>> _groupPropertiesWithKeys(
    Map<String, String>? groups,
    Map<String, Map<String, Object?>>? groupProperties,
  ) =>
      {
        for (final entry in (groups ?? const <String, String>{}).entries)
          entry.key: {
            r'$group_key': entry.value,
            ...?groupProperties?[entry.key],
          },
      };

  void _checkNotShutDown() {
    if (_isShutDown) {
      throw StateError('This PostHog client was shut down.');
    }
  }

  void _report(Object error, StackTrace stackTrace) {
    try {
      _onError(error, stackTrace);
    } on Object catch (handlerError, handlerStackTrace) {
      Zone.current.handleUncaughtError(handlerError, handlerStackTrace);
    }
  }

  static const _maxFlagCallCacheSize = 50000;

  static String _encode(Object? value) =>
      jsonEncode(value, toEncodable: _toEncodable);

  static Object? _toEncodable(Object? value) =>
      value is DateTime ? _isoTimestamp(value) : (value as dynamic).toJson();

  static void _print(String message) => print('[PostHog] $message');

  static void _printError(Object error, StackTrace stackTrace) {
    _print('$error');
  }

  static String _requireApiKey(String apiKey) {
    if (apiKey.trim().isEmpty) {
      throw ArgumentError.value(
        apiKey,
        'apiKey',
        "You must pass your PostHog project's api key.",
      );
    }
    return apiKey;
  }
}

final class _QueuedEvent {
  _QueuedEvent(this.json);

  final String json;
}
