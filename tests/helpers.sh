#!/usr/bin/env bash
# helpers.sh - minimal asserts for the tests (no external dependencies).

# Keep the output deterministic even when the tests run in a terminal.
export NO_COLOR=1

REQ_TESTS_FAILED=0
REQ_TESTS_RUN=0

# assert_eq <expected> <actual> <description>
assert_eq() {
    REQ_TESTS_RUN=$((REQ_TESTS_RUN + 1))
    if [[ $1 == "$2" ]]; then
        printf '  ok   %s\n' "$3"
    else
        REQ_TESTS_FAILED=$((REQ_TESTS_FAILED + 1))
        printf '  FAIL %s\n       expected: %q\n       actual:   %q\n' "$3" "$1" "$2"
    fi
}

# assert_contains <snippet> <text> <description>
assert_contains() {
    REQ_TESTS_RUN=$((REQ_TESTS_RUN + 1))
    if [[ $2 == *"$1"* ]]; then
        printf '  ok   %s\n' "$3"
    else
        REQ_TESTS_FAILED=$((REQ_TESTS_FAILED + 1))
        printf '  FAIL %s\n       missing snippet: %q\n       text: %q\n' "$3" "$1" "$2"
    fi
}

# test_summary - prints the summary and returns non-zero if anything failed.
test_summary() {
    printf '%d asserts, %d failures\n' "$REQ_TESTS_RUN" "$REQ_TESTS_FAILED"
    (( REQ_TESTS_FAILED == 0 ))
}
