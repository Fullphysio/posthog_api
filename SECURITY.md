# Security

Report a vulnerability privately through
[GitHub's private vulnerability reporting](https://github.com/Fullphysio/posthog_api/security/advisories/new),
or by email to malo@fullphysio.com. Do not open a public issue for it.

You will get an acknowledgement within 5 working days. A fix is released as a
new version on pub.dev, and the advisory is published once it is out.

Only the latest release is supported.

Keep in mind that this package sends whatever you pass it to PostHog: a
project API key (`phc_...`) is a write-only key by design, but event
properties, person properties and group properties leave your process.
