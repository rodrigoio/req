#!/usr/bin/env bash
# build.sh - builds release/req.sh: the whole tool in one executable file, so a user installs it
# with a single download (see "Installation" in README.md and "Release" in DEVELOPMENT.md).
#
# usage: build.sh [output-file]      (default: release/req.sh, at the root of this repository)
#
# The order is the one bin/req already uses to load the modules: version.sh, then every
# `source "$REQ_HOME/<file>"` of bin/req, then the entrypoint itself. Nothing is listed here: a
# new module only has to be sourced by bin/req. The comments of the sources are left out, so the
# file a user downloads is smaller (req_build_strip_comments).

# req_build_err <message> - prints an error to stderr.
req_build_err() {
    printf 'build: error: %s\n' "$*" >&2
}

# req_build_modules <entrypoint> - prints the files the entrypoint sources, in order.
# shellcheck disable=SC2016  # the sed expression is single-quoted on purpose: it matches a literal $REQ_HOME
req_build_modules() {
    sed -n 's/^[[:space:]]*source "\$REQ_HOME\/\(.*\)"$/\1/p' "$1"
}

# req_build_strip_comments [file...] - prints the files (or stdin) without their full-line comments,
# the shebang included: the single file is read by the shell and the comments are about a third of
# the sources. A comment after code stays, because there a `#` can sit inside a string, `$#` or
# `${#x}`. The body of a heredoc is text, so it stays whole; a line that starts with `#` inside a
# multi-line quoted string is not told apart from a comment, so no module may have one. A blank line
# that is left next to another one only by the removal is dropped too.
# shellcheck disable=SC2016  # the awk program is single-quoted on purpose: $0 is awk's, not the shell's
req_build_strip_comments() {
    awk '
        inhd {
            print
            line = $0
            if (dash) sub(/^\t+/, "", line)
            if (line == tag) inhd = 0
            next
        }
        /^[[:space:]]*#/ { dropped = 1; next }
        /^[[:space:]]*$/ {
            if (dropped && blank) next
            blank = 1
            print
            next
        }
        {
            dropped = 0
            blank = 0
            print
            # A heredoc starts at `<<WORD`, `<<-WORD` or `<<"WORD"` that is not inside a string or a here-string (`<<<`).
            if (match($0, /<<-?[[:space:]]*\\?["\047]?[A-Za-z_][A-Za-z0-9_]*["\047]?/) && substr($0, RSTART - 1, 1) != "<") {
                before = substr($0, 1, RSTART - 1)
                quotes = before; doubles = gsub(/"/, "", quotes)
                quotes = before; singles = gsub(/\047/, "", quotes)
                if (doubles % 2 == 0 && singles % 2 == 0) {
                    dash = (substr($0, RSTART, 3) == "<<-")
                    tag = substr($0, RSTART, RLENGTH)
                    sub(/^<<-?[[:space:]]*/, "", tag)
                    gsub(/[\\"\047]/, "", tag)
                    inhd = 1
                }
            }
        }
    ' "$@"
}

# req_build_entrypoint <entrypoint> - prints the entrypoint without what the single file does not
# need: the lookup of REQ_HOME (req_resolve_home and its call) and the sourcing of the modules,
# which the build inlines. It finds req_resolve_home by the comment that opens it, so it runs
# before the comments are taken out.
# shellcheck disable=SC2016  # the awk program is single-quoted on purpose: it matches a literal $REQ_HOME
req_build_entrypoint() {
    awk '
        /^# req_resolve_home/ { skip = 1 }
        skip { if ($0 == "}") skip = 0; next }
        /^[[:space:]]*REQ_HOME=/ { next }
        /^[[:space:]]*source "\$REQ_HOME\// { next }
        { print }
    ' "$1"
}

# req_build_script <root> <output> - writes the single file. The output is only replaced by a
# complete, syntactically valid file, so a failed build leaves the previous one untouched.
req_build_script() {
    local root=$1 out=$2 mod tmp
    local -a modules
    mapfile -t modules < <(req_build_modules "$root/bin/req")
    if [[ ${#modules[@]} -eq 0 ]]; then
        req_build_err "$root/bin/req: it sources no module"
        return 1
    fi
    for mod in "${modules[@]}"; do
        [[ -f $root/$mod ]] && continue
        req_build_err "$root/$mod: sourced by $root/bin/req, but it does not exist"
        return 1
    done
    mkdir -p "$(dirname "$out")" || return 1
    tmp=$(mktemp "$out.XXXXXX") || return 1
    {
        printf '#!/usr/bin/env bash\n'
        printf '# Built from the sources by build.sh: do not edit, change the sources and run make build.\n'
        for mod in "${modules[@]}"; do
            printf '\n# ==== %s\n' "$mod"
            req_build_strip_comments "$root/$mod"
        done
        printf '\n# ==== bin/req\n'
        req_build_entrypoint "$root/bin/req" | req_build_strip_comments
    } >"$tmp"
    if grep -q 'REQ_HOME' "$tmp"; then
        req_build_err "the entrypoint still uses REQ_HOME: update req_build_entrypoint in $root/build.sh"
        rm -f "$tmp"
        return 1
    fi
    if ! bash -n "$tmp"; then
        req_build_err "the generated file has a syntax error"
        rm -f "$tmp"
        return 1
    fi
    if ! { chmod 755 "$tmp" && mv -f "$tmp" "$out"; }; then
        rm -f "$tmp"
        return 1
    fi
}

main() {
    local root out=${1-}
    root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || return 1
    [[ -n $out ]] || out=$root/release/req.sh
    [[ $out == /* ]] || out=$PWD/$out
    req_build_script "$root" "$out" || return 1
    printf 'built: %s\n' "$out"
}

main "$@"
