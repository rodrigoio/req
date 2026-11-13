#!/usr/bin/env bash
# Tests for lib/home.sh.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/tests/helpers.sh"
source "$ROOT/lib/core.sh"
source "$ROOT/lib/home.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

test_kv_read() {
    echo "home: key=value reading"
    local f=$TMP/read.kv out
    printf '# a comment\n\nname = demo project \n url=http://x/a?b=1&c=2\nempty=\r\nCRLF=yes\r\nbad line\n9bad=1\n  # indented comment\nname=second\n' >"$f"
    assert_eq "demo project" "$(req_kv_get "$f" name)" "trims spaces; the first line of a key wins"
    assert_eq "http://x/a?b=1&c=2" "$(req_kv_get "$f" url)" "the value may contain ="
    assert_eq "" "$(req_kv_get "$f" empty)" "an empty value is allowed"
    req_kv_get "$f" empty >/dev/null; assert_eq "0" "$?" "and it counts as present"
    assert_eq "yes" "$(req_kv_get "$f" CRLF)" "CRLF line endings are tolerated"
    req_kv_get "$f" absent >/dev/null; assert_eq "1" "$?" "a missing key fails"
    req_kv_get "$f" "9bad" >/dev/null; assert_eq "1" "$?" "an invalid key is never returned"
    req_kv_get "$TMP/none.kv" name >/dev/null; assert_eq "1" "$?" "a missing file fails"

    out=$(req_kv_list "$f")
    assert_eq $'name=demo project\nurl=http://x/a?b=1&c=2\nempty=\nCRLF=yes\nname=second' "$out" "lists the valid lines, normalized, in order"
    assert_eq "" "$(req_kv_list "$TMP/none.kv")" "a missing file lists nothing"
    req_kv_list "$TMP/none.kv"; assert_eq "0" "$?" "and is not an error"
}

test_kv_check() {
    echo "home: key=value checking"
    local f=$TMP/check.kv out
    printf '# ok\na=1\n\nb = 2\n' >"$f"
    req_kv_check "$f"; assert_eq "0" "$?" "a valid file passes"
    req_kv_check "$TMP/none.kv"; assert_eq "0" "$?" "a missing file passes"
    printf 'a=1\nnot a pair\n9x=2\n# fine\nc=3\n' >"$f"
    out=$(req_kv_check "$f" 2>&1); assert_eq "1" "$?" "invalid lines fail"
    assert_contains "$f:2: expected key=value" "$out" "the first problem has the absolute path and the line"
    assert_contains "$f:3: expected key=value" "$out" "the second problem too"
    [[ $out != *":4:"* && $out != *":5:"* ]]; assert_eq "0" "$?" "comments and valid lines are not reported"
}

test_kv_write() {
    echo "home: key=value writing"
    local f=$TMP/deep/er/write.kv
    req_kv_set "$f" token abc
    assert_eq "token=abc" "$(<"$f")" "set creates the file and its directories"
    assert_eq "600" "$(stat -c %a "$f")" "a new file is private"
    assert_eq "700" "$(stat -c %a "$TMP/deep/er")" "and so is its new directory"

    printf '# header\nfirst=1\n\n# middle\nsecond=2\nthird=3' >"$f"
    req_kv_set "$f" second "  two  "
    assert_eq $'# header\nfirst=1\n\n# middle\nsecond=two\nthird=3' "$(<"$f")" "set replaces in place and keeps comments, blanks and order"
    req_kv_set "$f" fourth 4
    assert_eq $'# header\nfirst=1\n\n# middle\nsecond=two\nthird=3\nfourth=4' "$(<"$f")" "a new key goes to the end (even after a last line without newline)"
    req_kv_set "$f" empty ""
    assert_eq "empty=" "$(tail -n1 "$f")" "an empty value is written"
    assert_eq "" "$(req_kv_get "$f" empty)" "and read back"
    req_kv_set "$f" url "http://x/?a=1"
    assert_eq "http://x/?a=1" "$(req_kv_get "$f" url)" "a value with = round-trips"

    printf 'k=1\nx=9\nk=2\n' >"$f"
    req_kv_set "$f" k 5
    assert_eq $'k=5\nx=9' "$(<"$f")" "set keeps only the first line of a duplicated key"

    chmod 640 "$f"
    req_kv_set "$f" x 10
    assert_eq "640" "$(stat -c %a "$f")" "the mode of an existing file is kept"
    assert_eq "" "$(compgen -G "$TMP/deep/er/write.kv.*")" "no temporary files are left"

    local out
    out=$(req_kv_set "$f" "bad key" 1 2>&1); assert_eq "1" "$?" "an invalid key is refused"
    assert_contains "invalid key" "$out" "and explained"
    out=$(req_kv_set "$f" ok $'two\nlines' 2>&1); assert_eq "1" "$?" "a multi-line value is refused"
    assert_contains "single line" "$out" "and explained"
    assert_eq $'k=5\nx=10' "$(<"$f")" "refusals leave the file untouched"

    printf 'k=1\n# c\nk=2\nz=3\n' >"$f"
    req_kv_unset "$f" k; assert_eq "0" "$?" "unset removes a key"
    assert_eq $'# c\nz=3' "$(<"$f")" "every line of it, and nothing else"
    req_kv_unset "$f" k; assert_eq "1" "$?" "unsetting an absent key fails"
    req_kv_unset "$TMP/none.kv" k; assert_eq "1" "$?" "unsetting in a missing file fails"
    assert_eq $'# c\nz=3' "$(<"$f")" "and changes nothing"

    ln -s "$f" "$TMP/link.kv"
    req_kv_set "$TMP/link.kv" z 4
    [[ -L $TMP/link.kv ]]; assert_eq "0" "$?" "a symbolic link stays a link"
    assert_eq "4" "$(req_kv_get "$f" z)" "and the target is the file written"
}

test_kv_read
test_kv_check
test_kv_write
test_summary
