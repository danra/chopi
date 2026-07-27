# You are running under chopi's sandbox

chopi runs this session directly on the user's machine under a macOS Seatbelt policy plus
two local proxies, and sets `CHOPI_DIR` in the environment to its own directory, which the
configuration paths below are relative to. Four things are confined:

- **Filesystem.** Read/write is limited to the workspace -- the current dir, always the root
  of a git worktree -- plus whatever the user allowed explicitly.
- **Worktrees.** Sibling worktrees of the same repo, and other repos, are unreadable. This
  is deliberate: it keeps a session from picking up context outside its assigned task.
- **Network.** The only reachable addresses are two loopback proxies. Everything else is
  blocked at the kernel level, so a request that ignores the proxies gets no network at all
  rather than a direct connection.
- **Git internals.** `.git` is readable, and git's data paths (objects, refs, index, rebase
  state) are writable, but `config`, `hooks`, and the rest are read-only, so nothing you
  write can later execute unsandboxed during a git operation. Committing, amending,
  rebasing and cherry-picking all work in-session. Pushing to the current branch also works
  for allowlisted GitHub repos (see below).

## The rule

**Denials are configuration, not bugs, and not obstacles to solve.** Every restriction
above is something the user chose. When you hit one:

1. Name exactly what was denied: the full path, or the host and port.
2. Give the user the whole fix in one message, from the table below: which file in chopi's
   directory to edit, the exact line to add, and whether it takes effect immediately, on a
   `chopi-proxy` restart, or only in a fresh chopi session.
3. Stop and wait, or continue with the parts of the task that don't need it.

Never try to get around a denial. Concretely, do not look for a mirror or an alternate host
when one is refused, do not unset or rewrite `HTTP_PROXY` / `HTTPS_PROXY`, do not try to
reach a blocked host through a different transport, and do not edit chopi's own
configuration (it is outside the sandbox and inaccessible by design). Working around a
restriction defeats the protection the user set up, and the exfiltration path you would be
opening is the exact thing it exists to prevent.

## Symptom, cause, and what to ask for

Note the third column. The three configuration files apply at different times, and telling
the user to restart the wrong thing wastes a cycle.

| Symptom | Cause | Fix, and when it takes effect |
|---|---|---|
| `Operation not permitted` / `EPERM` on a path outside the workspace | Filesystem policy | User adds `--add-dirs PATH` (or `--add-dirs-ro PATH`) to `CHOPI_SAFEHOUSE_FLAGS` in `config/sandbox.sh`. **Needs a new chopi session:** the policy is fixed when the session launches. |
| `EPERM` writing under `.git/` (`git config`, `git remote add`, `git worktree add`, `git submodule update`, hook installers like husky) | Git hardening | These cannot be made to work in-session. Ask the user to run the command **outside** the sandbox. For `--worktree` runs, recurring setup belongs in `CHOPI_WORKTREE_SETUP`. |
| A sibling worktree or another repo is unreadable | Worktree isolation | Intended. Do not ask for it to be lifted unless the task genuinely spans worktrees, in which case the user should run a session at the other worktree. |
| `Received HTTP code 407 from proxy after CONNECT`, or a refused connection to a host | The host is not on the proxy allowlist | User adds it to `config/proxy-rules.yaml`. **Hot-reloads:** no restart, retry once they confirm. Denials also appear in the terminal running `chopi-proxy`, which you cannot see, so quote the host. |
| A network call hangs or fails with no proxy error | Something bypassed the proxy environment variables | Use a client that honors `HTTP_PROXY`/`HTTPS_PROXY`. Nothing can be granted for this. |
| `chopi: push denied, repo is not in chopi's config/github-allowlist` | The repo is not allowlisted for push | User adds `owner/repo` (or `owner/*`) to `config/github-allowlist`. **Needs a `chopi-proxy` restart:** the allowlist is compiled in when the proxy starts. |
| `chopi: repo not found, or private and missing from ...` | Private repo fetch, same allowlist | Same as above. Public repo fetch needs no entry. |
| `gh` commands, or anything hitting `api.github.com` | Only git over the relay is supported for GitHub | Not available. Use plain git, or ask the user to run `gh` outside the sandbox. |
| Background tasks fail to start | The daemon needs a unix socket the policy denies; the default config also turns them off (`CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1`) | Run the command in the foreground. |

## Branch bookkeeping and the read-only config

Some branch commands update the ref and then also try to record bookkeeping in `.git/config`,
which is read-only here. The ref update lands and only the config write fails, so the
`error: could not lock config file .git/config` is harmless -- but it reads like a failure.
Use the forms that skip config:

- Push with plain `git push`, never `git push -u`: `-u` exists to record the upstream in
  config. A plain push works even when the upstream is listed as gone.
- Delete with `git update-ref -d refs/heads/NAME`, not `git branch -D`: deletion always
  tries to drop the branch's config section, even when it has none.
- Creating and force-moving branches (`git branch [-f] NAME START`, `git checkout -B`) are
  already quiet, unless START is a remote-tracking ref (`origin/...`): then git tries to
  record tracking, fails, and hints at `git branch --set-upstream-to` -- a config write that
  fails the same way. Pass `--no-track` instead: tracking cannot be recorded in-session, and
  living without it just means naming the push (`git push origin NAME`).
- Checking out a branch that exists only on the remote (a bare `git switch NAME` or
  `git checkout NAME` with only `origin/NAME`) half-works: the branch is created, but the
  switch aborts on the tracking write, leaving you where you were. Use
  `git switch -c NAME --no-track origin/NAME`; once a bare switch has already tripped, a
  second `git switch NAME` completes quietly.
- Leave renaming and copying (`git branch -m` / `-c`) to the user: the ref updates, but any
  upstream association is stranded in the config section that cannot follow it.

## Landmines

- **Never run `lsof`, `pkill`, or `fuser -k` against ports 4760 or 4761.** From inside the
  sandbox those resolve to *your own* process, not the host's proxy, so you kill your own
  session. You cannot restart the host proxy from in here either. The proxy is your only
  gateway to Anthropic's servers, so under normal circumstances, the fact you're reading
  this message means the proxy is up.
- **Do not run `chopi` or `sandbox-exec` from inside the sandbox.** Seatbelt does not nest;
  it will fail in confusing ways.
- **Do not leave a rebase or cherry-pick in progress.** chopi aborts any sequenced
  operation when the session ends, so unfinished work is lost. Finish or abort it yourself.
- **A `getcwd` or stat error while changing directory** is usually harmless policy noise,
  not a broken shell.

## Subagents you spawn

None of this reaches a subagent's system prompt, so a subagent does not know it is
sandboxed and will read a denial as a broken setup. Say what is confined in the prompt of
any subagent whose work will touch a restricted area, and diagnose its denials yourself
rather than trusting the conclusion it comes back with.
