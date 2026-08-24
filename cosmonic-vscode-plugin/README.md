# Cosmonic for VS Code

Cosmonic Desktop inside your editor: scaffold WebAssembly component projects,
run them in the confined local sandbox with one click, watch logs and metrics,
and give AI agents safe tools over MCP.

> Requires [Cosmonic Desktop](https://cosmonic.com/desktop) (free — macOS,
> Windows, Linux). The extension talks to its local daemon; no cloud account
> needed.

## Features

| Feature | What it does |
|---|---|
| **Workloads view** | Every sandbox workload with live status, exports, and granted capabilities. Rows carry Cosmonic Desktop's Tools-column vocabulary inline: Open in browser · MCP Inspector (MCP servers) · Logs in Desktop · Inspect; start/stop/restart, manifest, Output-panel logs, and delete on right-click. |
| **MCP Inspector** | The robot button on any MCP workload opens the MCP Inspector — the same one Cosmonic Desktop bundles — already connected to that server's endpoint (localhost-only, session token on). |
| **One-click deploy** | The rocket in the editor title starts the sandbox dev loop for the current project — build, run, watch. Every save hot-swaps the running component. |
| **Workload detail** | An editor tab per workload: overview, live invocation sparklines, streaming logs with level filter and search, and point-in-time stats. Logs are also mirrored to the Output panel. |
| **Templates** | `Cosmonic: New Cosmonic Project…` (also under **File → New File…**) scaffolds Rust / Go / TypeScript HTTP or MCP components from the daemon's template catalog — offline-capable via a local cache. |
| **Tasks** | A `cosmonic` task type per project: `dev` (sandbox dev loop) and `build` (the project's own build command with problem matching). |
| **MCP for agent mode** | Registers Cosmonic Desktop's MCP server with VS Code — agents get `cosmonic_*` tools (deploy, logs, inspect, scaffold) with correct read-only annotations, no manual config. |
| **Agent terminals** | `Cosmonic: New Sandboxed Agent Terminal` launches an installed agent CLI (Claude Code, Codex, Gemini, …) with the Cosmonic sandbox as its execution substrate. |
| **Status bar** | `$(vm-active) Cosmonic: N running` — click to open the sidebar. Distinct states for stopped, starting, and unreachable. |

## How it connects

Everything rides the Cosmonic Desktop daemon API over its local socket
(`cosmonicd.sock` / named pipe on Windows) — filesystem-permission auth, no
tokens, no network. The only network calls the extension makes are opening
your workload's own `http://<name>.localhost.cosmonic.sh:<port>` endpoints in
the browser when you ask.

Inspect and MCP-Inspector hand off to the Cosmonic Desktop app via its
`cosmonic://` deep links rather than re-implementing those screens.

## What this extension does not do

- **No Cosmonic Cloud** — local sandbox only; no auth, no remote deploys.
- **No WIT language tooling** — it depends on the
  [WIT IDL](https://marketplace.visualstudio.com/items?itemName=BytecodeAlliance.wit-idl)
  extension for syntax support rather than shipping a competing grammar.
- **No debugger, no registry publishing UI, no remote resolvers.**
- **No telemetry.** The extension sends nothing anywhere.

## Settings

| Setting | Default | Purpose |
|---|---|---|
| `cosmonic.stateDir` | _(platform default)_ | Override the daemon state directory (mirrors `COSMONIC_STATE_DIR`). |
| `cosmonic.deploy.openDetail` | `true` | Open the workload detail tab after deploy. |
| `cosmonic.agents.additionalClis` | `[]` | Extra agent CLI names to offer in agent terminals. |



## Installing

The Bytecode Alliance WIT IDL highlighting is a dependency

The from the command line:

```
code --install-extension ./wit-idl-0.3.34.vsix
code --install-extension ./cosmonic-vscode-0.1.0.vsix
```

- VS Code UI: Extensions panel → ⋯ menu → "Install from VSIX…" → select the file

Install from GitHub Repository (Once published)

## License
Cosmonic Proprietary
