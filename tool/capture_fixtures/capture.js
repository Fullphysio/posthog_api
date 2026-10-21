// Captures test/fixtures/requests_golden.json: the exact request bodies the
// REAL `posthog-node` sends for each scenario, recorded through its `fetch`
// option with canned responses. The Dart tests replay the same scenarios and
// compare, so conformance is checked against upstream behaviour rather than
// against what we believe it to be.
//
//   mkdir -p /tmp/posthog-ref && cd /tmp/posthog-ref && npm install posthog-node@5.29.2
//   node /path/to/posthog_api/tool/capture_fixtures/capture.js
//
// Volatile values (uuids, timestamps, library name and version) are replaced
// by placeholders; the Dart test normalises its own requests the same way.

'use strict';

const fs = require('fs');
const path = require('path');

const POSTHOG_NODE_VERSION = '5.29.2';

function loadPostHog() {
  const resolved = require.resolve('posthog-node', { paths: [process.cwd()] });
  let dir = path.dirname(resolved);
  for (let i = 0; i < 8; i++) {
    const candidate = path.join(dir, 'package.json');
    if (fs.existsSync(candidate)) {
      const pkg = JSON.parse(fs.readFileSync(candidate, 'utf8'));
      if (pkg.name === 'posthog-node') {
        if (pkg.version !== POSTHOG_NODE_VERSION) {
          throw new Error('Installed posthog-node is ' + pkg.version + ', expected ' + POSTHOG_NODE_VERSION);
        }
        return require(resolved).PostHog;
      }
    }
    dir = path.dirname(dir);
  }
  throw new Error('Could not locate posthog-node package.json from ' + resolved);
}

const PostHog = loadPostHog();

const FLAGS_RESPONSE = {
  flags: {
    'beta-feature': {
      key: 'beta-feature',
      enabled: true,
      variant: null,
      reason: { code: 'condition_match', description: 'Matched condition set 1', condition_index: 0 },
      metadata: { id: 11, version: 3, payload: '{"discount":10}', description: null },
    },
    'pricing-test': {
      key: 'pricing-test',
      enabled: true,
      variant: 'variant-b',
      reason: { code: 'condition_match', description: 'Matched condition set 2', condition_index: 1 },
      metadata: { id: 12, version: 1, payload: null, description: null },
    },
    'disabled-flag': {
      key: 'disabled-flag',
      enabled: false,
      variant: null,
      reason: { code: 'no_condition_match', description: 'No matching condition set', condition_index: null },
      metadata: { id: 13, version: 7, payload: null, description: null },
    },
  },
  errorsWhileComputingFlags: false,
  requestId: '0f801b5b-0776-42ca-b0f7-8375c95730bf',
  evaluatedAt: 1760000000000,
};

