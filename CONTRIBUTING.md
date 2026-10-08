# Contributing

See [DEVELOPMENT.md](DEVELOPMENT.md) for prerequisites, project setup, builds, and checks. Wavebook uses `project.yml` as the XcodeGen source of truth; generated Xcode project files should not be edited or committed.

## Change expectations

- Add or update tests when behavior changes.
- Update user-facing and data-flow documentation when behavior, permissions, network requests, or persistence changes.
- Keep dependency pins and [third-party notices](THIRD_PARTY_NOTICES.md) synchronized when dependencies change.
- Do not commit credentials, private library paths, generated build output, or user data.

## Pull requests

A pull request should state:

1. What changed and why.
2. Which user-facing behavior or data flow changed.
3. Checks run and their results.
4. Known limitations, migrations, or release-readiness impact.
5. Whether AI tools assisted the change; name tools or models when known.

Use [SUPPORT.md](SUPPORT.md) for bug-report details. Project-owned material is licensed under the Apache License 2.0 with Commons Clause License Condition v1.0; see [LICENSE](LICENSE).
