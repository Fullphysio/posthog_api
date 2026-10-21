## 1.0.0

- Initial release: a port of `posthog-node` 5.29.2. Capture, identify, alias
  and group identify (plus the `*Immediate` variants), batching via `/batch/`
  with gzip, retries, `413` batch halving, `beforeSend`, `flush()` /
  `shutdown()`, and remote feature flag evaluation.
