@Tags(['mock'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:posthog_api/posthog_api.dart';
import 'package:test/test.dart';

/// Runs the client against a local HTTP server that behaves like PostHog's
/// ingestion endpoints, over real sockets with the default `http.Client`.
/// No account and no network, so it runs on every pull request.
void main() {
  late HttpServer server;
  late List<Map<String, Object?>> received;
  late List<int> statuses;
  late Duration delay;

  setUp(() async {
    received = [];
    statuses = [];
    delay = Duration.zero;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final bytes = await request
          .fold<List<int>>([], (buffer, chunk) => buffer..addAll(chunk));
      final body = request.headers.value('content-encoding') == 'gzip'
          ? gzip.decode(bytes)
          : bytes;
      received.add({
        'path': request.uri.path,
        'encoding': request.headers.value('content-encoding'),
        'userAgent': request.headers.value('user-agent'),
        'json': jsonDecode(utf8.decode(body)),
      });
      await Future<void>.delayed(delay);
      final status = statuses.isEmpty ? 200 : statuses.removeAt(0);
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(request.uri.path.startsWith('/flags')
            ? jsonEncode({
                'flags': {
                  'beta': {'key': 'beta', 'enabled': true, 'variant': 'b'},
                },
              })
            : '{"status":"Ok"}');
      await request.response.close();
    });
  });

  tearDown(() => server.close(force: true));

  PostHog client({int retries = 3, Duration? timeout}) => PostHog(
        'phc_test',
        host: Uri.parse('http://${server.address.host}:${server.port}'),
        flushInterval: Duration.zero,
        fetchRetryCount: retries,
        fetchRetryDelay: const Duration(milliseconds: 10),
        requestTimeout: timeout ?? const Duration(seconds: 5),
      );

  test('sends a gzipped batch the server can decode', () async {
    final posthog = client();
    posthog.capture(distinctId: 'u', event: 'a', properties: {'n': 1});
    posthog.identify(distinctId: 'u', properties: {'plan': 'pro'});
    await posthog.shutdown();

    final request = received.single;
    expect(request['path'], '/batch/');
    expect(request['encoding'], 'gzip');
    expect(request['userAgent'], 'posthog_api/$posthogApiVersion');
    final batch = (request['json']! as Map)['batch'] as List;
    expect(batch.map((e) => (e as Map)['event']), ['a', r'$identify']);
  });

  test('retries a 503 over a real connection', () async {
    statuses = [503, 502];
    final posthog = client();
    await posthog.captureImmediate(distinctId: 'u', event: 'a');
    expect(received, hasLength(3));
    await posthog.shutdown();
  });

  test('times out a stalled response and keeps the event', () async {
    delay = const Duration(seconds: 2);
    final posthog =
        client(retries: 0, timeout: const Duration(milliseconds: 200));
    posthog.capture(distinctId: 'u', event: 'a');
    await expectLater(posthog.flush(), throwsA(isA<PostHogNetworkException>()));
    expect(posthog.queueLength, 1);
  });

  test('a refused connection is a network error', () async {
    final port = server.port;
    await server.close(force: true);
    final posthog = PostHog(
      'phc_test',
      host: Uri.parse('http://127.0.0.1:$port'),
      fetchRetryCount: 0,
    );
    await expectLater(
      posthog.captureImmediate(distinctId: 'u', event: 'a'),
      throwsA(isA<PostHogNetworkException>()),
    );
  });

  test('evaluates a flag through /flags/', () async {
    final posthog = client();
    expect(await posthog.getFeatureFlag('beta', 'u'), 'b');
    await posthog.shutdown();
    expect(received.map((r) => r['path']), ['/flags/', '/batch/']);
  });
}
