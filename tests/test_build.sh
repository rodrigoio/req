#!/usr/bin/env bash
# Tests for build.sh (make build): the single file release/req.sh. The execution ones use
# tests/mock_server.py (needs python3). Nothing here touches the real release/ directory.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/tests/helpers.sh"

TMP=$(mktemp -d)
SERVER_PID=""
trap '[[ -n $SERVER_PID ]] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$TMP"' EXIT
export REQ_CONFIG_DIR=$TMP/central      # never touch the real ~/.req
unset REQ_ENV REQ_VERBOSE
BUILT=$TMP/out/nested/req.sh            # a directory that does not exist yet, on purpose

# test_tree <dir> - a copy of the build inputs without lib/, for the tests that break them.
test_tree() {
    mkdir -p "$1/bin" && cp "$ROOT/build.sh" "$ROOT/version.sh" "$1/" && cp "$ROOT/bin/req" "$1/bin/"
}

test_build_output() {
    echo "build: the single file"
    local out expected version
    out=$(bash "$ROOT/build.sh" "$BUILT" 2>&1); assert_eq "0" "$?" "build succeeds"
    assert_eq "built: $BUILT" "$out" "says what it built, with the absolute path"
    [[ -x $BUILT ]]; assert_eq "0" "$?" "the file is executable"
    bash -n "$BUILT"; assert_eq "0" "$?" "the syntax is valid"
    assert_eq "#!/usr/bin/env bash" "$(head -n 1 "$BUILT")" "starts with the shebang"
    assert_eq "1" "$(grep -c '^#!' "$BUILT")" "the shebang of the modules is gone"
    assert_not_contains "REQ_HOME" "$(<"$BUILT")" "nothing looks for an installation directory"

    version=$(source "$ROOT/version.sh"; printf '%s' "$REQ_VERSION")
    assert_eq "req $version" "$(bash "$BUILT" --version)" "the version is the one of version.sh"

    # The modules come in the order bin/req loads them (version.sh is the first one), bin/req last.
    # shellcheck disable=SC2016  # single-quoted on purpose: the sed expression matches a literal $REQ_HOME
    expected=$(sed -n 's/^[[:space:]]*source "\$REQ_HOME\/\(.*\)"$/\1/p' "$ROOT/bin/req"; printf '%s\n' bin/req)
    out=$(sed -n 's/^# ==== //p' "$BUILT")
    assert_eq "$expected" "$out" "every module, once, in the order of bin/req"
    assert_eq "version.sh" "$(head -n 1 <<<"$out")" "and version.sh comes first"

    out=$(cd "$ROOT" && bash build.sh "$TMP/absolute.sh"); assert_eq "built: $TMP/absolute.sh" "$out" "an absolute output path is kept as given"
    out=$(cd "$TMP" && bash "$ROOT/build.sh" relative-name.sh); assert_eq "built: $TMP/relative-name.sh" "$out" "a relative output path is made absolute"
    [[ -f $TMP/relative-name.sh ]]; assert_eq "0" "$?" "and written where it says"
}

test_build_standalone() {
    echo "build: the single file runs alone"
    local lone=$TMP/lone work=$TMP/work out port
    mkdir -p "$lone" "$work"
    cp "$BUILT" "$lone/req.sh"          # nothing else: no lib/, no version.sh, no bin/
    out=$(cd "$work" && bash "$lone/req.sh" --help 2>&1); assert_eq "0" "$?" "--help works"
    assert_contains "req run <file>" "$out" "and lists the commands"
    out=$(cd "$work" && bash "$lone/req.sh" init 2>&1); assert_eq "0" "$?" "req init works"
    assert_contains "workspace=." "$(<"$work/.req")" "the .req was written"
    out=$(cd "$work" && bash "$lone/req.sh" bogus_test_command 2>&1); assert_eq "1" "$?" "an unknown command fails"
    assert_contains "usage: req" "$out" "and shows the usage"

    command -v python3 >/dev/null 2>&1 || { echo "  skip python3 unavailable"; return; }
    python3 -I "$ROOT/tests/mock_server.py" >"$TMP/port" 2>/dev/null &
    SERVER_PID=$!
    for _ in {1..50}; do [[ -s $TMP/port ]] && break; sleep 0.1; done
    [[ -s $TMP/port ]] || { echo "  skip the mock server did not start"; return; }
    port=$(<"$TMP/port")
    printf '{"name":"echo-test","method":"GET","url":"http://127.0.0.1:%s/echo?q=1"}\n' "$port" >"$work/echo-test.get.json"
    out=$(cd "$work" && bash "$lone/req.sh" run echo-test.get.json 2>&1); assert_eq "0" "$?" "req run works"
    assert_contains "200" "$out" "and shows the status of the response"
    assert_contains "Total" "$out" "and the timing profile"
}

