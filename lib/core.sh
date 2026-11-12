#!/usr/bin/env bash
# core.sh - verificação de dependências, erros e restauração do terminal.

REQ_VERSION="0.1.0"
REQ_REQUIRED_BASH_MAJOR=4
REQ_REQUIRED_CMDS=(curl jq)

# req_die <mensagem> - imprime erro em stderr e encerra com status 1.
req_die() {
    printf 'req: erro: %s\n' "$*" >&2
    exit 1
}

# req_check_bash - exige bash >= REQ_REQUIRED_BASH_MAJOR.
req_check_bash() {
    if (( BASH_VERSINFO[0] < REQ_REQUIRED_BASH_MAJOR )); then
        req_die "bash ${REQ_REQUIRED_BASH_MAJOR}+ é necessário (encontrado: ${BASH_VERSION})."
    fi
}

# req_missing_deps - lista, uma por linha, as dependências ausentes do PATH.
req_missing_deps() {
    local cmd
    for cmd in "${REQ_REQUIRED_CMDS[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || printf '%s\n' "$cmd"
    done
}

# req_check_deps - encerra com instruções se faltar alguma dependência.
req_check_deps() {
    local missing
    missing=$(req_missing_deps)
    [[ -z $missing ]] && return 0
    req_die "dependências ausentes: $(tr '\n' ' ' <<<"$missing")
instale-as com o gerenciador de pacotes da distro, por exemplo:
  debian/ubuntu:  sudo apt-get install ${missing//$'\n'/ }
  centos/rhel:    sudo yum install ${missing//$'\n'/ }"
}

# req_restore_terminal - devolve o terminal ao estado normal (cursor, eco, cores).
req_restore_terminal() {
    [[ -t 1 ]] || return 0
    printf '\033[0m\033[?25h'
    [[ -t 0 ]] && stty sane 2>/dev/null
    return 0
}

# req_setup_traps - garante restauração do terminal em saída normal, erro ou sinal.
req_setup_traps() {
    trap req_restore_terminal EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
}
