PREFIX  ?= $(HOME)/.local
BINDIR  ?= $(PREFIX)/bin
TARGET  := $(DESTDIR)$(BINDIR)/req
SRC     := $(abspath bin/req)

.DEFAULT_GOAL := help
.PHONY: help test lint check container install uninstall

help: ## List the available targets
	@grep -E '^[a-z]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-10s %s\n", $$1, $$2}'
	@echo
	@echo "Variables: PREFIX=$(PREFIX) BINDIR=$(BINDIR)"

test: ## Run all tests
	@tests/run.sh

lint: ## Run shellcheck (if installed) and check syntax
	@bash -n bin/req lib/*.sh tests/*.sh
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck bin/req lib/*.sh tests/*.sh; \
	else \
		echo "shellcheck not found; only the syntax was checked"; \
	fi

check: lint test ## Lint + tests

container: ## Run the tests in a container: make container IMAGE=debian:12-slim
	@tests/container.sh "$(IMAGE)"

install: ## Install a symlink at $(BINDIR)/req
	@mkdir -p "$(DESTDIR)$(BINDIR)"
	@ln -sf "$(SRC)" "$(TARGET)"
	@echo "installed: $(TARGET) -> $(SRC)"
	@case ":$$PATH:" in \
		*":$(BINDIR):"*) ;; \
		*) echo "warning: $(BINDIR) is not in your PATH; add this to your shell profile:"; \
		   echo "  export PATH=\"$(BINDIR):\$$PATH\"" ;; \
	esac

uninstall: ## Remove the symlink, if it points to this project
	@if [ -L "$(TARGET)" ] && [ "$$(readlink "$(TARGET)")" = "$(SRC)" ]; then \
		rm "$(TARGET)" && echo "removed: $(TARGET)"; \
	elif [ -e "$(TARGET)" ] || [ -L "$(TARGET)" ]; then \
		echo "refused: $(TARGET) does not point to $(SRC)"; exit 1; \
	else \
		echo "nothing to remove: $(TARGET)"; \
	fi
