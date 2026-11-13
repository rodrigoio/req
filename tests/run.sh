#!/usr/bin/env bash
# run.sh - runs every tests/test_*.sh and fails if any of them fails.

main() {
    local dir failed=0 t
    dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    for t in "$dir"/test_*.sh; do
        printf '== %s\n' "$(basename "$t")"
        # stdin is closed on purpose: a test that waits for the keyboard (an editor, a
        # prompt) must fail instead of hanging the whole run.
        bash "$t" </dev/null || failed=1
    done
    return "$failed"
}

main "$@"
