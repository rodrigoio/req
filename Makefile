PREFIX  ?= $(HOME)/.local
BINDIR  ?= $(PREFIX)/bin
TARGET  := $(DESTDIR)$(BINDIR)/req
SRC     := $(abspath bin/req)

.DEFAULT_GOAL := help
.PHONY: help test lint check build install uninstall

help: ## List the available targets
	@grep -E '^[a-z]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-10s %s\n", $$1, $$2}'
	@echo
	@echo "Variables: PREFIX=$(PREFIX) BINDIR=$(BINDIR)"

test: ## Run all tests
	@tests/run.sh

lint: ## Run shellcheck (if installed) and check syntax
	@bash -n bin/req version.sh build.sh lib/*.sh tests/*.sh
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck bin/req version.sh build.sh lib/*.sh tests/*.sh; \
	else \
		echo "shellcheck not found; only the syntax was checked"; \
	fi

check: lint test ## Lint + tests

