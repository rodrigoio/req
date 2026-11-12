#!/usr/bin/env bash
# ui.sh - cores ANSI e formatação por método HTTP.

# Cores desligadas quando a saída não é terminal ou NO_COLOR está definido.
req_colors_enabled() {
    [[ -t 1 && -z ${NO_COLOR-} ]]
}

# req_color <get|post|put|delete|ok|warn|err|reset|bold|dim> - emite a sequência ANSI.
req_color() {
    req_colors_enabled || return 0
    case ${1,,} in
        get)    printf '\033[32m' ;;
        post)   printf '\033[34m' ;;
        put)    printf '\033[38;5;208m' ;;
        delete) printf '\033[31m' ;;
        ok)     printf '\033[32m' ;;
        warn)   printf '\033[33m' ;;
        err)    printf '\033[31m' ;;
        bold)   printf '\033[1m' ;;
        dim)    printf '\033[2m' ;;
        reset)  printf '\033[0m' ;;
    esac
}

# req_method_color <MÉTODO> - cor do método; métodos desconhecidos ficam sem cor.
req_method_color() {
    case ${1,,} in
        get|post|put|delete) req_color "$1" ;;
    esac
}

# req_paint_method <MÉTODO> - imprime o método colorido (sem newline).
req_paint_method() {
    req_method_color "$1"
    printf '%s' "${1^^}"
    req_color reset
}

# req_paint_status <código HTTP> - imprime o código colorido por classe (sem newline).
req_paint_status() {
    case $1 in
        2*) req_color ok ;;
        3*) req_color warn ;;
        4*|5*) req_color err ;;
    esac
    printf '%s' "$1"
    req_color reset
}

# req_rule [caractere] - linha horizontal na largura do terminal (padrão: =).
req_rule() {
    local ch=${1:-=} cols=${COLUMNS:-}
    [[ $cols =~ ^[0-9]+$ ]] || cols=$(tput cols 2>/dev/null)
    [[ $cols =~ ^[0-9]+$ && $cols -gt 0 ]] || cols=60
    local line
    printf -v line '%*s' "$cols" ''
    printf '%s\n' "${line// /$ch}"
}
