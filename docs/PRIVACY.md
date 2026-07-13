# Privacy Policy

Last updated: 2026-07-13

## Data processed locally

The launcher may process the following data on the user's Windows device:

- JBBToken username and password entered for authentication;
- optional two-factor authentication or email verification codes;
- a randomly generated launcher device identifier;
- JBBToken user ID, username, access token, wallet information, and API connection settings;
- Codex CLI configuration and authentication state;
- local diagnostic status and request error messages.

The launcher stores a random device identifier and the current JBBToken desktop session
under `%APPDATA%\JBBTokenCodexLauncher`. The saved access token is protected with Windows
user-scoped DPAPI and is not written to the repository or build artifacts.

## Network transfers

When the user signs in, registers, checks wallet/API status, creates a recharge order,
or configures Codex, the launcher sends the information required for that action over
HTTPS to JBBToken-operated endpoints under `downstream.jbbtoken.cn`, `jbbtoken.cn`, or
`jbbt.cc`. API connectivity tests send the user's API credential to the configured API
base URL selected or returned for that user.

The build process downloads the pinned OpenAI Codex CLI release from GitHub. Runtime use
of Codex may send prompts and related request data to the configured API provider as
initiated by the user.

## User control

The launcher does not perform these network actions until the user opens or uses the
corresponding feature. Users can remove locally stored launcher session data and the
isolated Codex configuration by following [UNINSTALL.md](UNINSTALL.md).

## Contact

Service and privacy questions can be submitted through <https://jbbtoken.cn/>.
