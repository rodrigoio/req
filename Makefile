PREFIX  ?= $(HOME)/.local
BINDIR  ?= $(PREFIX)/bin
RELEASE ?= release/req.sh
TARGET  := $(DESTDIR)$(BINDIR)/req
BUILT   := $(abspath $(RELEASE))
SRC     := $(abspath bin/req)

.DEFAULT_GOAL := help
.PHONY: help test lint check build install uninstall

help: ## List the available targets
	@grep -E '^[a-z]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-10s %s\n", $$1, $$2}'
	@echo
	@echo "Variables: PREFIX=$(PREFIX) BINDIR=$(BINDIR) RELEASE=$(RELEASE)"

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

build: ## Build release/req.sh, the whole tool in one file
	@./build.sh "$(RELEASE)"

install: build ## Build, then link BINDIR/req to the built release/req.sh
	@mkdir -p "$(DESTDIR)$(BINDIR)"
	@ln -sfn "$(BUILT)" "$(TARGET)"
	@echo "installed: $(TARGET) -> $(BUILT)"
	@case ":$$PATH:" in \
		*":$(BINDIR):"*) ;; \
		*) echo "warning: $(BINDIR) is not in your PATH; add this to your shell profile:"; \
		   echo "  export PATH=\"$(BINDIR):\$$PATH\"" ;; \
	esac

uninstall: ## Remove the link, if it points to the built release/req.sh (or to bin/req, from an older install)
	@if [ -L "$(TARGET)" ] && { [ "$$(readlink "$(TARGET)")" = "$(BUILT)" ] || [ "$$(readlink "$(TARGET)")" = "$(SRC)" ]; }; then \
		rm "$(TARGET)" && echo "removed: $(TARGET)"; \
	elif [ -e "$(TARGET)" ] || [ -L "$(TARGET)" ]; then \
		echo "refused: $(TARGET) does not point to $(BUILT)"; exit 1; \
	else \
		echo "nothing to remove: $(TARGET)"; \
	fi

