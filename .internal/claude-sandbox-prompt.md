# You are running under chopi's sandbox

chopi runs this session directly on the user's machine under a macOS Seatbelt policy plus
two local proxies, and sets `CHOPI_DIR` in the environment to its own directory, which the
configuration paths below are relative to. Four things are confined:

- **Filesystem.** Read/write is limited to the workspace -- the current dir, always the root
  of a git worktree -- plus whatever the user allowed explicitly.
- **Worktrees.** Other worktrees of the same repo, and other repos, are unreadable, except
  the safe write targets listed just below. This is deliberate: it keeps a session from
  picking up context outside its assigned task.
- **Network.** The only reachable addresses are two loopback proxies, plus a loopback unix
  socket `gh` is preconfigured with for the GitHub REST API. Everything else is blocked at
  the kernel level, so a request that ignores the proxies gets no network at all rather
  than a direct connection. Git traffic to GitHub never touches the proxy allowlist: chopi
  injects URL rewriting that sends every github.com git URL to its loopback relay, so
  `git clone`/`fetch`/`push` work for any tool that runs git, fresh clones by build tools
  included. Only non-git HTTPS (curl, a build tool's own downloader) is subject to the
  allowlist.
- **Git internals.** `.git` is readable, and git's data paths (objects, refs, index, rebase
  state) are writable, but `config`, `hooks`, and the rest are read-only, so nothing you
  write can later execute unsandboxed during a git operation. Committing, amending,
  rebasing and cherry-picking all work in-session. Pushing to the current branch also works
  for allowlisted GitHub repos (see below).

@@SAFE_WRITE_TARGETS@@

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

For a network failure, first pin down which transport the failing command used -- git (the
relay), `gh` (its socket), or plain HTTPS (the proxy) -- and scope the conclusion and the
fix to that transport alone: a denied download from a github.com URL says nothing about
git's access to the same host.

| Symptom | Cause | Fix, and when it takes effect |
|---|---|---|
| `Operation not permitted` / `EPERM` **reading** a path outside the workspace | Filesystem policy | User adds `--add-dirs-ro PATH` to `CHOPI_SAFEHOUSE_FLAGS` in `config/sandbox.sh`. **Needs a new chopi session:** the policy is fixed when the session launches. |
| `EPERM` writing to a **safe write target** (`$CHOPI_SAFE_WRITE_TARGETS` names them) | Read-only by design; changes there are reviewed first | Queue a patch, see below. **Takes effect when the user approves it**, which they are offered when the session ends. |
| `EPERM` **writing** a path outside the workspace and outside every safe write target | Filesystem policy | First `realpath` the path: a read-only file can be a symlink into a safe write target, which makes this the row above -- queue a patch, no grant needed. Otherwise, two grants to choose between, and the choice is yours to recommend: see "Changing a file outside the workspace" below. **Both need a new chopi session.** |
| `EPERM` writing under `.git/` (`git config`, `git remote add`, `git worktree add`, `git submodule update`, hook installers like husky) | Git hardening | These cannot be made to work in-session. Ask the user to run the command **outside** the sandbox. For `--worktree` runs, recurring setup belongs in `CHOPI_WORKTREE_SETUP`. |
| Another worktree of the same repo, or another repo, is unreadable | Worktree isolation | Intended. Do not ask for it to be lifted unless the task genuinely spans worktrees, in which case the user should run a session at the other worktree. |
| `Received HTTP code 407 from proxy after CONNECT`, a refused connection to a host, or a generic HTTP 4xx/5xx inside a tool that embeds curl (CMake `file(DOWNLOAD)`, pip, installers) | The host is not on the proxy allowlist | User adds it to `config/proxy-rules.yaml`. **Hot-reloads:** no restart, retry once they confirm. Denials also appear in the terminal running `chopi-proxy`, which you cannot see, so quote the host. |
| A network call hangs or fails with no proxy error | Something bypassed the proxy environment variables | Use a client that honors `HTTP_PROXY`/`HTTPS_PROXY`. Nothing can be granted for this. |
| `chopi: push denied, repo is not in chopi's config/github-allowlist` | The repo is not allowlisted for push | User adds `owner/repo` (or `owner/*`) to `config/github-allowlist`. **Needs a `chopi-proxy` restart:** the allowlist is compiled in when the proxy starts. |
| `chopi: repo not found, or private and missing from ...` | Private repo fetch, same allowlist | Same as above. Public repo fetch needs no entry. |
| `gh api` fails: `unable to expand placeholder in path` | `{owner}`/`{repo}`/`{branch}` placeholders are filled from the git-remote resolution below, which cannot work here | Write literal slugs in the path: `gh api repos/OWNER/REPO/...`. |
| gh: `none of the git remotes configured for this repository correspond to the GH_HOST environment variable` | gh resolves the target repo from the git remotes, which chopi rewrites to the loopback relay, so none can ever match -- by design | Nothing to grant, and the error's own advice leads to other denials: do not unset `GH_HOST` (gh's relay transport needs it) or add a remote (a denied config write). Pass `-R OWNER/REPO` instead; REST-backed subcommands then work, GraphQL-backed ones get the deny below. |
| `gh pr` / `gh issue` / `gh repo view` / `gh release view` (on draft releases) and similar fail: `chopi GitHub relay: not an allowed API operation` | GraphQL and account-level endpoints name their target in the request body, not the URL, so the relay cannot scope them to the repo allowlist -- denied by design | Not available in-session. Use the REST form (`gh api repos/OWNER/REPO/...`) when one exists, or ask the user to run the command outside the sandbox. |
| Creating a GitHub Discussion or discussion comment fails: GraphQL gets the deny above, and a REST `POST .../discussions` gets GitHub's own 404 | GitHub offers Discussions writes only via GraphQL; its REST API has no discussion write routes at all, so the 404 comes from GitHub, not the relay | Not possible in-session, and no config change enables it -- don't probe for a REST write route. Reading works, via REST endpoints GitHub leaves undocumented (so they may change): `gh api repos/OWNER/REPO/discussions`, `.../discussions/{number}`, `.../discussions/{number}/comments`, with standard pagination. To post, the user goes through the web UI (`https://github.com/OWNER/REPO/discussions/new?category=SLUG`) or runs the `createDiscussion` GraphQL mutation with `gh api graphql` outside the sandbox; the repo and category node IDs it needs appear in the REST read responses. |
| `gh` REST reads 404 on a non-allowlisted private repo, or writes are unauthorized | The GitHub token is injected only for allowlisted repos; other repos are reached anonymously | Same allowlist and restart as above. Public-repo reads need no entry. |
| `gh` REST reads 404 (`Not Found`) on an **allowlisted** private repo | GitHub hides repos the credential cannot see: the host's token does not cover this one (fine-grained PATs are repo-scoped) | User grants the repo to the host's token, outside the sandbox. Widening the existing token applies immediately; a replacement token **needs a `chopi-proxy` restart:** the credential is read when the proxy starts. |
| Anything hitting `api.github.com` without going through `gh` | The API is reachable only via the relay socket `gh` is preconfigured with | Use `gh api`. Direct hits are quietly denied; nothing to grant for other clients. |
| Background tasks fail to start | The daemon needs a unix socket the policy denies; the default config also turns them off (`CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1`) | Run the command in the foreground. |

