# JBBToken Codex Launcher

Windows x64 launcher for installing the official OpenAI Codex CLI offline,
connecting it to a user-selected JBBToken account, and keeping the launcher's
Codex configuration isolated from the user's default `~/.codex` directory.

## Features

- Installs the official OpenAI Codex CLI Windows x64 package after SHA-256 verification.
- Signs in to JBBToken and obtains the current user's API connection settings.
- Stores the JBBToken desktop session with Windows user-scoped DPAPI protection.
- Writes Codex configuration into an isolated launcher directory.
- Provides API connectivity checks, wallet status, recharge entry points, and launch controls.

## Build

Requirements: Windows 10/11, Windows PowerShell 5.1, and IExpress (included with Windows).

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build-Installer.ps1
```

The build downloads the official OpenAI Codex CLI `0.142.2` Windows x64 package,
verifies SHA-256, and writes the installer to `artifacts/`.

## Verification

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-Source.ps1
Get-FileHash .\artifacts\JBBToken-Codex-Setup-v1.1.34-dropdown-panel-win64.exe -Algorithm SHA256
```

## Privacy and system changes

See [Privacy Policy](docs/PRIVACY.md) and [Uninstallation](docs/UNINSTALL.md).

## Code signing policy

Free code signing provided by [SignPath.io](https://signpath.io/), certificate by
[SignPath Foundation](https://signpath.org/).

- Committers and reviewers: repository maintainers with write access.
- Approvers: repository owners.
- Every release signing request requires manual approval.
- Release binaries must be produced by the GitHub Actions workflow from this repository.

See [CODE_SIGNING_POLICY.md](CODE_SIGNING_POLICY.md) for the complete policy.

## License

The launcher is licensed under the [MIT License](LICENSE). The downloaded OpenAI
Codex CLI package is a third-party component; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
