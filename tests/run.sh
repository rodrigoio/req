#!/usr/bin/env bash
# run.sh - runs every tests/test_*.sh and fails if any of them fails.

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
