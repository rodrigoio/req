#!/usr/bin/env bash
# Testes de lib/core.sh e lib/ui.sh.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/tests/helpers.sh"
source "$ROOT/lib/core.sh"
source "$ROOT/lib/ui.sh"

test_missing_deps() {
    echo "core: dependências"
    local out
    out=$(REQ_REQUIRED_CMDS=(bash req_cmd_inexistente_xyz); req_missing_deps)
    assert_eq "req_cmd_inexistente_xyz" "$out" "lista apenas a dependência ausente"
    out=$(REQ_REQUIRED_CMDS=(bash); req_missing_deps)
    assert_eq "" "$out" "nada ausente quando tudo existe"
}

test_check_deps_message() {
    local out status
    out=$(REQ_REQUIRED_CMDS=(req_cmd_inexistente_xyz); req_check_deps 2>&1)
    status=$?
    assert_eq "1" "$status" "check_deps falha com dependência ausente"
    assert_contains "req_cmd_inexistente_xyz" "$out" "mensagem cita a dependência"
    assert_contains "apt-get install" "$out" "mensagem orienta a instalação"
}

test_bash_check() {
    local out status
    out=$(REQ_REQUIRED_BASH_MAJOR=99 req_check_bash 2>&1)
    status=$?
    assert_eq "1" "$status" "check_bash falha com versão insuficiente"
    assert_contains "bash 99+" "$out" "mensagem cita a versão exigida"
    req_check_bash
    assert_eq "0" "$?" "bash atual atende ao mínimo"
}

test_colors() {
    echo "ui: cores"
    # Saída capturada não é terminal, então as cores ficam desligadas.
    assert_eq "" "$(req_color get)" "sem cor fora de terminal"
    assert_eq "GET" "$(req_paint_method get)" "método em maiúsculas sem cor"
    # Força o modo colorido sobrescrevendo a checagem.
    req_colors_enabled() { return 0; }
    assert_eq $'\033[32m' "$(req_color get)" "GET verde"
    assert_eq $'\033[34m' "$(req_color post)" "POST azul"
    assert_eq $'\033[38;5;208m' "$(req_color put)" "PUT laranja"
    assert_eq $'\033[31m' "$(req_color delete)" "DELETE vermelho"
    assert_eq "" "$(req_method_color patch)" "método desconhecido sem cor"
}

test_missing_deps
test_check_deps_message
test_bash_check
test_colors
test_summary
