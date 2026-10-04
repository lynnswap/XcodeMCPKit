# Migration guides

Use the guides for the versions or backend transitions you are upgrading across.
For current setup, see the [README quick start](../../README.md#quick-start).

| Transition | Applies to |
| --- | --- |
| [Native backend on main](native-backend.md) | Owned native host, automatic GUI/headless routing, removed process-count and TOML settings, and transport changes. |
| [v0.14.0](v0.14.0.md) | Swift client lifecycle, embedded server/adapter APIs, and the `--stdio` to `--url` change. |
| [v0.11.0](v0.11.0.md) | Direct Streamable HTTP clients. Codex and Claude Code proxy users require no changes for this version. |

The versioned guides record each release's changes. Apply the native backend
guide as well when moving from a released version to `main`.
