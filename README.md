# Chopi 🐶

Run an agent or any other command under a macOS sandbox that confines 
**filesystem** access and restricts outgoing **network** connections to an
explicit hosts allowlist.

This is **not** a container- or VM-based solution. Chopi runs the command
directly on your own machine with your real tools and environment, using
the OS's native sandboxing and an outbound network proxy to put guardrails
around it.

Chopi uses [**Agent Safehouse**](https://github.com/eugene1g/agent-safehouse) for building
most of the underlying macOS Seatbelt policy, and [**smokescreen**](https://github.com/stripe/smokescreen),
for the proxy.


## Install

Clone the repo and run the installer:

   ```sh
   ./install.sh
   ```

Before first use, review the configuration.


## Configuration

To add or remove allowed domains, edit `config/proxy-rules.yaml`. **Restart the proxy** if
it's already running for edits to take effect.

To configure the sandbox policy, edit `config/sandbox.sh`:

- `CHOPI_SAFEHOUSE_FLAGS`: [`safehouse`](https://github.com/eugene1g/agent-safehouse) flags
  for selecting what preset features and additional filesystem access to enable in the 
  underlying macOS Seatbelt policy; run `safehouse --help` for the full list of flags and
  additional ways to configure `safehouse` which also take effect here. `chopi` also
  automatically appends its network protection Seatbelt policy (always last, so it has the
  final word on network access).
- `CHOPI_EXTRA_ENV`: extra environment variables for the sandboxed command, passed as
  literal `KEY=VALUE` after the `--`. Use it for vars whose values are fine to be visible
  for inspection on the command line. You can also forward a host value here with `FOO="$FOO"`.
  For secrets or anything you'd rather keep off the visible command line, use `safehouse`'s
  flags `--env-pass NAME` (forward a host var by name) or `--env=FILE` (source an env file) in
  `CHOPI_SAFEHOUSE_FLAGS`.

Edits to `config/sandbox.sh` take effect on any following `chopi` invocations.

Both configuration files are created once on install and then **never overwritten**, so any
edits persist on reinstalls. When updating Chopi, you can examine the templates under
`config/templates` for any upstream changes that you might want to bring in to your local 
configuration.

`chopi` always prints the `safehouse` command that it executes, so you can inspect it for
the expected permissions. This also allows you to re-run the command and modify it inline
before committing to change more persistent configuration in `config/sandbox.sh` or any of
the other locations that `safehouse` itself provides.


## Usage

1. **Start the outgoing proxy** in its own terminal and leave it running:

   ```sh
   chopi-proxy
   ```

   All `chopi` sessions share this one proxy. It runs in the foreground so you
   can watch refused connections. Each denial also pops a macOS notification
   naming the host. (If the banners don't appear, allow notifications for your
   terminal in System Settings -> Notifications.)

   The proxy only reads the rules at startup, so after editing them **restart
   the proxy** (Ctrl-C, then `chopi-proxy` again). The new rules will take
   effect for any new connections in existing `chopi` sessions; you don't have
   to restart them (unless you need to kill an already established connection).

2. **Run your command** under the sandbox from another terminal, inside the repo
   you're working on:

   ```sh
   cd ~/path/to/your/repo
   chopi <executable> [args...]
   ```

   The sandbox grants read/write to your current directory (the workspace) and
   runs the command there. This does *not* start the proxy; it fails fast if the
   proxy isn't already up. This is intentional: this way, denials are always clearly
   visible in the separate terminal dedicated to running the proxy in the foreground.

### Advanced

To run the proxy against a different rules file, pass `chopi-proxy --rules FILE`. Keep
that file **outside** of any workspace you sandbox with chopi: a sandboxed command that 
can write its own allowlist can modify its own limits.

To use a different sandbox config for a single run, pass `chopi --config FILE`. The file 
must define the same `CHOPI_SAFEHOUSE_FLAGS` / `CHOPI_EXTRA_ENV` as `config/sandbox.sh`.
arrays. `chopi` enforces this file being **outside** of the workspace you're sandboxing,
so the confined command can't rewrite its own config (set `CHOPI_ALLOW_SELF=1` in your 
environment to downgrade the enforcement to a warning).

`chopi` lives in its own directory, outside of the repos you sandbox, so a command you 
run under it can't read or tamper with the sandbox's own config. `chopi` enforces
this, refusing to run when it finds its own folder in the workspace (and also in 
the more obscure case where the workspace is within `chopi`'s own folder). Set
`CHOPI_ALLOW_SELF=1` in your environment to downgrade the enforcement to a warning
and run anyway (useful mainly for dogfooding `chopi` for developing `chopi` itself).

## Why two layers

macOS Seatbelt (`sandbox-exec`) can confine the filesystem and pin outgoing network
connections to an IP/port, but it **cannot** filter by hostname; its network rules only
understand `localhost`/IP. Host-based filtering is therefore split across two cooperating
layers:

| Layer | Tool | Enforces |
|-------|------|----------|
| Sandbox | [`safehouse`](https://github.com/eugene1g/agent-safehouse) (wraps `sandbox-exec`) | Filesystem and preset features; the only outgoing network traffic permitted is to the local proxy at `127.0.0.1:4760`. |
| Outgoing proxy | [`smokescreen`](https://github.com/stripe/smokescreen) | Of the traffic that reaches it, only connections to allowed hosts are forwarded; everything else is refused and logged. |

Neither layer is sufficient alone: the sandbox makes the proxy the *only* way out,
and the proxy is what actually enforces the hostname rules.

The sandboxed agent must route its traffic through the proxy, i.e., respect
`HTTP_PROXY`/`HTTPS_PROXY`). The sandbox blocks all other outgoing traffic, so an agent that
ignores them gets *no* network rather than a direct connection. Most popular CLI
harnesses (Claude Code, Codex, Gemini CLI, Copilot CLI, opencode, Pi) do this by default
on current versions; a few (e.g. Cursor CLI) need `NODE_USE_ENV_PROXY=1`, which `chopi` also
sets in the sandbox env.

```
  Terminal 1 (start once, leave running)
  ──────────────────────────────────────
  $ chopi-proxy
       → smokescreen listens on 127.0.0.1:4760, enforcing config/proxy-rules.yaml

  Terminal 2 (from inside the repo you're working on)
  ───────────────────────────────────────────────────
  $ chopi <cmd> [args...]
       → safehouse builds the Seatbelt policy and runs <cmd> inside it
         (confined to your current directory), with HTTPS_PROXY=127.0.0.1:4760

  Network path of the sandboxed command:

      <cmd>
        │  Seatbelt allows outgoing connections ONLY to 127.0.0.1:4760
        ▼
      smokescreen ──(host allowed?)──────▶  api.anthropic.com / api.github.com / downloads.claude.ai
        │
        └────────(not allowed)───────────▶  refused + logged in Terminal 1
```


## Troubleshooting

- **A network connection was refused** -- First verify that the proxy is running.
  Refused hosts appear as red `DENY` lines in the log; if the host should be permitted,
  add it to `config/proxy-rules.yaml` and restart the proxy. You don't have
  to restart any of your existing `chopi` sessions: the added domains will be
  immediately allowed.
- **A non-network sandbox denial** -- See Agent Safehouse's
- [Debugging Sandbox Denials](https://agent-safehouse.dev/docs/debugging.html)
  to analyze, and amend `config/sandbox.sh` (or another `safehouse` persistent
  configuration location) accordingly.


## Development

### Changing configuration defaults

To change the default configuration a fresh install starts from, edit the templates
under `config/templates`.

### Tests

```sh
make test     # run unit and integration tests
make lint     # shellcheck the scripts
make check    # lint, then test
```
