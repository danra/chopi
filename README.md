# Chopi 🐶

Run an agent or any other command under a macOS sandbox that:
- Confines filesystem access
- Restricts outgoing network connections to allowed hosts
- Restricts git pushes to allowed repos (currently GitHub only)
- Hardens git internals

This is **not** a container- or VM-based solution. Chopi runs the command
directly on your machine with your real tools and environment, using the
OS's native sandboxing and additional network proxies to put guardrails
around it.

Chopi uses [**Agent Safehouse**](https://github.com/eugene1g/agent-safehouse) for building
most of the underlying macOS Seatbelt policy, [**Smokescreen**](https://github.com/stripe/smokescreen)
for its CONNECT proxy, and [**Caddy**](https://github.com/caddyserver/caddy) for its GitHub reverse proxy.


## Install

Clone the repo and run the installer:

   ```sh
   ./install.sh
   ```

Before first use, review the configuration.


## Configuration

To add or remove allowed domains, edit `config/proxy-rules.yaml`. You can also modify the list
of known denied domains that don't generate alerts -- important for keeping blocked telemetry,
auto-updates etc. from spamming you with notifications. You can add and remove domains while
the proxy is running and they'll take effect immediately.

To set the GitHub repos allowlist, edit `config/github-allowlist`.

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

2. **Run your command** under the sandbox from another terminal, at the root of
   the repo you're working on:

   ```sh
   cd ~/path/to/your/repo
   chopi <executable> [args...]
   ```

   The sandbox grants read/write to your current directory (the workspace) and
   runs the command there. The workspace must be the root of a git worktree,
   where `chopi`'s git protections apply; running anywhere else (a subdir, or a
   non-git directory) is refused, so you can't accidentally run "naked" without
   them. This does *not* start the proxy; it fails fast if the
   proxy isn't already up. This is intentional: this way, denials are always clearly
   visible in the separate terminal dedicated to running the proxy in the foreground.

   To run a sandboxed command in a separate git worktree instead of the repo root, you
   can either `cd` to an existing worktree and launch `chopi` as usual, or add and setup
   a new worktree by running `chopi` in `--worktree` mode:

   ```sh
   chopi --worktree NAME <executable> [args...]
   ```

   Run from the root of the repo (or a worktree), this creates a new linked worktree at
   `<repo>/.worktrees/NAME`, checks out branch `NAME` (creating it in case it doesn't already
   exist), and runs the command with that worktree folder as its workspace. Or, if the
   worktree at that path already exists, it is reused (on whatever branch or detached `HEAD`
   it has checked out), so you can resume previous sessions.

   In both normal and `--worktree` modes, `chopi` also isolates the command to a single
   worktree and applies additional hardening to prevent rogue commands compromising the
   host system.

   ### Git Protection in Detail

   The workspace is always the root of a git repo (main worktree) or a linked worktree
   (including `--worktree` mode). `chopi` isolates access to that worktree, which keeps an
   agent from wandering outside its assigned task and picking up irrelevant information
   from another worktree. This undoes safehouse's own default grants to all other worktrees.
   Read access is also granted to specific allowlisted Claude context files (currently
   `CLAUDE.md`) in folders above the repo.

   In addition, `chopi` hardens the repo's git internals: `.git` stays readable, but only
   git's data paths (objects, refs, index, etc.) are writable. Everything else (`config`,
   `hooks`, etc.) stays read-only, so the sandboxed command can't plant code that could
   later run *unsandboxed* on some git operation. Submodules (recursive) get the same
   treatment one level down.

   Operations that write to the denied paths fail inside the sandbox: repo-local
   `git config`, `git remote add`, `git worktree add`, `git submodule update` (git
   insists on rewriting `core.worktree` in the submodule's read-only config), and
   hook installers (e.g. husky), so run these outside the sandbox. For `--worktree`
   runs, `chopi` provides the `CHOPI_WORKTREE_SETUP` config to set commands to run
   before the sandboxed command starts. The default initializes and updates submodules
   and pre-sets the upstream for `push`/`pull` (`push -u` can't write the upstream
   to the config while sandboxed).

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
   and names the cause: a workspace that is not the root of a git worktree;
   git location overrides in the environment (`GIT_DIR`,
   `GIT_WORK_TREE`) or in the repo's own files (`core.worktree`, `core.bare`, a corrupt
   `.git` entry) that make git resolve the workspace root away from where it physically
   is; object reads through an external store (a non-empty `.git/objects/info/alternates`,
   also in submodule git dirs); and relocated ref storage (`extensions.refStorage` with a
   URI payload).

   On termination, `chopi` aborts any in-progress sequenced rebase or cherry-pick: resuming
   one outside of the sandbox could execute rogue `exec` lines injected into the todo list,
   with no warning in `git status`, and without expecting a rebase to be able to execute
   code unless that's a feature the user is familiar with. The abort runs inside the sandbox
   so anything possibly triggered by the cleanup itself stays confined. `chopi` also refuses
   to start when a sequenced operation is in progress to avoid losing the state on exit.

### Advanced

To run the proxy against a different rules file, pass `chopi-proxy --rules FILE`. Keep
that file **outside** of any workspace you sandbox with chopi: a sandboxed command that 
can write its own allowlist can modify its own limits.

To use a different sandbox config for a single run, pass `chopi --config FILE`. The file 
must define the same `CHOPI_SAFEHOUSE_FLAGS` / `CHOPI_EXTRA_ENV` arrays as `config/sandbox.sh`
(plus `CHOPI_WORKTREE_SETUP` for `--worktree` runs; `CHOPI_GIT_CONFIG` is optional).
`chopi` enforces this file being **outside** of the workspace you're sandboxing,
so the confined command can't rewrite its own config (set `CHOPI_ALLOW_SELF=1` in your
environment to downgrade the enforcement to a warning).