function recordingFetch() {
  const calls = [];
  const fetch = async (url, options) => {
    const body = JSON.parse(options.body);
    calls.push({ url, method: options.method, contentType: options.headers['Content-Type'], body });
    const json = url.includes('/flags/') ? FLAGS_RESPONSE : { status: 'Ok' };
    return { status: 200, text: async () => JSON.stringify(json), json: async () => json };
  };
  return { fetch, calls };
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[0-9a-f]{4}-[0-9a-f]{12}$/;

function normalise(value) {
  if (Array.isArray(value)) return value.map(normalise);
  if (value === null || typeof value !== 'object') return value;
  const out = {};
  for (const [key, inner] of Object.entries(value)) {
    if (key === 'uuid' || key === 'timestamp' || key === 'sent_at') out[key] = '<' + key + '>';
    else if (key === 'distinct_id' && UUID.test(inner)) out[key] = '<uuid>';
    else if (key === 'library' || key === '$lib') out[key] = '<lib>';
    else if (key === 'library_version' || key === '$lib_version') out[key] = '<lib_version>';
    else out[key] = normalise(inner);
  }
  return out;
}

async function scenario(name, run) {
  const { fetch, calls } = recordingFetch();
  const client = new PostHog('phc_test', {
    host: 'https://eu.i.posthog.com',
    fetch,
    flushAt: 100,
    flushInterval: 0,
    disableCompression: true,
  });
  await run(client);
  await client.flush();
  await client.shutdown();
  return {
    name,
    requests: calls.map((c) => ({
      path: new URL(c.url).pathname + new URL(c.url).search,
      method: c.method,
      contentType: c.contentType,
      body: normalise(c.body),
    })),
  };
}

async function main() {
  const cases = [];

  cases.push(
    await scenario('capture_with_set_and_groups', async (ph) => {
      ph.capture({
        distinctId: 'user-1',
        event: 'program_created',
        properties: { $set: { plan: 'pro' }, $set_once: { first_seen: '2026-01-01' }, exercises: 3 },
        groups: { company: 'acme' },
      });
    }),
  );

  cases.push(
    await scenario('capture_set_event', async (ph) => {
      ph.capture({ distinctId: 'user-1', event: '$set', properties: { $set: { name: 'Ada', isPatient: false } } });
    }),
  );

  cases.push(
    await scenario('capture_with_geoip_enabled', async (ph) => {
      ph.capture({ distinctId: 'user-1', event: 'opened', disableGeoip: false });
    }),
  );

  cases.push(
    await scenario('capture_without_distinct_id', async (ph) => {
      ph.capture({ event: 'cron_ran', properties: { jobs: 2 } });
    }),
  );

  cases.push(
    await scenario('ai_generation', async (ph) => {
      ph.capture({
        distinctId: 'user-1',
        event: '$ai_generation',
        properties: {
          $ai_trace_id: 'trace-1',
          $ai_provider: 'anthropic',
          $ai_model: 'claude-sonnet-5-5',
          $ai_input_tokens: 120,
          $ai_output_tokens: 40,
          $ai_latency: 1.25,
          $ai_input: [{ role: 'user', content: 'hi' }],
        },
      });
    }),
  );

  cases.push(
    await scenario('identify_plain_properties', async (ph) => {
      ph.identify({ distinctId: 'user-1', properties: { email: 'ada@example.com', $set_once: { signup: 'web' } } });
    }),
  );

  cases.push(
    await scenario('identify_explicit_set', async (ph) => {
      ph.identify({
        distinctId: 'user-1',
        properties: { $set: { plan: 'pro' }, ignored: true, $anon_distinct_id: 'anon-9' },
      });
    }),
  );

  cases.push(
    await scenario('alias', async (ph) => {
      ph.alias({ distinctId: 'user-1', alias: 'legacy-42' });
    }),
  );

  cases.push(
    await scenario('group_identify', async (ph) => {
      ph.groupIdentify({ groupType: 'company', groupKey: 'acme', properties: { seats: 12 } });
    }),
  );

  cases.push(
    await scenario('group_identify_with_distinct_id', async (ph) => {
      ph.groupIdentify({ groupType: 'company', groupKey: 'acme', distinctId: 'user-1' });
    }),
  );

  cases.push(
    await scenario('capture_immediate', async (ph) => {
      await ph.captureImmediate({ distinctId: 'user-1', event: 'paid', properties: { amount: 30 } });
    }),
  );

  cases.push(
    await scenario('two_events_one_batch', async (ph) => {
      ph.capture({ distinctId: 'user-1', event: 'a' });
      ph.capture({ distinctId: 'user-2', event: 'b' });
    }),
  );

  cases.push(
    await scenario('get_feature_flag_variant', async (ph) => {
      const value = await ph.getFeatureFlag('pricing-test', 'user-1', {
        groups: { company: 'acme' },
        personProperties: { plan: 'pro' },
        groupProperties: { company: { seats: '12' } },
      });
      if (value !== 'variant-b') throw new Error('unexpected ' + value);
    }),
  );

  cases.push(
    await scenario('get_feature_flag_disabled', async (ph) => {
      const value = await ph.getFeatureFlag('disabled-flag', 'user-1');
      if (value !== false) throw new Error('unexpected ' + value);
    }),
  );

  cases.push(
    await scenario('get_feature_flag_missing', async (ph) => {
      const value = await ph.getFeatureFlag('nope', 'user-1');
      if (value !== undefined) throw new Error('unexpected ' + value);
    }),
  );

  cases.push(
    await scenario('get_feature_flag_called_once', async (ph) => {
      await ph.getFeatureFlag('beta-feature', 'user-1');
      await ph.getFeatureFlag('beta-feature', 'user-1');
    }),
  );

  cases.push(
    await scenario('get_feature_flag_payload', async (ph) => {
      const payload = await ph.getFeatureFlagPayload('beta-feature', 'user-1');
      if (JSON.stringify(payload) !== '{"discount":10}') throw new Error('unexpected ' + JSON.stringify(payload));
    }),
  );

  cases.push(
    await scenario('get_all_flags_and_payloads', async (ph) => {
      const all = await ph.getAllFlagsAndPayloads('user-1', { flagKeys: ['beta-feature', 'pricing-test'] });
      if (all.featureFlags['pricing-test'] !== 'variant-b') throw new Error('unexpected ' + JSON.stringify(all));
    }),
  );

  cases.push(
    await scenario('capture_with_send_feature_flags', async (ph) => {
      ph.capture({ distinctId: 'user-1', event: 'checkout', sendFeatureFlags: true });
    }),
  );

  const out = path.join(__dirname, '..', '..', 'test', 'fixtures', 'requests_golden.json');
  fs.writeFileSync(
    out,
    JSON.stringify({ upstream: 'posthog-node@' + POSTHOG_NODE_VERSION, flagsResponse: FLAGS_RESPONSE, cases }, null, 2) + '\n',
  );
  console.log('Wrote ' + out + ' (' + cases.length + ' cases)');
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
