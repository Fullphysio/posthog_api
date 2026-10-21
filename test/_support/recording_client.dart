import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A request the fake transport received, with its body decoded.
class RecordedRequest {
  RecordedRequest(this.request, this.json);

  final http.Request request;
  final Map<String, Object?> json;

  String get pathAndQuery =>
      request.url.path + (request.url.hasQuery ? '?${request.url.query}' : '');

  List<Map<String, Object?>> get batch =>
      (json['batch'] as List<Object?>).cast<Map<String, Object?>>();
}

/// Decides the response for each request. Returning `null` falls back to the
/// default: `{"status":"Ok"}` for `/batch/`, [flagsResponse] for `/flags/`.
typedef Responder = Future<http.Response?> Function(
  http.Request request,
  int attempt,
);

/// An in-memory PostHog: records every request and answers like the real
/// endpoints unless a [Responder] says otherwise.
class RecordingClient {
  RecordingClient({this.flagsResponse = const {}, this.responder});

  final Map<String, Object?> flagsResponse;
  final Responder? responder;
  final List<RecordedRequest> requests = [];

  late final MockClient client = MockClient((request) async {
    final bytes = request.headers['Content-Encoding'] == 'gzip'
        ? gzip.decode(request.bodyBytes)
        : request.bodyBytes;
    final json = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
    requests.add(RecordedRequest(request, json));
    final custom = await responder?.call(request, requests.length);
    if (custom != null) return custom;
    final body = request.url.path.startsWith('/flags')
        ? flagsResponse
        : const {'status': 'Ok'};
    return http.Response(jsonEncode(body), 200,
        headers: {'content-type': 'application/json'});
  });

  List<RecordedRequest> get batches =>
      requests.where((r) => r.request.url.path == '/batch/').toList();

  List<Map<String, Object?>> get events =>
      [for (final r in batches) ...r.batch];
}

final RegExp _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

/// Replaces volatile values exactly as `tool/capture_fixtures/capture.js`
/// does, so requests compare equal to the captured fixtures.
Object? normalise(Object? value) {
  if (value is List) return value.map(normalise).toList();
  if (value is! Map) return value;
  return {
    for (final MapEntry(:key, value: inner) in value.entries)
      key: switch (key) {
        'uuid' || 'timestamp' || 'sent_at' => '<$key>',
        'distinct_id' when inner is String && _uuid.hasMatch(inner) => '<uuid>',
        'library' || r'$lib' => '<lib>',
        'library_version' || r'$lib_version' => '<lib_version>',
        _ => normalise(inner),
      },
  };
}
