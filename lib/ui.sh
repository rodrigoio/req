#!/usr/bin/env bash
# ui.sh - cores ANSI e formatação por método HTTP.

# Cores desligadas quando a saída não é terminal ou NO_COLOR está definido.
req_colors_enabled() {
    [[ -t 1 && -z ${NO_COLOR-} ]]
}

# req_color <get|post|put|delete|reset|bold|dim> - emite a sequência ANSI.
req_color() {
    req_colors_enabled || return 0
    case ${1,,} in
        get)    printf '\033[32m' ;;
        post)   printf '\033[34m' ;;
        put)    printf '\033[38;5;208m' ;;
        delete) printf '\033[31m' ;;
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
