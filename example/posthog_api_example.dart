import 'package:posthog_api/posthog_api.dart';

Future<void> main() async {
  final posthog = PostHog(
    'phc_your_project_api_key',
    host: Uri.parse('https://eu.i.posthog.com'),
  );

  posthog.capture(
    distinctId: 'user-123',
    event: 'program_created',
    properties: {
      'exercises': 6,
      r'$set': {'plan': 'pro'},
    },
  );

  posthog.identify(
    distinctId: 'user-123',
    properties: {'email': 'ada@example.com'},
  );

  if (await posthog.isFeatureEnabled('new-editor', 'user-123') ?? false) {
    print('new-editor is on');
  }

  await posthog.shutdown();
}
