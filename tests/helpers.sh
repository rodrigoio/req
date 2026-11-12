#!/usr/bin/env bash
# helpers.sh - asserts mínimos para os testes (sem dependências externas).

REQ_TESTS_FAILED=0
REQ_TESTS_RUN=0

# assert_eq <esperado> <obtido> <descrição>
assert_eq() {
    REQ_TESTS_RUN=$((REQ_TESTS_RUN + 1))
    if [[ $1 == "$2" ]]; then
        printf '  ok   %s\n' "$3"
    else
        REQ_TESTS_FAILED=$((REQ_TESTS_FAILED + 1))
        printf '  FAIL %s\n       esperado: %q\n       obtido:   %q\n' "$3" "$1" "$2"
    fi
}

# assert_contains <trecho> <texto> <descrição>
assert_contains() {
    REQ_TESTS_RUN=$((REQ_TESTS_RUN + 1))
    if [[ $2 == *"$1"* ]]; then
        printf '  ok   %s\n' "$3"
    else
        REQ_TESTS_FAILED=$((REQ_TESTS_FAILED + 1))
        printf '  FAIL %s\n       trecho ausente: %q\n       texto: %q\n' "$3" "$1" "$2"
    fi
}

# test_summary - imprime o resumo e devolve status != 0 se algo falhou.
test_summary() {
    printf '%d asserts, %d falhas\n' "$REQ_TESTS_RUN" "$REQ_TESTS_FAILED"
    (( REQ_TESTS_FAILED == 0 ))
}
