## 0.1.0

- Initial release: a port of `posthog-node` 5.29.2. Capture, identify, alias
  and group identify (plus the `*Immediate` variants), batching via `/batch/`
  with gzip, retries, `413` batch halving, `beforeSend`, `flush()` with an
  optional timeout, `shutdown()`, and remote feature flag evaluation.
- Stays below 1.0 until the API has run in production.
