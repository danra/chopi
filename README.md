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

To add or remove allowed domains, edit `config/proxy-rules.yaml`. You can also modify the list
of known denied domains that don't generate alerts -- important for keeping blocked telemetry,
auto-updates etc. from spamming you with notifications. **Restart the proxy** if it's already
running for edits to take effect.

To configure the sandbox policy, edit the first two settings in `config/sandbox.sh` (other
settings can be reviewed later):

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


## Usage

1. **Start the outgoing proxy** in its own terminal and leave it running:

   ```sh
   chopi-proxy
   ```

   All `chopi` sessions share this one proxy. It runs in the foreground so you
   can watch refused connections. Each denial also pops a macOS notification
   naming the host. (If the banners don't appear, allow notifications for your
   terminal in System Settings -> Notifications.) Hosts matching the known denylist
   are the exception: their denials log a single quiet `deny(known)` line per
   proxy run, with no notification.

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

   When run in a git repo, `chopi` also isolates the command to a single worktree
   and applies additional hardening to prevent rogue commands compromising the host
   system.

   ### Git Protection in Detail

   When the workspace is the root of a git repo (main worktree) or a linked worktree,
   `chopi` isolates access to that worktree, which keeps an agent from wandering
   outside its assigned task and picking up irrelevant information from another worktree.
   This undoes safehouse's own default grants to all other worktrees.
   A submodule's root counts as a main worktree of its own repo: its git dir lives under
   the superproject's `.git/modules/`, and `chopi` grants exactly that subtree (hardened
   like any shared git dir) while the rest of the superproject stays out of reach. A repo
   whose git dir was detached with `git init --separate-git-dir` gets the same treatment.

   In addition, `chopi` hardens the repo's git internals: `.git` stays readable, but only
   git's data paths (objects, refs, index, etc.) are writable. Everything else (`config`,
   `hooks`, etc.) stays read-only, so the sandboxed command can't plant code that could
   later run *unsandboxed* on some git operation. Submodules (recursive) get the same
   treatment one level down.

   Operations that write to the denied paths fail inside the sandbox: repo-local
   `git config`, `git remote add`, `git worktree add`, `git submodule update` (git
   insists on rewriting `core.worktree` in the submodule's read-only config), and
   hook installers (e.g. husky). Run these outside the sandbox; for config keys the
   sandboxed command needs, use `CHOPI_GIT_CONFIG` in `config/sandbox.sh`.

   The writable data paths in the common git dir mean the worktree isolation isn't
   perfect and agents still have access to, e.g., objects and refs only used in other
   worktrees; but the worktree isolation's goal is more about minimizing agent errors
   anyway.

   Hardening-wise, being able to write internal data that another worktree references
   is certainly a risk, but it's required given git's implementation. Hardening should
   therefore be considered as applying to the repo as a whole, not to a specific
   worktree; it's not safe to assume other worktrees remained untouched by a sandboxed
   session.

   Rather than launch a run these protections cannot cover, `chopi` refuses to start
   and names the cause: git location overrides in the environment (`GIT_DIR`,
   `GIT_WORK_TREE`) or in the repo's own files (`core.worktree`, `core.bare`, a corrupt
   `.git` entry) that make git resolve the workspace root away from where it physically
   is; object reads through an external store (a non-empty `.git/objects/info/alternates`,
   also in submodule git dirs); and relocated ref storage (`extensions.refStorage` with a
   URI payload).

### Advanced

To run the proxy against a different rules file, pass `chopi-proxy --rules FILE`. Keep
that file **outside** of any workspace you sandbox with chopi: a sandboxed command that 
can write its own allowlist can modify its own limits.

To use a different sandbox config for a single run, pass `chopi --config FILE`. The file 
must define the same `CHOPI_SAFEHOUSE_FLAGS` / `CHOPI_EXTRA_ENV` arrays as `config/sandbox.sh`
(`CHOPI_GIT_CONFIG` is optional). `chopi` enforces this file being **outside** of the
workspace you're sandboxing, so the confined command can't rewrite its own config (set
`CHOPI_ALLOW_SELF=1` in your environment to downgrade the enforcement to a warning).

`CHOPI_GIT_CONFIG` sets extra git config for the sandboxed command, as `key=value` pairs
(e.g. `protocol.file.allow=always`). It's applied through git's `GIT_CONFIG_*` environment
variables, appended *inside* the sandbox after the environment is fully composed, so the
pairs merge with any git config you forward from the host via `safehouse`'s
`--env-pass`/`--env` flags instead of overwriting it (in case of a conflict,
`CHOPI_GIT_CONFIG` wins).

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
  Refused hosts appear as red `DENY` lines in the log (or as a single plain
  `deny(known)` line if they match the known denylist); if the host should be allowed,
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
