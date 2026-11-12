PREFIX  ?= $(HOME)/.local
BINDIR  ?= $(PREFIX)/bin
TARGET  := $(DESTDIR)$(BINDIR)/req
SRC     := $(abspath bin/req)

.DEFAULT_GOAL := help
.PHONY: help test lint check install uninstall

help: ## Lista os alvos disponíveis
	@grep -E '^[a-z]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-10s %s\n", $$1, $$2}'
	@echo
	@echo "Variáveis: PREFIX=$(PREFIX) BINDIR=$(BINDIR)"

test: ## Executa todos os testes
	@tests/run.sh

lint: ## Roda shellcheck (se instalado) e verifica a sintaxe
	@bash -n bin/req lib/*.sh tests/*.sh
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck -x bin/req lib/*.sh; \
	else \
		echo "shellcheck não encontrado; apenas a sintaxe foi verificada"; \
	fi

check: lint test ## Lint + testes

install: ## Instala o link simbólico em $(BINDIR)/req
	@mkdir -p "$(DESTDIR)$(BINDIR)"
	@ln -sf "$(SRC)" "$(TARGET)"
	@echo "instalado: $(TARGET) -> $(SRC)"
	@case ":$$PATH:" in \
		*":$(BINDIR):"*) ;; \
		*) echo "aviso: $(BINDIR) não está no PATH; adicione ao seu shell:"; \
		   echo "  export PATH=\"$(BINDIR):\$$PATH\"" ;; \
	esac

uninstall: ## Remove o link simbólico, se apontar para este projeto
	@if [ -L "$(TARGET)" ] && [ "$$(readlink "$(TARGET)")" = "$(SRC)" ]; then \
		rm "$(TARGET)" && echo "removido: $(TARGET)"; \
	elif [ -e "$(TARGET)" ] || [ -L "$(TARGET)" ]; then \
		echo "recusado: $(TARGET) não aponta para $(SRC)"; exit 1; \
	else \
		echo "nada a remover: $(TARGET)"; \
	fi
