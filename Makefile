.PHONY: test lint check install

# Shell sources that shellcheck should analyze.
SHELL_SOURCES = \
	bin/chopi.sh \
	bin/chopi-proxy.sh \
	install.sh \
	.internal/util.sh \
	.internal/classify-log.sh \
	.internal/append-git-config.sh \
	.internal/git-layout.sh \
	.internal/git-preflight.sh \
	.internal/git-isolate.sh \
	.internal/git-harden.sh \
	.internal/git-protect.sh \
	.internal/worktree.sh \
	.internal/preflight.sh \
	config/templates/sandbox.template.sh \
	test/lib.sh \
	test/append-git-config.sh \
	test/git-preflight.sh \
	test/git-isolate.sh \
	test/git-harden.sh \
	test/chopi-proxy.sh \
	test/worktree.sh \
	test/preflight.sh \
	test/integration.sh

test:
	@./test/append-git-config.sh
	@./test/git-preflight.sh
	@./test/git-isolate.sh
	@./test/git-harden.sh
	@./test/chopi-proxy.sh
	@./test/worktree.sh
	@./test/preflight.sh
	@./test/integration.sh

lint:
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck -s bash $(SHELL_SOURCES) && echo "shellcheck: clean"; \
	else \
		echo "shellcheck not installed -- skipping (brew install shellcheck)"; \
	fi

check: lint test

install:
	@./install.sh
