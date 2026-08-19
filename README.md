# dsh-fork — personal fork of DeepSeek Harness

English | [中文](README.zh.md)

This is a personal fork of [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`), an open-source agent harness developed by [DeepSeek AI](https://deepseek.com) where **everything is a plugin**, powered by [Cordis](https://github.com/cordiverse/cordis).

## Differences from upstream

### Enabled LAN access / remote hosting

The upstream safety guard that rejects `--host 0.0.0.0` is removed. You can now serve the Web UI on all interfaces for LAN or tunnel access:

```sh
pnpm dsh web --host 0.0.0.0 --port 34567 --trusted-host dsh.example.com
```

Default port changed from `3080` to `34567` to avoid conflicts with common local dev servers.

### Windows GUI launchers

- **`dsh-web.pyw`** — double-clickable Python/tkinter launcher with host/port/trusted-hosts fields and Start/Stop control. Requires Python 3.10+ (tkinter built-in).
- **`dsh-web.ps1`** — PowerShell/WinForms launcher with system tray icon, balloon notifications, and background process management. Requires Windows and PowerShell 5.1+.
- **`test-launch.ps1`** — diagnostic script to verify the launcher pipeline.
- **`replace-node.ps1`** — helper to replace the global Node.js with a specific version (admin elevation required).

### Windows developer experience

- Lefthook install is skipped on Windows (platform-unsupported); stale lock files are recovered automatically.
- `package.json` scripts adapted for Windows compatibility.

### LLM retry fixes

- Quota-exceeded errors (`429`) are now retried instead of failing immediately.
- Rate-limit prioritisation fixed so the correct error type triggers backoff.
- Overall retry budget increased for production robustness.

### Subagent model inheritance

Subagents now inherit their parent's effective provider/model from the **logged request config** (the durable record after all model-selection waterfall overrides fire), rather than from the stale creation-time `AgentOptions`. This fixes the case where a parent switches model via `session.selectModel()` in the Web UI but children were created under the old model.

### Browser compatibility

`crypto.randomUUID()` replaced with `crypto.getRandomValues()` in browser-facing code, fixing crashes in non-secure-context or proxied environments.

## Run

### Run from source

```sh
git clone https://github.com/ID-VerNe/dsh-fork.git
cd dsh-fork
pnpm install
pnpm run build
pnpm dsh web
```

Or double-click `dsh-web.pyw` (Windows) for a GUI launcher.

## License

[MIT](LICENSE)

Third-party dependencies and their licenses are disclosed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
