# Conventions

This is a public package, so it does **not** follow the Fullphysio monorepo's
no-comments or 120-column rules.

- `///` dartdoc is **required** on every exported symbol. pub.dev scores it and
  IDE hovers depend on it.
- No comments on private implementation code. Name things properly instead.
  Internal helpers live in `part` files of `lib/src/posthog.dart` so they can
  stay private.
- Formatting is stock `dart format` — **default width, no `--line-length`**.
  A Dart SDK from a Flutter fork or a dev channel can format differently from
  stable; CI runs official stable and is the arbiter.
- `dart analyze --fatal-infos` must be clean.
- No `dart:io` outside `lib/src/platform_io.dart`: the package must keep
  compiling for the web, where gzip is skipped.

## Tests

Three tiers:

- **Unit and golden conformance** — `test/*.dart`, no network.
  `test/fixtures/requests_golden.json` was captured from the real
  `posthog-node` (5.29.2) by `tool/capture_fixtures/capture.js`;
  `test/conformance_test.dart` replays each scenario and compares the
  requests. When changing payload construction, regenerate the fixture
  against the same reference version rather than editing it by hand, and bump
  the version in `THIRD_PARTY_NOTICES` and the README if you move upstream.
- **Mock server** (`test/mock/`, tag `mock`) — a local `HttpServer` that
  behaves like PostHog: real sockets, gzip, timeouts, refused connections. No
  account and no network, so it runs in the default `dart test`.
- **Integration** (`test/integration/`, tag `integration`) — sends real events
  and evaluates flags. Skipped by default (see `dart_test.yaml`); run with
  `POSTHOG_TEST_API_KEY=phc_... dart test --tags integration --run-skipped`.
  It skips itself when the key is unset. Assertions are structural.

## CI

- `ci.yml` — format, analyze, `pub publish --dry-run`, then tests on the
  declared SDK floor and stable, plus a `pana` job that fails if the pub.dev
  score drops below maximum. Runs weekly too, to catch SDK and dependency drift.
- `integration.yml` — live API tests on main, nightly and on demand, reading
  the `POSTHOG_TEST_API_KEY` repository variable. Deliberately not on pull
  requests: an upstream outage must never block a merge.
- `publish.yml` — releases on a `v<version>` tag via GitHub OIDC. No stored
  credentials.

## Releasing

1. Bump `version:` in `pubspec.yaml` and `posthogApiVersion` in
   `lib/src/version.dart` (a test keeps them in step), and add a
   `CHANGELOG.md` entry.
2. Merge to `main` and let CI go green.
3. Tag and push:

   ```
   git tag v1.2.3 && git push origin v1.2.3
   ```

Publishing is permanent: a version can be retracted within 7 days but never
deleted, and the number is never reusable.