`CHOPI_GIT_CONFIG` sets extra git config for the sandboxed command, as `key=value` pairs
(e.g. `protocol.file.allow=always`). It's applied through git's `GIT_CONFIG_*` environment
variables, appended *inside* the sandbox after the environment is fully composed, so the
pairs merge with any git config you forward from the host via `safehouse`'s
`--env-pass`/`--env` flags instead of overwriting it (in case of a conflict,
`CHOPI_GIT_CONFIG` wins).

`chopi` lives in its own directory, outside of the repos you sandbox, so a command you 
run under it can't read or tamper with the sandbox's own config. `chopi` enforces
this, refusing to run when it finds its own folder in the workspace (and also in 
the more obscure case where the workspace is within `chopi`'s own folder).

## Why the macOS sandbox isn't enough

macOS Seatbelt (`sandbox-exec`) can confine the filesystem and pin outgoing network
connections to an IP/port, but it **cannot** filter by hostname; its network rules only
understand `localhost`/IP. It obviously can't filter by repo, either. Filtering is
therefore split across cooperating layers:

| Layer | Tool | Enforces |
|-------|------|----------|
| Sandbox | [`safehouse`](https://github.com/eugene1g/agent-safehouse) (wraps `sandbox-exec`) | Filesystem and preset features; the only outgoing network permitted is to the local proxies at `127.0.0.1:4760` (smokescreen) and `:4761` (the GitHub relay). |
| Domain-level proxy | [`smokescreen`](https://github.com/stripe/smokescreen) (CONNECT proxy) | Of the traffic that reaches it, only connections to allowed hosts are forwarded; everything else is refused and logged. |
| GitHub repo-level proxy | [`caddy`](https://caddyserver.com) (reverse proxy) | `github.com` git is reached *only* through this relay, which scopes it to a repo allowlist: fetching a **public** repo is unrestricted, but reading a **private** repo and **any push** are limited to allowlisted repos. |

**The sandbox** makes the proxies the *only* way to communicate over the network.

**The domain-level proxy** allows communication only with trusted hosts, so a rogue
agent can't connect anywhere else to exfiltrate user data. Be careful not to add
innocent domains that can still be abused by an attacker for exfiltration! (e.g.
pastebin.com)

**The repo-level proxy** exists to prevent a misbehaving agent pushing stolen code to
*any* repo on GitHub (possibly using an attacker-provided token). Currently, this
protection layer only supports GitHub; other repo-hosting domains can be allowlisted by
domain, but be aware of the exfiltration risk. `gh` and GitHub's API are still
unsupported.

The sandboxed agent must route its traffic through the proxy, i.e., respect
`HTTP_PROXY`/`HTTPS_PROXY`). The sandbox blocks all other outgoing traffic, so an agent that
ignores them gets *no* network rather than a direct connection. Most popular CLI
harnesses (Claude Code, Codex, Gemini CLI, Copilot CLI, opencode, Pi) do this by default
on current versions; a few (e.g. Cursor CLI) need `NODE_USE_ENV_PROXY=1`, which `chopi` also
sets in the sandbox env.

Network path of the sandboxed command:

```
<cmd>
  │  Seatbelt allows outgoing connections ONLY to 127.0.0.1:{4760,4761}
  ├─ github.com (git) ─── 4761 ────▶ caddy relay ─(repo allowlisted?)─▶ GitHub
  │                                   └─ public fetch: any repo · private fetch or push: allowlisted only
  └─ everything else ──── 4760 ────▶ smokescreen ─(host allowed?)─▶ api.anthropic.com / ...
                                          └────(not allowed)────▶ refused + logged
```


## Troubleshooting

- **A network connection was refused** -- First verify that the proxy is running.
  Refused hosts appear as red `DENY` lines in the log (or as a single plain
  `deny(known)` line if they match the known denylist); if the host should be allowed,
  add it to `config/proxy-rules.yaml`. The proxy hot-reloads the rules, so you don't
  need to restart it.
- **A non-network sandbox denial** -- See Agent Safehouse's
- [Debugging Sandbox Denials](https://agent-safehouse.dev/docs/debugging.html)
  to analyze, and amend `config/sandbox.sh` (or another `safehouse` persistent
  configuration location) accordingly.


## Development

### Changing configuration defaults

To change the default configuration a fresh install starts from, edit the templates
under `config/templates`.

### The proxy binary

The proxy is an in-repo Go wrapper, `.internal/proxy/`, that embeds smokescreen as a
library and hot-reloads the rules file (the standalone smokescreen binary only reads
its rules at startup). `install.sh` and `make build` compile it to
`.internal/proxy/chopi-smokescreen`.

### Tests

```sh
make build    # build the proxy binary (needs go)
make test     # build, then run unit and integration tests
make lint     # shellcheck the scripts, go vet the proxy
make check    # lint, then test
```

### Dogfooding Chopi

By default, `chopi`'s refuses protecting a workspace that overlaps `chopi`s folder;
set `CHOPI_ALLOW_SELF=1` to override when developing `chopi`.
