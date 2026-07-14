.PHONY: build test lint check install github-relay-test

# Shell sources that shellcheck should analyze.
SHELL_SOURCES = \
	bin/chopi.sh \
	bin/chopi-proxy.sh \
	install.sh \
	.internal/util.sh \
	.internal/classify-log.sh \
	.internal/git-protect-wrapper.sh \
	.internal/github-relay-caddyfile.sh \
	.internal/git-layout.sh \
	.internal/git-preflight.sh \
	.internal/git-isolate.sh \
	.internal/git-harden.sh \
	.internal/git-protect.sh \
	.internal/git-protect-cleanup.sh \
	.internal/context-reads.sh \
	.internal/worktree.sh \
	.internal/preflight.sh \
	config/templates/sandbox.template.sh \
	test/lib.sh \
	test/caddyfile-lint.sh \
	test/git-protect-wrapper.sh \
	test/github-relay-caddyfile.sh \
	test/github-relay-reroute.sh \
	test/github-relay-test.sh \
	test/git-preflight.sh \
	test/git-protect-cleanup.sh \
	test/git-isolate.sh \
	test/git-harden.sh \
	test/chopi-proxy.sh \
	test/worktree.sh \
	test/preflight.sh \
	test/context-reads.sh \
	test/integration.sh

PROXY_DIR = .internal/proxy

build:
	@$(MAKE) -C $(PROXY_DIR) build

test:
	@$(MAKE) -C $(PROXY_DIR) test
	@./test/git-protect-wrapper.sh
	@./test/github-relay-caddyfile.sh
	@./test/github-relay-reroute.sh
	@./test/git-preflight.sh
	@./test/git-protect-cleanup.sh
	@./test/git-isolate.sh
	@./test/git-harden.sh
	@./test/chopi-proxy.sh
	@./test/worktree.sh
	@./test/preflight.sh
	@./test/context-reads.sh
	@./test/integration.sh

lint:
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck -s bash $(SHELL_SOURCES) && echo "shellcheck: clean"; \
	else \
		echo "shellcheck not installed -- skipping (brew install shellcheck)"; \
	fi
	@./test/caddyfile-lint.sh
	@$(MAKE) -C $(PROXY_DIR) lint

# Manual end-to-end check of the GitHub relay (not part of `make test`).
github-relay-test:
	@./test/github-relay-test.sh

check: lint test

install:
	@./install.sh
