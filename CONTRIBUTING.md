# Contributing

## Reporting a bug

Open an issue with the package version, the call you made, and what PostHog
returned (redact keys and personal data). A failing request is most useful
with its HTTP status and the exception's message.

Behaviour follows the official `posthog-node` SDK. If this package differs from
it, that is a bug unless the README lists it as a deliberate divergence.

## Running the tests

```
dart pub get
dart analyze --fatal-infos
dart test                      # unit, golden conformance and local mock server, no network
dart test --tags integration --run-skipped   # live API, needs `POSTHOG_TEST_API_KEY`
```

## Pull requests

- Keep `dart format` (default width) and `dart analyze --fatal-infos` clean.
- Every exported symbol needs `///` dartdoc.
- Add a `CHANGELOG.md` entry under an `## Unreleased` heading.
