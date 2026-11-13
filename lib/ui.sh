#!/usr/bin/env bash
# ui.sh - ANSI colors, terminal helpers and per-method formatting.

# Colors are off when the output is not a terminal or NO_COLOR is set.
req_colors_enabled() {
    [[ -t 1 && -z ${NO_COLOR-} ]]
}

# req_color <get|post|put|patch|delete|ok|warn|err|reset|bold|dim> - emits the ANSI sequence.
req_color() {
    req_colors_enabled || return 0
    case ${1,,} in
        get)    printf '\033[32m' ;;
        post)   printf '\033[34m' ;;
        put)    printf '\033[38;5;208m' ;;
        patch)  printf '\033[38;5;130m' ;;
        delete) printf '\033[31m' ;;
        ok)     printf '\033[32m' ;;
        warn)   printf '\033[33m' ;;
        err)    printf '\033[31m' ;;
        bold)   printf '\033[1m' ;;
        dim)    printf '\033[2m' ;;
        reset)  printf '\033[0m' ;;
    esac
}

# req_method_color <METHOD> - the method's color; unknown methods get none.
req_method_color() {
    case ${1,,} in
        get|post|put|patch|delete) req_color "$1" ;;
    esac
}

# req_paint_method <METHOD> - prints the colored method (no newline).
req_paint_method() {
    req_method_color "$1"
    printf '%s' "${1^^}"
    req_color reset
}

# req_paint_status <HTTP code> - prints the code colored by class (no newline).
req_paint_status() {
    case $1 in
        2*) req_color ok ;;
        3*) req_color warn ;;
        4*|5*) req_color err ;;
    esac
    printf '%s' "$1"
    req_color reset
}

# req_utf8 - succeeds if the current locale is UTF-8.
req_utf8() {
    case ${LC_ALL:-${LC_CTYPE:-${LANG-}}} in
        *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) return 0 ;;
    esac
    return 1
}

# req_term_cols / req_term_rows - terminal size (COLUMNS/LINES, tput, 80x24).
req_term_cols() {
    local c=${COLUMNS:-}
    [[ $c =~ ^[0-9]+$ && $c -gt 0 ]] || c=$(tput cols 2>/dev/null)
    [[ $c =~ ^[0-9]+$ && $c -gt 0 ]] || c=80
    printf '%s' "$c"
}

req_term_rows() {
    local r=${LINES:-}
    [[ $r =~ ^[0-9]+$ && $r -gt 0 ]] || r=$(tput lines 2>/dev/null)
    [[ $r =~ ^[0-9]+$ && $r -gt 0 ]] || r=24
    printf '%s' "$r"
}

# req_trunc <text> <width> - cuts the text to fit, marking the cut with … (or ~).
req_trunc() {
    local t=$1 max=$2 ell='…'
    req_utf8 || ell='~'
    (( max < 1 )) && max=1
    if (( ${#t} > max )); then
        printf '%s%s' "${t:0:max-1}" "$ell"
    else
        printf '%s' "$t"
    fi
}

# req_rule [char] - horizontal line as wide as the terminal (default: =).
req_rule() {
    local ch=${1:-=} line
    printf -v line '%*s' "$(req_term_cols)" ''
    printf '%s\n' "${line// /$ch}"
}

# req_confirm <question> - asks "[Y/n]" and succeeds on yes. Enter means yes;
# end of input means no. Reads from REQ_INPUT_FD (default: stdin).
req_confirm() {
    local answer
    while :; do
        printf '%s [Y/n] ' "$1"
        IFS= read -r -u "${REQ_INPUT_FD:-0}" answer || { printf '\n'; return 1; }
        case ${answer,,} in
            ''|y|yes) return 0 ;;
            n|no)     return 1 ;;
        esac
    done
}