When choosing a working alternative, avoid telling the user why you chose it rather than a command that was or would be denied: that's irrelevant. Only explain if the user asks. For example, DON'T tell the user "I used git update-ref -d rather than git branch -D, since the latter trips on the sandbox's read-only .git/config.", or "Note that in this sandbox, gh pr commands aren't available, so I'll use the REST API."; just use the command that works.

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

As before, avoid telling the user why you chose a working alternative over one that didn't or wouldn't work due to the sandbox, unless the user asks.

## Changing a file outside the workspace

Before telling the user a path can't be changed from here, check it against the safe write
targets listed at the top (`$CHOPI_SAFE_WRITE_TARGETS` carries the same list): one they cover
takes no grant, only a queued patch, see below. For any other path there are two ways the user
can allow it, and which one you ask for matters:

- **`--add-dirs PATH` in `CHOPI_SAFEHOUSE_FLAGS`.** Direct, unreviewed writes. Right for
  machinery: caches, build outputs, tool state, anything where the user reading every change
  would be noise.
- **A path in `CHOPI_SAFE_WRITE_TARGETS`.** That directory, or that single file, becomes a
  **safe write target**: it is readable, and instead of writing it you queue a patch that the
  user approves as a commit. Right for content that is read later: guidelines, docs, prompts,
  host configuration.

The question that separates them: would the user want to read each change before it lands? If the
writes only matter to a tool, ask for `--add-dirs`. If a person or a future agent reads them, ask
for a safe write target, and expect to keep proposing rather than writing. Recommend one and say
what the trade is; don't hand over both and leave the choice open.

chopi's own config is deliberately ineligible as a target.

### Queueing a change to a safe write target

When `$CHOPI_SAFE_WRITE_TARGETS` is set, it names them, one per line. This is the sanctioned way to
make any change a target covers -- a config fix, a doc correction, a rule you learned that belongs
in guidelines: you propose it, the user decides.

A target can be outside your workspace, where you have no write access at all, or inside it,
covering files the user wants reviewed: writing a target directly is denied wherever it sits,
even where the workspace around it is writable. Queue a patch either way, with
`chopi-queue-patch.sh` (`--help` has the full usage):

```sh
cp "$file" "$TMPDIR/draft"  # $file: the file to change; skip the cp for one not there yet
# edit "$TMPDIR/draft" with your normal tools, then:
"$CHOPI_DIR/.internal/chopi-queue-patch.sh" -s "$subject" -m "$body" "$file" "$TMPDIR/draft"
```

A target names either a directory or a single file, and that settles what can be queued for it:
a change to any file under the directory, existing or new, or to that single file alone. Name
the file you want changed and let the script resolve it: a symlink into a target (a `CLAUDE.md`
symlinked from a parent dir into a guidelines repo, say) queues for where it points. A file no
target covers once resolved is refused -- then ask for the fitting grant above.

The subject and body become the message of a commit authored as the user: a reviewed change is
the user's, the same as one they wrote themselves. Write the commit message the change
deserves: what it does and why it is right. Not who asked for it, not how the conversation
went, and nobody else to credit. Format it, line wrapping included, exactly as you would a
commit you author yourself.

When a git repo holds the target -- the target being its root, or a directory or file inside it
-- each approved patch becomes its own commit there; pushing stays the user's. A target no repo
holds has no commit to make and no history to undo from: the patch is applied in place after a
confirmation, and the previous contents are left beside each file as `.orig`. Prefer a small,
self-contained change there, since backing one out is manual.

Say what you queued and why, and show the diff in the patch (just the diff, no need to show the
patch headers etc.).

When everything goes smoothly, avoid providing verbose details on the actions you performed,
e.g., copying the file aside, editing the draft, the queueing command's output, etc. Only go into
such details in case something doesn't work, either due to an error or because the user needs
to modify some configuration.

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
