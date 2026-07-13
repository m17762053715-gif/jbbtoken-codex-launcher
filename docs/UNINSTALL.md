# Uninstallation

The launcher installs files only for the current Windows user unless the user has
explicitly redirected the relevant environment variables.

1. Close the launcher and all Codex processes.
2. Remove `%APPDATA%\JBBTokenCodexLauncher` to delete the saved launcher session and device ID.
3. Remove the launcher's isolated Codex configuration directory under `%USERPROFILE%\.codex-jbbtoken` if present.
4. Remove `%USERPROFILE%\.codex\packages\standalone` if it was installed only for this launcher.
5. Remove `%LOCALAPPDATA%\Programs\OpenAI\Codex\bin` only if it points to that standalone installation.
6. Remove that Codex `bin` directory from the current user's `PATH` if it is no longer needed.

The launcher backs up an existing conflicting junction before replacing it. Backups have
names ending in `.bak-jbb-YYYYMMDD-HHmmss` and are not removed automatically.
