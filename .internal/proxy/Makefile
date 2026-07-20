.PHONY: build test lint

# chopi's proxy binary: smokescreen embedded as a library and extended to hot-reload
# the rules file (see main.go). Each recipe is guarded on `go`: skip with a hint rather
# than fail when it is missing, matching how the parent Makefile guards shellcheck.
BINARY = chopi-smokescreen

build:
	@if command -v go >/dev/null 2>&1; then \
		go build -o $(BINARY) . && echo "$(BINARY): built"; \
	else \
		echo "go not installed -- skipping the proxy build (brew install go)"; \
	fi

test: build
	@if command -v go >/dev/null 2>&1; then \
		go test -v ./...; \
	else \
		echo "go not installed -- skipping the proxy tests (brew install go)"; \
	fi

lint:
	@if command -v go >/dev/null 2>&1; then \
		go vet ./... && echo "go vet: clean"; \
	else \
		echo "go not installed -- skipping go vet (brew install go)"; \
	fi
