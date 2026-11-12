#!/usr/bin/env bash
# run.sh - executa todos os tests/test_*.sh e falha se algum falhar.

main() {
    local dir failed=0 t
    dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    for t in "$dir"/test_*.sh; do
        printf '== %s\n' "$(basename "$t")"
        bash "$t" || failed=1
    done
    return "$failed"
}

main "$@"
