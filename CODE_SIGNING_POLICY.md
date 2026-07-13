# Code signing policy

Free code signing provided by [SignPath.io](https://signpath.io/), certificate by
[SignPath Foundation](https://signpath.org/).

## Roles

- **Committers and reviewers:** [m17762053715-gif](https://github.com/m17762053715-gif).
- **Approvers:** [m17762053715-gif](https://github.com/m17762053715-gif).

## Build and signing rules

1. Release artifacts are built on GitHub-hosted Windows runners from the source and
   workflow committed to this repository.
2. The OpenAI Codex CLI archive is downloaded from the pinned upstream GitHub release
   and verified against its pinned SHA-256 digest before packaging.
3. No private signing key is stored in this repository or in build artifacts.
4. Every signing request requires manual approval by an approver.
5. Only artifacts produced by the repository's release workflow may be submitted for signing.
6. Changes to build scripts, workflows, dependency versions, network endpoints, or
   authentication logic require review before release.

## Privacy policy

See [docs/PRIVACY.md](docs/PRIVACY.md).