test_build_comments() {
    echo "build: full-line comments are left out"
    local rest joined text out tree=$TMP/comments_test_tree built=$TMP/comments_test_tree/req.sh
    local dir_a=$TMP/same_output_a dir_b=$TMP/same_output_b

    # The real file: only the shebang, the notice and the markers are comments, and it got smaller.
    rest=$(grep -E '^[[:space:]]*#' "$BUILT" | grep -vE '^(#!/usr/bin/env bash|# Built from the sources|# ==== )')
    assert_eq "" "$rest" "no full-line comment is left but the shebang, the notice and the markers"
    joined=$(cat "$ROOT/version.sh" "$ROOT"/lib/*.sh "$ROOT/bin/req" | wc -c)
    (( $(wc -c <"$BUILT") < joined )); assert_eq "0" "$?" "the file is smaller than the sources joined"

    # What it prints is what bin/req prints: a line of text taken for a comment would show here.
    mkdir -p "$dir_a" "$dir_b"
    assert_eq "$(bash "$ROOT/bin/req" --help)" "$(bash "$BUILT" --help)" "--help says the same as bin/req"
    out=$(cd "$dir_a" && bash "$ROOT/bin/req" init 2>&1)
    text=$(cd "$dir_b" && bash "$BUILT" init 2>&1)
    assert_eq "${out//$dir_a/DIR}" "${text//$dir_b/DIR}" "req init says the same as bin/req"
    assert_eq "$(<"$dir_a/.req")" "$(<"$dir_b/.req")" "and writes the same .req, comment line included"

    # A tree made for it: heredocs, a string with << and a trailing comment. Every comment that must go
    # says "dropped" in it.
    mkdir -p "$tree/bin" "$tree/lib"
    cp "$ROOT/build.sh" "$ROOT/version.sh" "$tree/"
    cat >"$tree/bin/req" <<'EOF'
#!/usr/bin/env bash
# the entrypoint comment (dropped)
main() {
    REQ_HOME=/nowhere
    source "$REQ_HOME/lib/fixture.sh"
    fixture_text
}
main "$@"
EOF
    cat >"$tree/lib/fixture.sh" <<'EOF'
# a comment (dropped)

fixture_one() { :; }

# a comment between two blank lines (dropped)

fixture_two() { :; }

fixture_text() {
    # a comment inside a function (dropped)
    cat <<'TEXT'
# a line of text, not a comment
TEXT
    printf 'a # inside a string\n'   # a trailing comment stays
    printf '(>> sent, << received)\n'
    # a comment after a string with << in it (dropped)
EOF
    printf '%s\n' "    cat <<-'TABBED'" $'\t# a line of text under a tab' $'\tTABBED' '}' >>"$tree/lib/fixture.sh"
    out=$(bash "$tree/build.sh" "$built" 2>&1); assert_eq "0" "$?" "a tree with heredocs builds"
    text=$(<"$built")
    assert_not_contains "(dropped)" "$text" "every comment line is gone, in the modules and in the entrypoint"
    assert_contains "# a line of text, not a comment" "$text" "the body of a heredoc stays, even a line that starts with #"
    assert_contains "# a trailing comment stays" "$text" "a comment after code stays"
    assert_eq $'fixture_one() { :; }\n\nfixture_two() { :; }' "$(grep -A2 '^fixture_one' "$built")" "the blank lines around a removed comment become one"
    out=$(bash "$built" 2>&1)
    assert_eq $'# a line of text, not a comment\na # inside a string\n(>> sent, << received)\n# a line of text under a tab' "$out" "and it prints the text of the heredocs, the string and the tabbed heredoc"
}

test_build_failures() {
    echo "build: failures leave the output alone"
    local tree=$TMP/missing_module_test_tree out
    test_tree "$tree"                   # bin/req sources lib/*.sh, which this tree does not have
    out=$(bash "$tree/build.sh" "$tree/release/req.sh" 2>&1); assert_eq "1" "$?" "a missing module fails"
    assert_contains "$tree/lib/core.sh: sourced by $tree/bin/req, but it does not exist" "$out" "names the module and the entrypoint"
    [[ ! -e $tree/release/req.sh ]]; assert_eq "0" "$?" "no output was created"

    printf 'previous build\n' >"$tree/previous.sh"
    out=$(bash "$tree/build.sh" "$tree/previous.sh" 2>&1); assert_eq "1" "$?" "it fails again with an existing output"
    assert_eq "previous build" "$(<"$tree/previous.sh")" "which keeps its content"
    assert_eq "previous.sh" "$(cd "$tree" && printf '%s\n' previous*)" "and leaves no temporary file behind"

    tree=$TMP/entrypoint_still_uses_home_test_tree
    test_tree "$tree" && cp -R "$ROOT/lib" "$tree/lib"
    # shellcheck disable=SC2016  # single-quoted on purpose: the line must keep a literal $REQ_HOME
    printf ': "$REQ_HOME"\n' >>"$tree/bin/req"
    out=$(bash "$tree/build.sh" "$tree/req.sh" 2>&1); assert_eq "1" "$?" "an entrypoint that still needs REQ_HOME fails"
    assert_contains "still uses REQ_HOME" "$out" "and says why"
    [[ ! -e $tree/req.sh ]]; assert_eq "0" "$?" "no output was created"
}

test_build_output
test_build_standalone
test_build_comments
test_build_failures
test_summary
