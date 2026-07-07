# shellcheck shell=bash
# shellcheck disable=SC2034 # These arrays are consumed by chopi, which sources this file.
# shellcheck disable=SC2054 # Commas inside an element are intentional (e.g. --enable's value list).
#
# sandbox.sh -- sandbox configuration

# Flags passed to safehouse. Run `safehouse --help` for the full option list.
CHOPI_SAFEHOUSE_FLAGS=(
    --enable xcode,vscode,keychain
    # Verify no secrets in shell RC file before enabling!
    # --enable shell-init

    # Enable read access to additional application binaries
    # --add-dirs-ro /Applications/CMake.app:/Applications/Postgres.app

    # Enable additional read-write access
    # --add-dirs "$HOME/.cache"
)

# Extra environment for the sandboxed command, passed as literal KEY=VALUE preceding
# the sandboxed command. Use it for vars that are OK to have visible on the command line,
# allowing easy inspection of the entire configuration for the sandboxed command.
#
# You can also forward a host environment variable with FOO="$FOO"; its resolved value is
# substituted (and thus visible in the command-line).
#
# For secrets or anything else you'd rather keep off the visible command line, use safehouse's
# --env-pass NAME or --env=FILE.
#
# For GIT_CONFIG_* vars, use CHOPI_GIT_CONFIG below instead.
CHOPI_EXTRA_ENV=(
    PATH="$HOME/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1
    DISABLE_ERROR_REPORTING=1

    # Forward a host env var into the sandbox. If the host var is unset, chopi hard-errors
    # rather than forwarding an empty value, so a missing var is caught loudly:
    # FOO="$FOO"
)

# Extra git config for the sandboxed command, as key=value pairs. They are appended to the
# GIT_CONFIG_* environment inside the sandbox, so they merge with, rather than overwrite,
# git config forwarded from the host via --env-pass/--env in CHOPI_SAFEHOUSE_FLAGS above.
# A later entry wins an earlier one for the same key, so a value here overrides a forwarded
# host value for the same key.
CHOPI_GIT_CONFIG=(
    # Turn off git's automatic housekeeping in the sandbox: auto-maintenance spawned by
    # routine commands (fetch, commit, ...) touches shared .git paths the hardening
    # profile denies, generating warnings.
    gc.auto=0
    gc.worktreePruneExpire=never
    maintenance.auto=false

    # Add your own as needed, e.g.:
    # protocol.file.allow=always
)

# Setup commands for `chopi --worktree NAME`, run just before the sandboxed command starts.
# They run UNSANDBOXED, each in the worktree as the working directory, with the worktree
# name exported as CHOPI_WORKTREE_NAME. They run on every invocation -- including a reused
# worktree -- so keep each command idempotent. A failing command aborts the run.
CHOPI_WORKTREE_SETUP=(
    'git submodule update --init --recursive'

    # chopi-provided helper that pre-records the upstream branch for push and pull, because
    # the sandboxed command cannot do so (e.g. with `push -u`)
    'chopi_record_upstream'

    # Add your own as needed, e.g.:
    # 'git lfs install --local'
    # '"$HOME/my-worktree-setup.sh"'
)
