#!/usr/bin/env bash
# Tests for `make install` and `make uninstall`: a symbolic link, in the user's bin directory, to
# the file `make build` generates (release/req.sh), never to the sources. Everything runs in a
# temporary directory (PREFIX and RELEASE point there), so the real ~/.local and the real
# release/req.sh are never touched.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/tests/helpers.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# run_make <args...> - runs make in the repository; the output ends up in $OUT, the status in $STATUS.
run_make() {
    OUT=$(make -C "$ROOT" "$@" 2>&1); STATUS=$?
}

test_default_reference() {
    echo "install: the reference is the release, not the sources"
    run_make -n install PREFIX="$TMP/dry"
    assert_contains "./build.sh \"release/req.sh\"" "$OUT" "install builds first"
    assert_contains "ln -sfn \"$ROOT/release/req.sh\" \"$TMP/dry/bin/req\"" "$OUT" "and links to release/req.sh, by its absolute path"
    assert_not_contains "bin/req\" \"$TMP/dry/bin/req\"" "$OUT" "never to bin/req"
}

test_install() {
    echo "install: build, then link"
    local prefix=$TMP/prefix built=$TMP/out/req.sh target before
    before=$(cksum <"$ROOT/release/req.sh")

    run_make install PREFIX="$prefix" RELEASE="$built"
    assert_eq "0" "$STATUS" "make install succeeds"
    assert_contains "built: $built" "$OUT" "the release is built by the same command"
    assert_contains "installed: $prefix/bin/req -> $built" "$OUT" "and says what it linked"
    target=$prefix/bin/req
    [[ -L $target ]]; assert_eq "0" "$?" "the installed req is a symbolic link"
    assert_eq "$built" "$(readlink "$target")" "to the built file, by its absolute path"
    [[ -x $built ]]; assert_eq "0" "$?" "which is executable"
    assert_contains "Built from the sources by build.sh" "$(head -n 3 "$built")" "and is the single-file build"
    assert_eq "req $(sed -n 's/^REQ_VERSION="\(.*\)"/\1/p' "$ROOT/version.sh")" "$("$target" --version)" "running through the link works"
    assert_eq "$before" "$(cksum <"$ROOT/release/req.sh")" "the repository's own release/req.sh is untouched"

    run_make install PREFIX="$prefix" RELEASE="$built"
    assert_eq "0" "$STATUS" "installing again works"
    assert_eq "$built" "$(readlink "$target")" "and the link is the same"
}

test_replaces_an_old_link() {
    echo "install: an old link to the sources is replaced"
    local prefix=$TMP/old built=$TMP/old-out/req.sh before
    mkdir -p "$prefix/bin"
    ln -s "$ROOT/bin/req" "$prefix/bin/req"
    before=$(cksum <"$ROOT/bin/req")
    run_make install PREFIX="$prefix" RELEASE="$built"
    assert_eq "0" "$STATUS" "make install succeeds over it"
    assert_eq "$built" "$(readlink "$prefix/bin/req")" "now the link points to the built file"
    assert_eq "$before" "$(cksum <"$ROOT/bin/req")" "and bin/req was not written through"
}

test_path_warning() {
    echo "install: the PATH warning"
    local prefix=$TMP/path built=$TMP/path-out/req.sh
    run_make install PREFIX="$prefix" RELEASE="$built"
    assert_contains "warning: $prefix/bin is not in your PATH" "$OUT" "a bin directory that is not in PATH is warned about"
    assert_contains "export PATH=\"$prefix/bin:\$PATH\"" "$OUT" "and the line to add is shown"
    OUT=$(PATH="$prefix/bin:$PATH" make -C "$ROOT" install PREFIX="$prefix" RELEASE="$built" 2>&1)
    assert_not_contains "warning:" "$OUT" "no warning when it is in PATH"
}

test_destdir() {
    echo "install: DESTDIR"
    local stage=$TMP/stage built=$TMP/stage-out/req.sh
    run_make install DESTDIR="$stage" PREFIX=/usr/local RELEASE="$built"
    assert_eq "0" "$STATUS" "a staged install works"
    assert_eq "$built" "$(readlink "$stage/usr/local/bin/req")" "the link is under DESTDIR"
}

test_uninstall() {
    echo "uninstall: removes the link"
    local prefix=$TMP/un built=$TMP/un-out/req.sh
    run_make install PREFIX="$prefix" RELEASE="$built"
    run_make uninstall PREFIX="$prefix" RELEASE="$built"
    assert_eq "0" "$STATUS" "make uninstall succeeds"
    assert_contains "removed: $prefix/bin/req" "$OUT" "and says what it removed"
    [[ ! -e $prefix/bin/req && ! -L $prefix/bin/req ]]; assert_eq "0" "$?" "the link is gone"
    [[ -f $built ]]; assert_eq "0" "$?" "the built file stays"

    run_make uninstall PREFIX="$prefix" RELEASE="$built"
    assert_eq "0" "$STATUS" "with nothing installed it is not an error"
    assert_contains "nothing to remove" "$OUT" "and says so"

    echo "uninstall: only what is ours"
    printf 'not req\n' >"$prefix/bin/req"
    run_make uninstall PREFIX="$prefix" RELEASE="$built"
    assert_eq "1" "$(( STATUS != 0 ))" "a regular file is refused (make fails)"
    assert_contains "refused:" "$OUT" "with a reason"
    assert_eq "not req" "$(<"$prefix/bin/req")" "and left alone"
    rm -f "$prefix/bin/req"

    ln -s /bin/sh "$prefix/bin/req"
    run_make uninstall PREFIX="$prefix" RELEASE="$built"
    assert_eq "1" "$(( STATUS != 0 ))" "a link to anything else is refused (make fails)"
    [[ -L $prefix/bin/req ]]; assert_eq "0" "$?" "and kept"
    rm -f "$prefix/bin/req"

    ln -s "$ROOT/bin/req" "$prefix/bin/req"
    run_make uninstall PREFIX="$prefix" RELEASE="$built"
    assert_eq "0" "$STATUS" "an old link to bin/req, from an earlier install, is removed"
    [[ ! -L $prefix/bin/req ]]; assert_eq "0" "$?" "and the sources are untouched"
    [[ -f $ROOT/bin/req ]]; assert_eq "0" "$?" "bin/req is still there"
}

test_default_reference
test_install
test_replaces_an_old_link
test_path_warning
test_destdir
test_uninstall
test_summary
