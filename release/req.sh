#!/usr/bin/env bash
# Built from the sources by build.sh: do not edit, change the sources and run make build.

# ==== version.sh
# version.sh - the single source of the req version (semantic versioning, MAJOR.MINOR.PATCH).
# Sourced by bin/req; the build process reads REQ_VERSION from here.

# shellcheck disable=SC2034  # read by bin/req
REQ_VERSION="0.3.0"

# ==== lib/core.sh
# core.sh - dependency checks, errors and terminal restoration.

# shellcheck disable=SC2034  # REQ_* globals are read by the other modules
REQ_REQUIRED_BASH_MAJOR=4
REQ_REQUIRED_CMDS=(curl jq)

# req_err <message> - prints an error to stderr without exiting.
req_err() {
    printf 'req: error: %s\n' "$*" >&2
}

# req_warn <message> - prints a warning to stderr without exiting.
req_warn() {
    printf 'req: warning: %s\n' "$*" >&2
}

# req_trim <text> - prints the text without leading and trailing whitespace.
req_trim() {
    local s=$1
    s=${s#"${s%%[![:space:]]*}"}
    s=${s%"${s##*[![:space:]]}"}
    printf '%s' "$s"
}

# req_abs_path <path> - prints the absolute (physical) path of a file or directory.
# The file itself does not need to exist; its directory does, otherwise the path
# is printed as given.
req_abs_path() {
    local p=$1 dir
    if [[ -d $p ]]; then
        (cd -P "$p" && pwd)
        return
    fi
    dir=$(cd -P "$(dirname "$p")" 2>/dev/null && pwd) || { printf '%s' "$p"; return; }
    printf '%s/%s' "$dir" "${p##*/}"
}

# req_die <message> - prints an error to stderr and exits with status 1.
req_die() {
    req_err "$@"
    exit 1
}

# req_check_bash - requires bash >= REQ_REQUIRED_BASH_MAJOR.
req_check_bash() {
    if (( BASH_VERSINFO[0] < REQ_REQUIRED_BASH_MAJOR )); then
        req_die "bash ${REQ_REQUIRED_BASH_MAJOR}+ is required (found: ${BASH_VERSION})."
    fi
}

# req_missing_deps - lists, one per line, the dependencies missing from PATH.
req_missing_deps() {
    local cmd
    for cmd in "${REQ_REQUIRED_CMDS[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || printf '%s\n' "$cmd"
    done
}

# req_check_deps - exits with an error naming the missing dependencies (in orange),
# without install commands.
req_check_deps() {
    local missing
    missing=$(req_missing_deps)
    [[ -z $missing ]] && return 0
    req_die "missing dependencies: $(req_color orange)${missing//$'\n'/ }$(req_color reset)"
}

# req_editor - prints the external editor command, like git does: $VISUAL, then
# $EDITOR, then vim, then vi. Fails (status 1) when none is available. $VISUAL and
# $EDITOR may carry arguments (e.g. "code -w") and are not checked for existence.
req_editor() {
    local e
    if [[ -n ${VISUAL-} ]]; then printf '%s' "$VISUAL"; return 0; fi
    if [[ -n ${EDITOR-} ]]; then printf '%s' "$EDITOR"; return 0; fi
    for e in vim vi; do
        if command -v "$e" >/dev/null 2>&1; then printf '%s' "$e"; return 0; fi
    done
    return 1
}

REQ_EDIT_TEXT=""    # result of req_edit_text

# req_edit_text <text> [suffix] - opens the text in the external editor, in a temporary
# file named raw_data<suffix> (e.g. ".json", so the editor picks the syntax), and puts
# the edited text in REQ_EDIT_TEXT without trailing line breaks. The editor takes over
# the terminal; the caller hands it over first (req_nav_prompt_begin).
# Status: 0 edited, 1 the editor failed (REQ_EDIT_TEXT keeps the original text),
# 2 no editor available (the caller falls back to a prompt).
req_edit_text() {
    local editor dir file status
    editor=$(req_editor) || return 2
    dir=$(mktemp -d "${TMPDIR:-/tmp}/req-edit.XXXXXX") || return 1
    file=$dir/raw_data${2-}
    printf '%s\n' "$1" >"$file"
    # The shell lets $VISUAL and $EDITOR carry arguments, as git does.
    sh -c "$editor \"\$@\"" req-editor "$file"
    status=$?
    if (( status == 0 )) && [[ -f $file ]]; then
        REQ_EDIT_TEXT=$(<"$file")
    else
        REQ_EDIT_TEXT=$1
        status=1
    fi
    rm -rf "$dir"
    return "$status"
}

# req_restore_terminal - puts the terminal back to normal (cursor, echo, colors).
req_restore_terminal() {
    [[ -t 1 ]] || return 0
    printf '\033[0m\033[?25h'
    [[ -t 0 ]] && stty sane 2>/dev/null
    return 0
}

REQ_EXIT_HOOK=""        # function to run first when the process exits (the menu saves its cursor)

# req_on_exit - the EXIT trap: runs the hook, if any, then restores the terminal.
req_on_exit() {
    [[ -z $REQ_EXIT_HOOK ]] || "$REQ_EXIT_HOOK"
    req_restore_terminal
}

# req_setup_traps - restores the terminal on normal exit, error or signal.
req_setup_traps() {
    trap req_on_exit EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

# ==== lib/ui.sh
# ui.sh - ANSI colors, terminal helpers and per-method formatting.

# Colors are off when the output is not a terminal or NO_COLOR is set. This is
# decided once, when the module is loaded: inside $(...) stdout is a pipe, so a
# per-call `-t 1` check would wrongly disable colors for captured fragments.
if [[ -t 1 && -z ${NO_COLOR-} ]]; then REQ_COLORS=1; else REQ_COLORS=0; fi

req_colors_enabled() {
    [[ $REQ_COLORS == 1 ]]
}

# req_color <get|post|put|patch|delete|ok|warn|err|orange|sel|reset|bold|dim> - emits the ANSI sequence.
# `sel` is the menu selection highlight: bold bright green.
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
        orange) printf '\033[38;5;208m' ;;
        sel)    printf '\033[1;92m' ;;
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

# req_confirm <question> [y|n] - asks "[Y/n]" (or "[y/N]" when the default is n) and
# succeeds on yes. Enter picks the default; end of input means no. Reads from
# REQ_INPUT_FD (default: stdin).
req_confirm() {
    local def=${2:-y} hint answer
    if [[ $def == n ]]; then hint='[y/N]'; else hint='[Y/n]'; fi
    while :; do
        printf '%s %s ' "$1" "$hint"
        IFS= read -r -u "${REQ_INPUT_FD:-0}" answer || { printf '\n'; return 1; }
        case ${answer,,} in
            '') [[ $def == n ]] && return 1 || return 0 ;;
            y|yes) return 0 ;;
            n|no)  return 1 ;;
        esac
    done
}

# req_prompt <label> [default] - asks for one line and leaves it in REQ_REPLY
# (the default when the answer is empty). Fails at end of input. Uses readline
# editing when reading from a terminal.
REQ_REPLY=""
# shellcheck disable=SC2034  # REQ_REPLY is read by the callers
req_prompt() {
    local label=$1 def=${2-} line prompt fd=${REQ_INPUT_FD:-0}
    prompt=$label
    [[ -n $def ]] && prompt+=" [$def]"
    prompt+=": "
    if [[ -t $fd ]]; then
        IFS= read -r -e -p "$prompt" -u "$fd" line || return 1
    else
        printf '%s' "$prompt"
        IFS= read -r -u "$fd" line || { printf '\n'; return 1; }
    fi
    REQ_REPLY=${line:-$def}
}

# ==== lib/store.sh
# store.sh - request persistence (<name>.<method>.json) and the .req project file.
#
# Request format:
#   {"name": "list-users", "method": "GET", "url": "https://api/users",
#    "description": "...", "headers": {}, "query": {}, "parameters": {}, "raw_data": ...}
#
# - `name` is a slug (lowercase letters, digits and hyphens) identical to the
#   file name; it is also the label shown in the menu.
# - `name`, `method` and `url` are required; the other fields are optional.
# - headers, query and parameters are objects with simple values (string,
#   number or boolean).
# - raw_data is the raw body: an object or list (JSON) or a string (any other text).
# Any unknown field or wrong type invalidates the request; the file is never
# changed, the error is only reported.

REQ_METHODS=(GET POST PUT PATCH DELETE)
REQ_PROJECT_FILE=.req

# Content checks (independent of the file name): prints one problem per line.
# shellcheck disable=SC2016  # a jq program: the $variables are jq's, not the shell's
# jq definition shared by the schema, the display and the request preparation: the
# "leaves" of a (possibly nested) query value, as [name, text] pairs. An object adds
# "[key]" to the name and a list adds "[]": {"f":{"a":1},"t":["x","y"]} gives f[a]=1,
# t[]=x and t[]=y (empty objects and lists give nothing).
# shellcheck disable=SC2016  # a jq program: the $variables are jq's, not the shell's
REQ_JQ_LEAVES='
def leaves($p):
    if type == "object" then (to_entries[] | .key as $k | .value | leaves(if $p == "" then $k else "\($p)[\($k)]" end))
    elif type == "array" then (.[] | leaves("\($p)[]"))
    else [$p, tostring] end;
'

# shellcheck disable=SC2016  # a jq program: the $variables are jq's, not the shell's
REQ_SCHEMA_JQ='
def scalar: type == "string" or type == "number" or type == "boolean";
def nested_ok: scalar or (type == "object" and all(.[]; nested_ok)) or (type == "array" and all(.[]; nested_ok));
def check_map($lbl; $item):
    if type != "object" then "field \"\($lbl)\" must be an object"
    else to_entries[] | select((.value | scalar) | not)
         | "\($item) \"\(.key)\": the value must be a string, number or boolean" end;
["name", "method", "url", "description", "headers", "query", "parameters", "raw_data", "timeout", "follow_redirects", "insecure", "files"] as $allowed
| if type != "object" then "the root must be an object"
  else
    (keys[] | select(. as $k | $allowed | index($k) | not)
        | if . == "data_parameter" then "field \"data_parameter\" was renamed to \"parameters\""
          elif . == "data_string" then "field \"data_string\" was renamed to \"raw_data\""
          else "unknown field \"\(.)\" (allowed: \($allowed | join(", ")))" end),
    (if (.name | type) != "string" then "field \"name\" is required (string)"
     elif (.name | test("^[a-z0-9]+(-[a-z0-9]+)*$") | not)
         then "field \"name\" must be a slug: lowercase letters, digits and hyphens (e.g. list-users)"
     else empty end),
    (if (.method | type) != "string" then "field \"method\" is required (string)" else empty end),
    (if (.url | type) != "string" or .url == "" then "field \"url\" is required (string)" else empty end),
    (if has("description") and (.description | type) != "string"
         then "field \"description\" must be a string" else empty end),
    (if has("headers") then
        (.headers | check_map("headers"; "header")),
        (if (.headers | type) == "object" then
            .headers | to_entries[]
            | if (.key | test("^[A-Za-z0-9!#$%&*+.^_|~-]+$") | not)
                  then "header \"\(.key)\": invalid name"
              elif (.value | type) == "string" and (.value | test("[\r\n]"))
                  then "header \"\(.key)\": the value must not contain line breaks"
              else empty end
         else empty end)
     else empty end),
    (if has("query") then
        (if (.query | type) != "object" then "field \"query\" must be an object"
         else .query | to_entries[] | select((.value | nested_ok) | not)
              | "query \"\(.key)\": the value must be a string, number or boolean, or a list or object of them" end)
     else empty end),
    (if has("parameters") then (.parameters | check_map("parameters"; "parameters")) else empty end),
    (if has("timeout") and ((.timeout | type) != "number" or .timeout <= 0)
         then "field \"timeout\" must be a positive number of seconds" else empty end),
    (if has("follow_redirects") and (.follow_redirects | type) != "boolean"
         then "field \"follow_redirects\" must be true or false" else empty end),
    (if has("files") then
        (.files | if type != "object" then "field \"files\" must be an object (field name -> file path)"
                  else to_entries[] | select((.value | type) != "string" or .value == "")
                       | "files \"\(.key)\": the value must be a file path" end),
        (if (.files | type) == "object" and (.files | length) > 0
             and ((.raw_data // "") | . != "" and . != {} and . != [])
             then "\"files\" and \"raw_data\" cannot be used together (files are sent as a multipart form, with \"parameters\")"
             else empty end)
     else empty end),
    (if has("insecure") and (.insecure | type) != "boolean"
         then "field \"insecure\" must be true or false" else empty end),
    (if has("raw_data") and ((.raw_data | type) as $t | $t != "object" and $t != "array" and $t != "string")
         then "field \"raw_data\" must be an object, a list or a string" else empty end)
  end'

# req_valid_method <method> - succeeds for a supported method (any case).
req_valid_method() {
    local m
    for m in "${REQ_METHODS[@]}"; do
        [[ ${1^^} == "$m" ]] && return 0
    done
    return 1
}

# req_valid_name <name> - slug: lowercase letters, digits and hyphens (e.g. list-users).
req_valid_name() {
    [[ $1 =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]
}

# req_request_filename <name> <method> - prints "<name>.<lowercase method>.json".
req_request_filename() {
    printf '%s.%s.json' "$1" "${2,,}"
}

# req_parse_filename <file> - prints "<name>\t<METHOD>", or fails if the file
# does not follow <slug>.<method>.json with a supported method.
req_parse_filename() {
    local base=${1##*/} stem method
    [[ $base == *.*.json ]] || return 1
    stem=${base%.json}
    method=${stem##*.}
    req_valid_method "$method" || return 1
    req_valid_name "${stem%.*}" || return 1
    printf '%s\t%s\n' "${stem%.*}" "${method^^}"
}

# Full check in a single jq call: the first two output lines are name and method
# (empty when missing or not a string), the rest are content problems, one per line.
REQ_CHECK_JQ='
(if type == "object" then
    (.name   | if type == "string" then gsub("[\r\n]"; " ") else "" end),
    (.method | if type == "string" then gsub("[\r\n]"; " ") else "" end)
 else "", "" end),
('"$REQ_SCHEMA_JQ"')'

# Request fields for display, as "tag NUL value NUL" records.
# shellcheck disable=SC2016  # a jq program: the $variables are jq's, not the shell's
REQ_FIELDS_JQ=$REQ_JQ_LEAVES'
(["name", (.name // "")], ["method", (.method // "")], ["url", (.url // "")],
 ["description", (.description // "")],
 ((.headers // {})        | to_entries[] | ["h", "\(.key): \(.value)"]),
 ((.query // {})          | to_entries[] | .key as $k | .value | leaves($k) | ["q", "\(.[0])=\(.[1])"]),
 ((.parameters // {}) | to_entries[] | ["p", "\(.key)=\(.value)"]),
 ((.raw_data // "") as $r
  | if $r == "" then empty
    elif ($r | type) == "string" then ["rawtext", $r]
    else ["rawjson", ($r | tojson)] end))
| .[] | (., "\u0000")'

REQ_F_NAME=""; REQ_F_METHOD=""; REQ_F_URL=""; REQ_F_DESC=""
REQ_F_HEADERS=(); REQ_F_QUERY=(); REQ_F_PARAMS=()
REQ_F_RAW=""        # raw_data as text: indented JSON for an object or list, else the string
REQ_F_RAW_SET=0     # 1 when the request has a non-empty raw_data

# shellcheck disable=SC2034  # REQ_F_* are read by nav.sh
# req_request_fields <file> - reads the fields of an already validated request in
# a single jq call and fills REQ_F_NAME, REQ_F_METHOD, REQ_F_URL, REQ_F_DESC and
# the arrays REQ_F_HEADERS ("key: value"), REQ_F_QUERY and REQ_F_PARAMS ("key=value"),
# plus REQ_F_RAW and REQ_F_RAW_SET for raw_data.
req_request_fields() {
    local tag val
    REQ_F_NAME=""; REQ_F_METHOD=""; REQ_F_URL=""; REQ_F_DESC=""
    REQ_F_HEADERS=(); REQ_F_QUERY=(); REQ_F_PARAMS=(); REQ_F_RAW=""; REQ_F_RAW_SET=0
    while IFS= read -r -d '' tag && IFS= read -r -d '' val; do
        case $tag in
            name)        REQ_F_NAME=$val ;;
            method)      REQ_F_METHOD=${val^^} ;;
            url)         REQ_F_URL=$val ;;
            description) REQ_F_DESC=$val ;;
            h)           REQ_F_HEADERS+=("$val") ;;
            q)           REQ_F_QUERY+=("$val") ;;
            p)           REQ_F_PARAMS+=("$val") ;;
            rawtext)     REQ_F_RAW=$val; REQ_F_RAW_SET=1 ;;
            rawjson)     REQ_F_RAW=$(jq . <<<"$val"); REQ_F_RAW_SET=1 ;;
        esac
    done < <(jq -j "$REQ_FIELDS_JQ" "$1")
}

# req_request_check <file> - validates the JSON, fields, types and consistency
# with the file name. Prints each problem to stderr; succeeds if there are none.
# Invalid JSON is only reported, the file is never changed.
req_request_check() {
    local file=$1 abs out status line parsed stem fmethod jname jmethod
    local lines=() problems=()
    abs=$(req_abs_path "$file")     # messages carry the absolute path, easy to copy
    out=$(jq -r "$REQ_CHECK_JQ" "$file" 2>&1); status=$?
    if (( status != 0 )) && [[ $out == *"parse error"* ]]; then
        req_err "$abs: invalid JSON: $out"
        return 1
    elif (( status != 0 )); then
        req_err "$abs: cannot validate: $out"
        return 1
    fi
    mapfile -t lines <<<"$out"
    jname=${lines[0]}
    jmethod=${lines[1]}
    problems=("${lines[@]:2}")

    if [[ ${problems[0]-} != *"the root must be"* ]]; then
        if [[ -n $jmethod ]] && ! req_valid_method "$jmethod"; then
            problems+=("method \"$jmethod\" is not supported (use ${REQ_METHODS[*]})")
        fi
        if parsed=$(req_parse_filename "$file"); then
            stem=${parsed%%$'\t'*}
            fmethod=${parsed#*$'\t'}
            if [[ -n $jname && $jname != "$stem" ]]; then
                problems+=("field \"name\" (\"$jname\") differs from the file name (\"$stem\")")
            fi
            if [[ -n $jmethod ]] && req_valid_method "$jmethod" && [[ $fmethod != "${jmethod^^}" ]]; then
                problems+=("method \"$jmethod\" differs from the file name ($fmethod)")
            fi
        else
            problems+=("file name does not follow <slug>.<method>.json")
        fi
    fi

    (( ${#problems[@]} == 0 )) && return 0
    for line in "${problems[@]}"; do
        req_err "$abs: $line"
    done
    return 1
}

# req_request_template <name> <method> <url> - prints a new request as JSON.
req_request_template() {
    jq -n --arg name "$1" --arg method "${2^^}" --arg url "$3" '{
        name: $name, method: $method, url: $url, description: "",
        headers: {}, query: {}, parameters: {}
    }'
}

# req_request_write <directory> <name> <method> <url> [json]
# Atomically writes the request as valid JSON and prints the created path.
# [json] carries the optional fields (description, headers, query, parameters);
# name, method and url come from the arguments and take precedence. If the
# result fails validation, nothing is written.
req_request_write() {
    local dir=$1 name=$2 method=$3 url=$4 json=${5-} target tmp problems line
    req_valid_name "$name" || {
        req_err "invalid name: \"$name\" (use a slug: lowercase letters, digits and hyphens)"; return 1; }
    req_valid_method "$method" || {
        req_err "invalid method: \"$method\" (use ${REQ_METHODS[*]})"; return 1; }
    [[ -n $url ]] || { req_err "the url is required"; return 1; }
    [[ -d $dir ]] || { req_err "directory does not exist: $dir"; return 1; }

    [[ -n $json ]] || json=$(req_request_template "$name" "$method" "$url")
    target=$dir/$(req_request_filename "$name" "$method")
    tmp=$(mktemp "$dir/.req.XXXXXX") || { req_err "cannot write to $dir"; return 1; }
    if ! jq --arg name "$name" --arg method "${method^^}" --arg url "$url" \
            '{name: $name, method: $method, url: $url} + del(.name, .method, .url)' <<<"$json" >"$tmp" 2>/dev/null; then
        rm -f "$tmp"
        req_err "the JSON of request \"$name\" is invalid; nothing was written"
        return 1
    fi
    problems=$(jq -r "$REQ_SCHEMA_JQ" "$tmp") || {
        rm -f "$tmp"; req_err "failed to validate request \"$name\""; return 1; }
    if [[ -n $problems ]]; then
        rm -f "$tmp"
        while IFS= read -r line; do
            req_err "request \"$name\": $line"
        done <<<"$problems"
        return 1
    fi
    mv "$tmp" "$target" && printf '%s\n' "$target"
}

# req_request_get <file> <field> - prints a field's value (raw text).
# Missing fields become {} (headers, query, parameters) or empty (others).
req_request_get() {
    case $2 in
        headers|query|parameters) jq -c --arg f "$2" '.[$f] // {}' "$1" ;;
        *) jq -r --arg f "$2" '.[$f] // ""' "$1" ;;
    esac
}

# req_project_find [directory] - prints the path of the .req in the directory (default: current).
req_project_find() {
    local file=${1:-.}/$REQ_PROJECT_FILE
    [[ -f $file ]] || return 1
    printf '%s\n' "$file"
}

# req_project_init [directory] - creates the .req file of a new project, and nothing
# else: a comment and "workspace=." (the working directory, relative to the .req; "." is
# the folder itself). Fails if the directory does not exist or already has a .req.
req_project_init() {
    local dir=${1:-.} file
    file=$dir/$REQ_PROJECT_FILE
    [[ -d $dir ]] || { req_err "directory does not exist: $dir"; return 1; }
    [[ ! -e $file ]] || { req_err "$file already exists"; return 1; }
    if ! printf '%s\n' \
            '# req project: this folder was initialized with req.' \
            '# workspace: the directory req works on, relative to this folder ("." is the folder itself).' \
            'workspace=.' >"$file" 2>/dev/null; then
        req_err "cannot write to $dir"
        return 1
    fi
}

# req_list_dir <directory> - lists the contents, subdirectories first and then
# requests, each group in alphabetical order. One TAB-separated entry per line:
#   d  <name>             <path>
#   r  <name>  <METHOD>   <path>
# Hidden items and files not matching <slug>.<method>.json are ignored.
req_list_dir() {
    local dir=${1%/} entry name parsed
    [[ -d $dir ]] || { req_err "directory does not exist: $dir"; return 1; }
    (
        shopt -s nullglob
        export LC_ALL=C
        for entry in "$dir"/*/; do
            entry=${entry%/}
            printf 'd\t%s\t%s\n' "${entry##*/}" "$entry"
        done | sort -t$'\t' -k2,2
        for entry in "$dir"/*.json; do
            [[ -f $entry ]] || continue
            parsed=$(req_parse_filename "$entry") || continue
            name=${parsed%%$'\t'*}
            printf 'r\t%s\t%s\t%s\n' "$name" "${parsed#*$'\t'}" "$entry"
        done | sort -t$'\t' -k2,2 -k3,3
    )
}

# ==== lib/http.sh
# http.sh - builds and runs the request through curl and shows the result in the terminal.
# The response is kept in memory; no file is written to disk.

REQ_CURL_ARGS=()        # curl arguments built by req_build_curl_args
REQ_BODY=""             # body sent through stdin (--data-binary @-)
REQ_RESP_BODY=""        # body of the last response
REQ_RESP_STATUS=""      # HTTP status code of the last response
REQ_RESP_CTYPE=""       # Content-Type of the last response
REQ_RESP_TIMES=()       # dns connect tls pretransfer ttfb total (seconds, cumulative)
REQ_RESP_STATUSLINE=""  # status line of the last response ("HTTP/1.1 200 OK")
REQ_RESP_HEADERS=()     # its headers, one "Name: value" per item
REQ_BAR_WIDTH=30
REQ_VERBOSE=${REQ_VERBOSE:-0}   # 1: show what is sent (>>) and received (<<); :v toggles it

# Metadata appended by curl at the end of the output; the Content-Type goes last
# because it can contain any character except a line break.
REQ_CURL_FORMAT=$'\n%{http_code}|%{time_namelookup}|%{time_connect}|%{time_appconnect}|%{time_pretransfer}|%{time_starttransfer}|%{time_total}|%{content_type}'

# Request preparation in a single jq call, as "tag NUL value NUL" records: method,
# url with the url-encoded querystring, headers and body. The body exists only for
# POST, PUT and PATCH. A non-empty raw_data (object, list or non-empty string) is the
# body ("raw", plus "rawjson" when it was an object or list) and wins over parameters,
# which otherwise come out as key=value form pairs.
# shellcheck disable=SC2016  # a jq program: the $variables are jq's, not the shell's
REQ_PREPARE_JQ=$REQ_JQ_LEAVES'
((.method // "") | ascii_upcase) as $m
| (.headers // {}) as $h
| (.parameters // {}) as $d
| (.raw_data // "") as $r
| (.timeout // "") as $t
| (.follow_redirects // false) as $f
| (.insecure // false) as $k
| (.files // {}) as $fl
| ($m == "POST" or $m == "PUT" or $m == "PATCH") as $body
| (["method", $m],
   ["url", ((.url // "") as $u
            | ([(.query // {}) | to_entries[] | .key as $k | .value | leaves($k)]
               | map("\(.[0] | @uri)=\(.[1] | @uri)") | join("&")) as $q
            | if $q == "" then $u
              elif ($u | contains("?")) then $u + "&" + $q
              else $u + "?" + $q end)],
   ($h | to_entries[] | ["header", "\(.key): \(.value)"]),
   ["hasctype", ($h | keys | any(ascii_downcase == "content-type") | tostring)],
   (if $t != "" then ["timeout", ($t | tostring)] else empty end),
   ["follow", ($f | tostring)],
   ["insecure", ($k | tostring)],
   (if $body and $r != "" then
        ["raw", (if ($r | type) == "string" then $r else ($r | tojson) end)],
        ["rawjson", (($r | type) != "string" | tostring)]
    elif $body and (($d | length) > 0 or ($fl | length) > 0) then
        ($d | to_entries[] | ["form", "\(.key)=\(.value | tostring)"]),
        ($fl | to_entries[] | ["file", "\(.key)=\(.value)"])
    else empty end))
| .[] | (., "\u0000")'

REQ_P_METHOD=""; REQ_P_URL=""; REQ_P_HEADERS=(); REQ_P_HASCTYPE=false
REQ_P_RAW=""; REQ_P_RAWSET=0; REQ_P_RAWJSON=false; REQ_P_FORM=(); REQ_P_TIMEOUT=""; REQ_P_FOLLOW=false; REQ_P_INSECURE=false; REQ_P_FILES=()
REQ_REQUEST_DIR=""      # folder of the request file; relative paths in "files" start here

# req_prepare_request <json> - fills REQ_P_* from the request. Fails without a url.
req_prepare_request() {
    local tag val
    REQ_P_METHOD=""; REQ_P_URL=""; REQ_P_HEADERS=(); REQ_P_HASCTYPE=false
    REQ_P_RAW=""; REQ_P_RAWSET=0; REQ_P_RAWJSON=false; REQ_P_FORM=(); REQ_P_TIMEOUT=""; REQ_P_FOLLOW=false; REQ_P_INSECURE=false; REQ_P_FILES=()
    while IFS= read -r -d '' tag && IFS= read -r -d '' val; do
        case $tag in
            method)   REQ_P_METHOD=$val ;;
            url)      REQ_P_URL=$val ;;
            header)   REQ_P_HEADERS+=("$val") ;;
            hasctype) REQ_P_HASCTYPE=$val ;;
            raw)      REQ_P_RAW=$val; REQ_P_RAWSET=1 ;;
            rawjson)  REQ_P_RAWJSON=$val ;;
            form)     REQ_P_FORM+=("$val") ;;
            timeout)  REQ_P_TIMEOUT=$val ;;
            follow)   REQ_P_FOLLOW=$val ;;
            insecure) REQ_P_INSECURE=$val ;;
            file)     REQ_P_FILES+=("$val") ;;
        esac
    done < <(jq -j "$REQ_PREPARE_JQ" <<<"$1")
    if [[ -z $REQ_P_URL ]]; then
        req_err 'the request has no "url"; set the "url" field in the file (or edit it with :e)'
        return 1
    fi
}

# req_build_url <json> - the url with the (url-encoded) querystring appended.
req_build_url() {
    req_prepare_request "$1" || return 1
    printf '%s' "$REQ_P_URL"
}

# req_build_curl_args <json> - fills REQ_P_*, REQ_CURL_ARGS and REQ_BODY. The maximum
# time of the whole request is the "timeout" field (seconds), else REQ_TIMEOUT, else 60.
# Body (POST, PUT and PATCH only): a non-empty raw_data is sent as it is, through
# stdin; an object or list gets "Content-Type: application/json" when the request
# has no Content-Type, and free text gets none (curl'"'"'s default one is removed).
# Without raw_data, parameters are sent as an url-encoded form, always. The form
# uses "key=value", so values starting with "@" are never read as files by curl.
req_build_curl_args() {
    local line
    req_prepare_request "$1" || return 1

    REQ_BODY=""
    REQ_CURL_ARGS=(-sS -g
        --connect-timeout "${REQ_CONNECT_TIMEOUT:-10}"
        --max-time "${REQ_P_TIMEOUT:-${REQ_TIMEOUT:-60}}"
        -X "$REQ_P_METHOD")
    [[ $REQ_P_FOLLOW == true ]] && REQ_CURL_ARGS+=(-L --max-redirs "$(req_config_get max_redirects)")
    [[ $REQ_P_INSECURE == true ]] && REQ_CURL_ARGS+=(-k)

    for line in "${REQ_P_HEADERS[@]}"; do
        REQ_CURL_ARGS+=(-H "$line")
    done

    if (( REQ_P_RAWSET )); then
        REQ_BODY=$REQ_P_RAW
        REQ_CURL_ARGS+=(--data-binary @-)
        if [[ $REQ_P_HASCTYPE != true ]]; then
            if [[ $REQ_P_RAWJSON == true ]]; then
                REQ_CURL_ARGS+=(-H "Content-Type: application/json")
            else
                REQ_CURL_ARGS+=(-H "Content-Type:")
            fi
        fi
    elif (( ${#REQ_P_FILES[@]} > 0 )); then
        req_files_args || return 1
    else
        for line in "${REQ_P_FORM[@]}"; do
            REQ_CURL_ARGS+=(--data-urlencode "$line")
        done
    fi
    REQ_CURL_ARGS+=("$REQ_P_URL")
}

# req_split_headers <text> - the text is what curl wrote with "-D -": the header block
# (CRLF lines, ended by a blank line) and then the body. Fills REQ_RESP_STATUSLINE and
# REQ_RESP_HEADERS, and puts the body in REQ_RESP_BODY. An interim "1xx" block (such as
# "100 Continue") is skipped, and so are the "3xx" blocks of the redirects followed
# (REQ_P_FOLLOW). Text that does not start with "HTTP/" is all body.
req_split_headers() {
    local rest=$1 block line crlf=$'\r\n'
    REQ_RESP_STATUSLINE=""; REQ_RESP_HEADERS=()
    while [[ $rest == HTTP/* && $rest == *"$crlf$crlf"* ]]; do
        block=${rest%%"$crlf$crlf"*}; rest=${rest#*"$crlf$crlf"}
        REQ_RESP_STATUSLINE=${block%%"$crlf"*}; REQ_RESP_HEADERS=()
        [[ $block == *"$crlf"* ]] && while IFS= read -r line; do
            [[ -z $line ]] || REQ_RESP_HEADERS+=("${line%$'\r'}")
        done <<<"${block#*"$crlf"}"
        [[ $REQ_RESP_STATUSLINE =~ ^HTTP/[0-9.]+\ 1[0-9][0-9] ]] && continue
        # with follow_redirects, curl dumps the headers of every hop: the last one counts
        [[ $REQ_P_FOLLOW == true && $REQ_RESP_STATUSLINE =~ ^HTTP/[0-9.]+\ 3[0-9][0-9] ]] || break
    done
    REQ_RESP_BODY=$rest
}

# req_files_args - the multipart form of a request with "files": every parameter as a
# text field (--form-string, so a value starting with "@" or "<" is never read as a file)
# and every file as "-F field=@path", quoted so a ";" or "," in the path is not read as an
# option of curl. A relative path starts at REQ_REQUEST_DIR. A file that cannot be read
# stops the request.
req_files_args() {
    local item name path
    for item in "${REQ_P_FORM[@]}"; do
        REQ_CURL_ARGS+=(--form-string "$item")
    done
    for item in "${REQ_P_FILES[@]}"; do
        name=${item%%=*}; path=${item#*=}
        [[ $path == /* || -z $REQ_REQUEST_DIR ]] || path=$REQ_REQUEST_DIR/$path
        if [[ ! -f $path || ! -r $path ]]; then
            req_err "file \"$path\" (field \"$name\") does not exist or cannot be read"
            return 1
        fi
        path=${path//\\/\\\\}; path=${path//\"/\\\"}
        REQ_CURL_ARGS+=(-F "$name=@\"$path\"")
    done
}

# req_curl_exec - runs REQ_CURL_ARGS/REQ_BODY and fills REQ_RESP_*, headers included.
# Returns curl's status (0 = an HTTP response was received, any status code).
req_curl_exec() {
    local out meta status
    out=$(printf '%s' "$REQ_BODY" | curl "${REQ_CURL_ARGS[@]}" -D - -w "$REQ_CURL_FORMAT")
    status=$?

    meta=${out##*$'\n'}
    req_split_headers "${out%$'\n'*}"
    IFS='|' read -r REQ_RESP_STATUS "REQ_RESP_TIMES[0]" "REQ_RESP_TIMES[1]" "REQ_RESP_TIMES[2]" \
        "REQ_RESP_TIMES[3]" "REQ_RESP_TIMES[4]" "REQ_RESP_TIMES[5]" REQ_RESP_CTYPE <<<"$meta"
    return "$status"
}

# req_execute <json> - builds and runs the request.
req_execute() {
    req_build_curl_args "$1" || return 1
    req_curl_exec
}

# req_timing_stages <dns> <connect> <tls> <pretransfer> <ttfb> <total>
# Converts curl's cumulative times into stages. Prints "<stage>\t<ms>" per line;
# TLS only appears on secure connections. The last line is the total.
req_timing_stages() {
    LC_ALL=C awk -v dns="$1" -v conn="$2" -v tls="$3" -v pre="$4" -v ttfb="$5" -v total="$6" '
        function clamp(x) { return x < 0 ? 0 : x }
        BEGIN {
            printf "DNS\t%.0f\n", clamp(dns) * 1000
            printf "TCP\t%.0f\n", clamp(conn - dns) * 1000
            if (tls > 0) printf "TLS\t%.0f\n", clamp(tls - conn) * 1000
            printf "Wait\t%.0f\n", clamp(ttfb - pre) * 1000
            printf "Download\t%.0f\n", clamp(total - ttfb) * 1000
            printf "Total\t%.0f\n", clamp(total) * 1000
        }'
}

# req_bar_char - full block in UTF-8 locales, "#" otherwise.
req_bar_char() {
    if req_utf8; then printf '█'; else printf '#'; fi
}

# req_print_profile - one horizontal bar per stage, proportional to the total time,
# and the total line. The settings time_stats (the stages) and time_stat_total (the
# total line) turn each part off; with both off nothing is printed.
req_print_profile() {
    local stages label ms total char bar n show_stats show_total
    show_stats=$(req_config_get time_stats); show_total=$(req_config_get time_stat_total)
    [[ $show_stats == yes || $show_total == yes ]] || return 0
    stages=$(req_timing_stages "${REQ_RESP_TIMES[@]}")
    total=$(tail -n 1 <<<"$stages"); total=${total#*$'\t'}
    char=$(req_bar_char)

    req_color dim; printf 'Timing\n'; req_color reset
    while IFS=$'\t' read -r label ms; do
        if [[ $label == Total ]]; then
            [[ $show_total == yes ]] || continue
            printf '  %-9s %*s %5s ms\n' "$label" "$REQ_BAR_WIDTH" '' "$ms"
            continue
        fi
        [[ $show_stats == yes ]] || continue
        n=0
        (( total > 0 && ms > 0 )) && n=$(( (ms * REQ_BAR_WIDTH + total / 2) / total ))
        (( ms > 0 && n < 1 )) && n=1
        (( n > REQ_BAR_WIDTH )) && n=$REQ_BAR_WIDTH
        printf -v bar '%*s' "$n" ''
        printf '  %-9s ' "$label"
        req_color dim; printf '%s' "${bar// /$char}"; req_color reset
        printf '%*s %5s ms\n' $(( REQ_BAR_WIDTH - n )) '' "$ms"
    done <<<"$stages"
}

# req_print_body <content-type> <body> - indented JSON; text and HTML as received.
req_print_body() {
    local ctype=$1 body=$2 pretty flags=()
    if [[ -z $body ]]; then
        req_color dim; printf '(no body)\n'; req_color reset
        return 0
    fi
    if [[ ${ctype,,} == *json* ]]; then
        req_colors_enabled && flags=(-C)
        if pretty=$(jq "${flags[@]}" . <<<"$body" 2>/dev/null); then
            printf '%s\n' "$pretty"
            return 0
        fi
    fi
    printf '%s\n' "$body"
}

# req_verbose_on - succeeds when the verbose mode is on.
req_verbose_on() {
    [[ $REQ_VERBOSE == 1 ]]
}

# req_verbose_request - with the verbose mode on, shows the data sent (set by
# req_build_curl_args), one ">>" line per form field or per line of raw_data. Prints
# nothing without data (a GET, or no parameters and no raw_data).
req_verbose_request() {
    local line
    req_verbose_on || return 0
    {
        if (( REQ_P_RAWSET )); then
            printf '%s\n' "$REQ_BODY"
        else
            for line in "${REQ_P_FORM[@]}"; do printf '%s\n' "$line"; done
            for line in "${REQ_P_FILES[@]}"; do printf '%s\n' "${line%%=*}=@${line#*=}"; done
        fi
    } | while IFS= read -r line || [[ -n $line ]]; do
        req_color dim; printf '>>'; req_color reset; printf ' %s\n' "${line%$'\r'}"
    done
}

# req_verbose_response - with the verbose mode on, shows the status line and the headers
# of the response (REQ_RESP_STATUSLINE, REQ_RESP_HEADERS), one "<<" line each.
req_verbose_response() {
    local line
    req_verbose_on || return 0
    for line in "$REQ_RESP_STATUSLINE" "${REQ_RESP_HEADERS[@]}"; do
        [[ -n $line ]] || continue
        req_color dim; printf '<<'; req_color reset; printf ' %s\n' "$line"
    done
    printf '\n'
}

# req_run_request <file> - validates, runs and shows: response, timing profile
# and a line of "=" that separates the result from the menu redrawn after it. Before
# sending, every ${key} in the url, headers, query, parameters and raw_data is replaced
# by its value in the environment REQ_ENV (default "default"); a key without a value
# stops the request with an error that says how to define it. With the "log" setting on,
# the request is written to the project's log just before it is sent and the response (or the
# failure) right after it arrives (log.sh).
req_run_request() {
    local file=$1 json status env=${REQ_ENV:-default}
    req_request_check "$file" || return 1
    json=$(<"$file")
    req_vars_load "$env" || return 1
    req_subst_json "$json" "$env" || return 1
    REQ_REQUEST_DIR=$(dirname "$(req_abs_path "$file")")
    req_build_curl_args "$REQ_SUBST_OUT" || return 1
    req_log_request "$file" "$env"

    req_method_color "$REQ_P_METHOD"; printf '%s' "$REQ_P_METHOD"; req_color reset
    printf ' %s\n' "$REQ_P_URL"
    req_verbose_request

    req_curl_exec; status=$?
    if (( status != 0 )); then
        req_log_failure "$status"
        req_err "request failed (curl exit code $status)"
        req_rule '='
        return 1
    fi

    req_log_response
    req_verbose_response

    printf 'HTTP '; req_paint_status "$REQ_RESP_STATUS"
    [[ -n $REQ_RESP_CTYPE ]] && printf '  %s' "$REQ_RESP_CTYPE"
    printf '\n\n'
    req_print_body "$REQ_RESP_CTYPE" "$REQ_RESP_BODY"
    printf '\n'
    req_print_profile
    req_rule '='
}

# ==== lib/nav.sh
# nav.sh - interactive navigation: directory and request menu, details screen.
#
# The menu is redrawn in place (the cursor moves up and erases the previous
# block) without clearing the screen. A request's result stays visible and the
# menu is redrawn right below it. Outside a terminal nothing is erased (used by tests).
#
# Keys: up/down move the selection, Enter opens/runs, Esc goes back (does nothing at the root),
# ":" enters command mode (see cmd.sh).

REQ_RAW_MAX_LINES=15    # lines of raw_data shown on the details screen
REQ_ESC_TIMEOUT=0.05    # wait for bytes after ESC to tell an arrow key from a bare Esc
REQ_INPUT_FD=0          # descriptor the keys are read from
REQ_KEY=""              # last key read: up, down, enter, esc, or the character itself

REQ_SCREEN_LINES=()     # lines of the current block
REQ_SCREEN_DRAWN=0      # rows of the block already printed in the terminal
REQ_SCREEN_EXTRA=0      # rows beyond one per line, from long lines that wrap
REQ_BASE_EXTRA=0

REQ_NAV_PROJECT=""      # name of the project (the folder of the .req), shown in the header
REQ_NAV_ROOT=""         # the menu root: the workspace of the project (set only by req_nav_root)
REQ_CUR_DIR=""          # directory being shown ("" = project root)
REQ_STACK_DIR=()        # navigation stack: previous directories and selections
REQ_STACK_SEL=()
REQ_VIEW=list           # list | detail | help | config
REQ_DETAIL_FILE=""
REQ_DETAIL_VALID=0

REQ_ITEM_KIND=()        # d | r, per item of the current list
REQ_ITEM_LABEL=()
REQ_ITEM_METHOD=()
REQ_ITEM_PATH=()
REQ_SEL=0
REQ_TOP=0

REQ_NAV_DIRTY=1         # 1 when the screen must be rebuilt (0 while only the prompt changes)
REQ_BASE_LINES=()       # last built screen, reused while nothing but the prompt changes

# req_read_key - reads a key into REQ_KEY. Fails (status 1) at end of input.
req_read_key() {
    local k rest=""
    REQ_KEY=""
    IFS= read -rsn1 -u "$REQ_INPUT_FD" k || return 1
    case $k in
        ''|$'\r') REQ_KEY=enter ;;
        $'\177'|$'\b') REQ_KEY=backspace ;;
        $'\e')
            IFS= read -rsn2 -t "$REQ_ESC_TIMEOUT" -u "$REQ_INPUT_FD" rest
            case $rest in
                '[A'|'OA') REQ_KEY=up ;;
                '[B'|'OB') REQ_KEY=down ;;
                '')        REQ_KEY=esc ;;
                *)         REQ_KEY=other ;;
            esac ;;
        *) REQ_KEY=$k ;;
    esac
    return 0
}

# --- screen ------------------------------------------------------------------

# req_screen_erase - erases the last drawn block (terminal only).
req_screen_erase() {
    if [[ -t 1 && $REQ_SCREEN_DRAWN -gt 0 ]]; then
        printf '\033[%dA\r\033[J' "$REQ_SCREEN_DRAWN"
    fi
    REQ_SCREEN_DRAWN=0
}

# req_screen_draw - replaces the previous block with REQ_SCREEN_LINES.
req_screen_draw() {
    req_screen_erase
    printf '%s\n' "${REQ_SCREEN_LINES[@]}"
    [[ -t 1 ]] && REQ_SCREEN_DRAWN=$(( ${#REQ_SCREEN_LINES[@]} + REQ_SCREEN_EXTRA ))
    return 0
}

# req_screen_add_long <text> - appends a line that is never truncated (so it can be
# copied whole). If it wraps, the extra terminal rows are counted for the redraw.
req_screen_add_long() {
    local cols
    cols=$(req_term_cols)
    REQ_SCREEN_LINES+=("$1")
    (( ${#1} > cols )) && REQ_SCREEN_EXTRA=$(( REQ_SCREEN_EXTRA + (${#1} - 1) / cols ))
    return 0
}

# req_marker - selection indicator.
req_marker() {
    if req_utf8; then printf '▸'; else printf '>'; fi
}

# --- data -----------------------------------------------------------------

# req_nav_rel <path> - path relative to the menu root (the workspace), when possible.
req_nav_rel() {
    printf '%s' "${1#"$REQ_NAV_ROOT"/}"
}

# req_nav_root <.req file> - decides the directory the menu starts in and never leaves:
# the project's workspace (REQ_NAV_ROOT). The single place that knows where the root is.
# Fails, with the reason already printed, when the workspace is not valid.
req_nav_root() {
    REQ_NAV_ROOT=$(req_project_workspace "$1") || { REQ_NAV_ROOT=""; return 1; }
}

# req_nav_load - loads the items of the current directory; at the root ("") they are
# the items of the workspace: its directories and its requests.
req_nav_load() {
    local kind a b c
    REQ_ITEM_KIND=(); REQ_ITEM_LABEL=(); REQ_ITEM_METHOD=(); REQ_ITEM_PATH=()
    while IFS=$'\t' read -r kind a b c; do
        REQ_ITEM_KIND+=("$kind"); REQ_ITEM_LABEL+=("$a")
        if [[ $kind == d ]]; then
            REQ_ITEM_METHOD+=(""); REQ_ITEM_PATH+=("$b")
        else
            REQ_ITEM_METHOD+=("$b"); REQ_ITEM_PATH+=("$c")
        fi
    done < <(req_list_dir "${REQ_CUR_DIR:-$REQ_NAV_ROOT}")
    REQ_SEL=0
    REQ_TOP=0
}

# req_nav_init <.req file> - sets the state up at the project root.
req_nav_init() {
    local pfile=$1
    [[ -f $pfile ]] || { req_err "project file not found: $pfile"; return 1; }
    req_nav_root "$pfile" || return 1
    REQ_NAV_PROJECT=$(req_abs_path "$(dirname "$pfile")"); REQ_NAV_PROJECT=${REQ_NAV_PROJECT##*/}
    REQ_CUR_DIR=""; REQ_STACK_DIR=(); REQ_STACK_SEL=()
    REQ_VIEW=list; REQ_DETAIL_FILE=""; REQ_DETAIL_VALID=0
    REQ_CMD_ACTIVE=0; REQ_CMD_BUF=""; REQ_STATUS=""; REQ_QUIT=0; REQ_NAV_DIRTY=1
    req_nav_load
}

# req_nav_save_cursor - saves where the menu is (directory and selected item, relative
# to the workspace) in the project's cursor file. Does nothing without a registered
# project; a write that fails is ignored, since the cursor is only a convenience.
req_nav_save_cursor() {
    local dir="" item=""
    [[ -n $REQ_PROJECT_ID && -n $REQ_NAV_ROOT ]] || return 0
    [[ -z $REQ_CUR_DIR ]] || dir=$(req_nav_rel "$REQ_CUR_DIR")
    (( ${#REQ_ITEM_PATH[@]} > REQ_SEL )) && item=$(req_nav_rel "${REQ_ITEM_PATH[REQ_SEL]}")
    req_cursor_save "$REQ_PROJECT_ID" "$dir" "$item" 2>/dev/null || true
    return 0
}

# req_nav_cursor_path_ok <relative path> - succeeds for "" or a plain relative path
# (no leading or trailing slash, no empty, "." or ".." component), so a hand-edited
# cursor file cannot lead outside the workspace.
req_nav_cursor_path_ok() {
    local parts comp
    [[ -z $1 ]] && return 0
    [[ $1 != /* && $1 != */ ]] || return 1
    IFS=/ read -ra parts <<<"$1"
    for comp in "${parts[@]}"; do
        [[ -n $comp && $comp != . && $comp != .. ]] || return 1
    done
}

# req_nav_restore_cursor - puts the menu where the project's cursor file says: the
# directory (the Esc stack is rebuilt on the way down) and the selected item. A directory
# that is gone leads to its nearest existing ancestor, an item that is gone to the first
# one; a missing or invalid file, no project or restore_cursor=no leave the root. Never
# an error. Call it right after req_nav_init.
req_nav_restore_cursor() {
    local file dir item path comp i found parts
    [[ -n $REQ_PROJECT_ID && -n $REQ_NAV_ROOT ]] || return 0
    [[ $(req_config_get restore_cursor) == yes ]] || return 0
    file=$(req_cursor_file "$REQ_PROJECT_ID")
    [[ -f $file ]] || return 0
    dir=$(req_kv_get "$file" dir) || dir=""
    item=$(req_kv_get "$file" item) || item=""
    req_nav_cursor_path_ok "$dir" && req_nav_cursor_path_ok "$item" || return 0
    if [[ -n $dir ]]; then
        IFS=/ read -ra parts <<<"$dir"
        path=${REQ_CUR_DIR:-$REQ_NAV_ROOT}
        for comp in "${parts[@]}"; do
            path=$path/$comp; found=-1
            for i in "${!REQ_ITEM_PATH[@]}"; do
                [[ ${REQ_ITEM_KIND[i]} == d && ${REQ_ITEM_PATH[i]} == "$path" ]] && found=$i
            done
            if (( found < 0 )); then item=""; break; fi
            REQ_SEL=$found
            REQ_STACK_DIR+=("$REQ_CUR_DIR"); REQ_STACK_SEL+=("$REQ_SEL")
            REQ_CUR_DIR=$path
            req_nav_load
        done
    fi
    [[ -n $item ]] || return 0
    path=$REQ_NAV_ROOT/$item
    for i in "${!REQ_ITEM_PATH[@]}"; do
        [[ ${REQ_ITEM_PATH[i]} == "$path" ]] && REQ_SEL=$i
    done
    return 0
}

# req_nav_refresh <path> - reloads the current directory (or the project root) and
# selects <path> in it, if present.
req_nav_refresh() {
    local want=$1 i
    req_nav_load
    for i in "${!REQ_ITEM_PATH[@]}"; do
        [[ ${REQ_ITEM_PATH[i]} == "$want" ]] && REQ_SEL=$i
    done
}

# --- screen building --------------------------------------------------

# req_nav_crumb - current path ("/" at the root).
req_nav_crumb() {
    if [[ -z $REQ_CUR_DIR ]]; then printf '/'; else printf '/%s' "$(req_nav_rel "$REQ_CUR_DIR")"; fi
}

# req_nav_build_list - builds REQ_SCREEN_LINES with the current directory's list.
req_nav_build_list() {
    local n=${#REQ_ITEM_KIND[@]} cols rows visible i end width pos
    local c_dim c_bold c_reset c_sel arrows hint tag label tail="" room
    cols=$(req_term_cols); rows=$(req_term_rows)
    c_dim=$(req_color dim); c_bold=$(req_color bold); c_reset=$(req_color reset)
    c_sel=$(req_color sel)
    REQ_SCREEN_LINES=(); REQ_SCREEN_EXTRA=0

    pos=""
    (( n > 0 )) && pos=" ($((REQ_SEL + 1))/$n)"
    # The project and the environment in use go after the position, when there is room.
    room=$(( cols - 5 - ${#pos} ))
    if [[ -n $REQ_NAV_PROJECT ]]; then
        tail="  $REQ_NAV_PROJECT @ ${REQ_ENV:-default}"
        if (( room - ${#tail} >= 12 )); then room=$(( room - ${#tail} )); else tail=""; fi
    fi
    REQ_SCREEN_LINES+=("${c_bold}req${c_reset} $(req_trunc "$(req_nav_crumb)" "$room")${c_dim}${pos}${tail}${c_reset}")

    if (( n == 0 )); then
        REQ_SCREEN_LINES+=("  ${c_dim}(empty)${c_reset}")
    else
        visible=$(( rows - 4 )); (( visible < 3 )) && visible=3
        (( n < visible )) && visible=$n
        (( REQ_SEL < REQ_TOP )) && REQ_TOP=$REQ_SEL
        (( REQ_SEL >= REQ_TOP + visible )) && REQ_TOP=$(( REQ_SEL - visible + 1 ))
        end=$(( REQ_TOP + visible ))
        width=$(( cols - 10 ))
        for (( i = REQ_TOP; i < end; i++ )); do
            if [[ ${REQ_ITEM_KIND[i]} == d ]]; then
                tag="dir   "; label=$(req_trunc "${REQ_ITEM_LABEL[i]}/" "$width")
            else
                tag=$(printf '%-6s' "${REQ_ITEM_METHOD[i]}"); label=$(req_trunc "${REQ_ITEM_LABEL[i]}" "$width")
            fi
            if (( i == REQ_SEL )); then
                # The whole selected row is highlighted, which replaces the method color.
                REQ_SCREEN_LINES+=("${c_sel}$(req_marker) ${tag} ${label}${c_reset}")
            elif [[ ${REQ_ITEM_KIND[i]} == d ]]; then
                REQ_SCREEN_LINES+=("  ${c_dim}${tag}${c_reset} ${c_bold}${label}${c_reset}")
            else
                REQ_SCREEN_LINES+=("  $(req_method_color "${REQ_ITEM_METHOD[i]}")${tag}${c_reset} ${label}")
            fi
        done
    fi

    if req_utf8; then arrows="↑↓"; else arrows="up/down"; fi
    hint="$arrows move   Enter open   : commands   :h help"
    [[ ${#REQ_STACK_DIR[@]} -gt 0 ]] && hint+="   Esc back"
    REQ_SCREEN_LINES+=("${c_dim}$(req_trunc "$hint" $((cols - 1)))${c_reset}")
}

# req_nav_build_detail - builds REQ_SCREEN_LINES with the open request's details.
# Invalid requests show their problems instead of the fields and do not run.
req_nav_build_detail() {
    local f=$REQ_DETAIL_FILE abs cols width c_dim c_bold c_reset problems line
    cols=$(req_term_cols); width=$(( cols - 4 ))
    c_dim=$(req_color dim); c_bold=$(req_color bold); c_reset=$(req_color reset)
    REQ_SCREEN_LINES=(); REQ_SCREEN_EXTRA=0

    if ! problems=$(req_request_check "$f" 2>&1); then
        REQ_DETAIL_VALID=0
        abs=$(req_abs_path "$f")
        REQ_SCREEN_LINES+=("$(req_color err)Invalid request:${c_reset}")
        req_screen_add_long "$abs"      # whole and on its own line, ready to copy
        while IFS= read -r line; do
            line=${line#"req: error: $abs: "}
            line=${line#"req: error: "}
            REQ_SCREEN_LINES+=("  $(req_trunc "$line" "$width")")
        done <<<"$problems"
        REQ_SCREEN_LINES+=("${c_dim}Fix the file and open it again.   Esc back${c_reset}")
        return 0
    fi

    REQ_DETAIL_VALID=1
    req_request_fields "$f"
    REQ_SCREEN_LINES+=("$(req_method_color "$REQ_F_METHOD")$(printf '%-6s' "$REQ_F_METHOD")${c_reset} ${c_bold}$(req_trunc "$REQ_F_NAME" $((cols - 9)))${c_reset}")
    REQ_SCREEN_LINES+=("  ${c_dim}url${c_reset}  $(req_trunc "$REQ_F_URL" $((width - 5)))")
    if [[ -n $REQ_F_DESC ]]; then
        REQ_F_DESC=${REQ_F_DESC//$'\n'/ }
        REQ_SCREEN_LINES+=("  ${c_dim}desc${c_reset} $(req_trunc "$REQ_F_DESC" $((width - 5)))")
    fi

    req_nav_detail_section "Headers" "$width" "${REQ_F_HEADERS[@]}"
    req_nav_detail_section "Query" "$width" "${REQ_F_QUERY[@]}"
    local sends_body=1 raw_title="Raw data" params_title="Parameters" raw_lines=()
    case $REQ_F_METHOD in POST|PUT|PATCH) ;; *) sends_body=0 ;; esac
    if (( ! sends_body )); then
        raw_title="Raw data (not sent with $REQ_F_METHOD)"
        params_title="Parameters (not sent with $REQ_F_METHOD)"
    elif (( REQ_F_RAW_SET )); then
        params_title="Parameters (not sent: raw data takes precedence)"
    fi
    req_nav_detail_section "$params_title" "$width" "${REQ_F_PARAMS[@]}"
    if (( REQ_F_RAW_SET )); then
        mapfile -t raw_lines <<<"$REQ_F_RAW"
        if (( ${#raw_lines[@]} > REQ_RAW_MAX_LINES )); then
            local more=$(( ${#raw_lines[@]} - REQ_RAW_MAX_LINES ))
            raw_lines=("${raw_lines[@]:0:REQ_RAW_MAX_LINES}" "... ($more more lines)")
        fi
        req_nav_detail_section "$raw_title" "$width" "${raw_lines[@]}"
    fi

    REQ_SCREEN_LINES+=("${c_dim}Enter run   : commands   :h help   Esc back${c_reset}")
}

# req_nav_build_help - builds REQ_SCREEN_LINES with the help screen, from REQ_HELP_ROWS.
req_nav_build_help() {
    local cols row keys w=0 c_dim c_bold c_reset
    cols=$(req_term_cols)
    c_dim=$(req_color dim); c_bold=$(req_color bold); c_reset=$(req_color reset)
    REQ_SCREEN_LINES=(); REQ_SCREEN_EXTRA=0
    for row in "${REQ_HELP_ROWS[@]}"; do
        [[ $row == *'|'* ]] && { keys=${row%%|*}; (( ${#keys} > w )) && w=${#keys}; }
    done
    REQ_SCREEN_LINES+=("${c_bold}req${c_reset} help")
    for row in "${REQ_HELP_ROWS[@]}"; do
        if [[ $row == *'|'* ]]; then
            keys=$(printf '%-*s' "$w" "${row%%|*}")
            REQ_SCREEN_LINES+=("  $(req_trunc "$keys  ${row#*|}" $((cols - 3)))")
        else
            REQ_SCREEN_LINES+=("${c_dim}${row}${c_reset}")
        fi
    done
    REQ_SCREEN_LINES+=("${c_dim}Press any key to go back${c_reset}")
}

# req_nav_build_config - the settings screen (:config): every known key with its effective
# value, its default and what it does; "project" marks the values set by the project's file, which wins over the global one.
req_nav_build_config() {
    local cols key w=0 value def src c_dim c_bold c_reset
    cols=$(req_term_cols)
    c_dim=$(req_color dim); c_bold=$(req_color bold); c_reset=$(req_color reset)
    REQ_SCREEN_LINES=(); REQ_SCREEN_EXTRA=0
    for key in "${REQ_CONFIG_KEYS[@]}"; do (( ${#key} > w )) && w=${#key}; done
    REQ_SCREEN_LINES+=("${c_bold}req${c_reset} settings   ${c_dim}$(req_config_file)${c_reset}")
    [[ -z $REQ_PROJECT_ID ]] || REQ_SCREEN_LINES+=("${c_dim}project settings   $(req_config_local_file)${c_reset}")
    for key in "${REQ_CONFIG_KEYS[@]}"; do
        value=$(req_config_get "$key"); def=${REQ_CONFIG_DEFAULT[$key]}
        src=""; [[ -z ${REQ_CONFIG_LOCAL[$key]+x} ]] || src="project"
        REQ_SCREEN_LINES+=("  $(req_trunc "$(printf '%-*s  %-4s  default %-4s  %-7s  %s' "$w" "$key" "$value" "$def" "$src" "${REQ_CONFIG_DESC[$key]}")" $((cols - 3)))")
    done
    REQ_SCREEN_LINES+=("${c_dim}Change one with :config key=value (:config -g key=value for the global file)   Press any key to go back${c_reset}")
}

# req_nav_detail_section <title> <width> [line...]
# Appends the title and the given lines; does nothing if there are no lines.
req_nav_detail_section() {
    local title=$1 width=$2 line
    shift 2
    (( $# > 0 )) || return 0
    REQ_SCREEN_LINES+=("  $(req_color dim)${title}$(req_color reset)")
    for line in "$@"; do
        line=${line//$'\n'/ }
        REQ_SCREEN_LINES+=("    $(req_trunc "$line" $((width - 2)))")
    done
}

# --- state transitions --------------------------------------------------

# req_nav_open - Enter on the list: enters the directory or opens the request's details.
req_nav_open() {
    local i=$REQ_SEL
    if [[ ${REQ_ITEM_KIND[i]} == d ]]; then
        REQ_STACK_DIR+=("$REQ_CUR_DIR"); REQ_STACK_SEL+=("$REQ_SEL")
        REQ_CUR_DIR=${REQ_ITEM_PATH[i]}
        req_nav_load
    else
        REQ_DETAIL_FILE=${REQ_ITEM_PATH[i]}
        REQ_VIEW=detail
    fi
}

# req_nav_back - Esc on the list: goes up one directory; does nothing at the root.
req_nav_back() {
    local last=$(( ${#REQ_STACK_DIR[@]} - 1 )) sel
    (( last >= 0 )) || return 0
    REQ_CUR_DIR=${REQ_STACK_DIR[last]}
    sel=${REQ_STACK_SEL[last]}
    unset "REQ_STACK_DIR[last]" "REQ_STACK_SEL[last]"
    req_nav_load
    REQ_SEL=$sel
}

# req_nav_execute - Enter on the details: erases the menu, runs and leaves the result on screen.
req_nav_execute() {
    req_screen_erase
    req_run_request "$REQ_DETAIL_FILE"
    return 0
}

# req_nav_handle <key> - applies a key to the current state.
req_nav_handle() {
    local key=$1 n=${#REQ_ITEM_KIND[@]}
    REQ_NAV_DIRTY=1
    if (( REQ_CMD_ACTIVE )); then
        req_cmd_key "$key"
        return 0
    fi
    if [[ $REQ_VIEW == help || $REQ_VIEW == config ]]; then
        REQ_VIEW=$REQ_HELP_BACK     # any key closes the help and the settings
        return 0
    fi
    if [[ $key == : ]]; then
        REQ_CMD_ACTIVE=1; REQ_CMD_BUF=""
        REQ_NAV_DIRTY=0
        return 0
    fi
    if [[ $REQ_VIEW == detail ]]; then
        case $key in
            enter) (( REQ_DETAIL_VALID )) && req_nav_execute ;;
            esc)   REQ_VIEW=list ;;
        esac
    else
        case $key in
            up)    (( n > 0 )) && REQ_SEL=$(( (REQ_SEL + n - 1) % n )) ;;
            down)  (( n > 0 )) && REQ_SEL=$(( (REQ_SEL + 1) % n )) ;;
            enter) (( n > 0 )) && req_nav_open ;;
            esc)   req_nav_back ;;
        esac
    fi
    return 0
}

# req_nav_overlay - puts the command prompt and the one-shot status on the screen.
req_nav_overlay() {
    local last=$(( ${#REQ_SCREEN_LINES[@]} - 1 )) cursor='_'
    req_utf8 && cursor='█'
    (( REQ_CMD_ACTIVE )) && REQ_SCREEN_LINES[last]=":${REQ_CMD_BUF}${cursor}"
    if [[ -n $REQ_STATUS ]]; then
        REQ_SCREEN_LINES+=("$(req_color dim)${REQ_STATUS}$(req_color reset)")
        REQ_STATUS=""
    fi
}

# req_nav_run <.req file> - main loop; ends at end of input or on :q. The menu position
# is saved in the project's cursor file when the loop ends or the process is signaled.
# shellcheck disable=SC2034  # REQ_EXIT_HOOK is read by req_on_exit (core.sh)
req_nav_run() {
    req_nav_init "$1" || return 1
    req_nav_restore_cursor
    REQ_EXIT_HOOK=req_nav_save_cursor      # a signal ends the process: save the cursor then too
    [[ -t 1 ]] && printf '\033[?25l'
    [[ -t 0 ]] && stty -echo 2>/dev/null
    while :; do
        if (( REQ_NAV_DIRTY )); then
            case $REQ_VIEW in
                detail) req_nav_build_detail ;;
                help)   req_nav_build_help ;;
                config) req_nav_build_config ;;
                *)      req_nav_build_list ;;
            esac
            REQ_BASE_LINES=("${REQ_SCREEN_LINES[@]}"); REQ_BASE_EXTRA=$REQ_SCREEN_EXTRA
            REQ_NAV_DIRTY=0
        else
            REQ_SCREEN_LINES=("${REQ_BASE_LINES[@]}"); REQ_SCREEN_EXTRA=$REQ_BASE_EXTRA
        fi
        req_nav_overlay
        req_screen_draw
        req_read_key || break
        req_nav_handle "$REQ_KEY"
        (( REQ_QUIT )) && break
    done
    req_nav_save_cursor; REQ_EXIT_HOOK=""      # :q and the end of the input
    [[ -t 0 ]] && stty echo 2>/dev/null
    [[ -t 1 ]] && printf '\033[?25h'
    return 0
}

# req_nav_start - interactive entry point: uses the .req of the current directory.
# Without one, offers to initialize a project right here.
req_nav_start() {
    local pfile
    [[ -t 0 && -t 1 ]] || req_die "interactive mode needs a terminal (use 'req run <file>' in scripts)"
    if ! pfile=$(req_project_find .); then
        printf 'No %s file found in %s.\n' "$REQ_PROJECT_FILE" "$PWD"
        if ! req_confirm "Initialize a req project here?"; then
            printf "Nothing created. Run 'req init' whenever you want to start a project.\n"
            return 1
        fi
        req_project_init . || return 1
        printf 'Created %s (workspace: .)\nUse :n to create a new request.\n' "$REQ_PROJECT_FILE"
        pfile=$(req_project_find .) || return 1
    fi
    req_project_activate "$(dirname "$pfile")"
    req_config_load_local || true      # the project's settings win over the global ones
    req_nav_run "$pfile"
}

# ==== lib/wizard.sh
# wizard.sh - interactive prompts to create, edit and duplicate requests and directories.
# All answers come from REQ_INPUT_FD, so the flows can be driven by tests.
#
# Conventions: an empty name (or end of input) cancels a flow; any other prompt
# accepts its default with Enter.

REQ_REPLY_JSON="{}"     # last object built by req_ask_pairs / req_ask_preset
REQ_PRESET=none         # format chosen by the last req_ask_preset: json, text, html or none
REQ_LAST_FILE=""        # last request file written by a wizard
REQ_LAST_DIR=""         # last directory created by a wizard

# req_cancelled - prints the cancellation notice and fails.
req_cancelled() {
    printf 'Cancelled.\n'
    return 1
}

# req_ask_name <default> [what] - asks for a slug; empty cancels (without default).
req_ask_name() {
    local def=${1-} what=${2:-Name} label
    label="$what (a slug, e.g. list-users)"
    [[ -z $def ]] && label+=" - empty to cancel"
    while :; do
        req_prompt "$label" "$def" || return 1
        [[ -n $REQ_REPLY ]] || return 1
        req_valid_name "$REQ_REPLY" && return 0
        req_err "invalid name: use lowercase letters, digits and hyphens"
    done
}

# req_ask_method [default] - asks for an HTTP method.
req_ask_method() {
    local def=${1:-GET}
    while :; do
        req_prompt "Method (${REQ_METHODS[*]})" "$def" || return 1
        if req_valid_method "$REQ_REPLY"; then
            REQ_REPLY=${REQ_REPLY^^}
            return 0
        fi
        req_err "invalid method: $REQ_REPLY"
    done
}

# req_ask_url [default] - asks for the url; it cannot be empty.
req_ask_url() {
    while :; do
        req_prompt "URL" "${1-}" || return 1
        [[ -n $REQ_REPLY ]] && return 0
        req_err "the url is required"
    done
}

# req_preset_headers <json|text|html|none> - prints the headers object of a format preset.
req_preset_headers() {
    local ct
    case $1 in
        json) ct=application/json ;;
        text) ct=text/plain ;;
        html) ct=text/html ;;
        *)    printf '{}'; return 0 ;;
    esac
    jq -cn --arg ct "$ct" '{"Content-Type": $ct, "Accept": $ct}'
}

# req_ask_preset - asks for a popular format (json, text, html); the matching
# headers object ends up in REQ_REPLY_JSON and the choice in REQ_PRESET.
req_ask_preset() {
    local choice
    while :; do
        req_prompt "Format preset: 1) json  2) text  3) html  4) none" "4" || return 1
        case ${REQ_REPLY,,} in
            1|json) choice=json ;;
            2|text) choice=text ;;
            3|html) choice=html ;;
            4|none) choice=none ;;
            *) req_err "choose 1-4"; continue ;;
        esac
        REQ_PRESET=$choice
        REQ_REPLY_JSON=$(req_preset_headers "$choice")
        return 0
    done
}

# req_ask_pairs <title> <separator> <json> - edits an object of simple values.
# One "key<separator>value" per line sets an entry, "-key" removes it, an empty
# line finishes. The resulting object ends up in REQ_REPLY_JSON.
req_ask_pairs() {
    local title=$1 sep=$2 json=${3:-"{}"} line key val
    printf '%s: key%svalue per line, "-key" removes, empty line to finish\n' "$title" "$sep"
    while :; do
        req_prompt "  $title" "" || break
        line=$(req_trim "$REQ_REPLY")
        [[ -n $line ]] || break
        if [[ $line == -* ]]; then
            key=$(req_trim "${line#-}")
            json=$(jq -c --arg k "$key" 'del(.[$k])' <<<"$json")
            continue
        fi
        if [[ $line != *"$sep"* ]]; then
            req_err "expected key${sep}value"
            continue
        fi
        key=$(req_trim "${line%%"$sep"*}")
        val=$(req_trim "${line#*"$sep"}")
        if [[ -z $key ]]; then
            req_err "the key cannot be empty"
            continue
        fi
        json=$(jq -c --arg k "$key" --arg v "$val" '. + {($k): $v}' <<<"$json")
    done
    REQ_REPLY_JSON=$json
}

# req_raw_text <json value> - prints raw_data as editable text: indented JSON for an
# object or list, the string itself otherwise ("" when there is no value).
req_raw_text() {
    [[ -n ${1-} ]] || return 0
    if [[ $(jq -r type <<<"$1") == string ]]; then jq -r . <<<"$1"; else jq . <<<"$1"; fi
}

# req_ask_raw_data <current> [ask] - edits the raw body (raw_data). <current> is the
# JSON value now stored ("" when none). The text is edited in the external editor
# (req_edit_text), or on one prompt line when there is no editor. An empty result
# clears raw_data. An object or list is stored as native JSON; any other text is
# stored as a string, but when [ask] is 1 (the default) the user is first offered to
# edit it again, since it was probably meant to be JSON. On success REQ_REPLY_JSON
# holds the new JSON value ("" = clear) and the status is 0; status 1 keeps it as is.
req_ask_raw_data() {
    local text native status ask=${2:-1}
    text=$(req_raw_text "${1-}")
    while :; do
        if req_edit_text "$text" .json; then
            text=$REQ_EDIT_TEXT
        else
            status=$?
            if (( status == 1 )); then req_err "the editor failed; raw data left as it was"; return 1; fi
            local def=$text
            [[ $def == *$'\n'* ]] && def=$(jq -c . <<<"$def" 2>/dev/null || tr '\n' ' ' <<<"$def")
            req_prompt "Raw data on one line (- clears; set an editor with \$EDITOR for more)" "$def" || return 1
            text=$REQ_REPLY
            [[ $text == - ]] && text=""
        fi
        if [[ -z $(req_trim "$text") ]]; then REQ_REPLY_JSON=""; return 0; fi
        native=$(jq -c 'select(type == "object" or type == "array")' <<<"$text" 2>/dev/null)
        if [[ -n $native ]]; then REQ_REPLY_JSON=$native; return 0; fi
        if (( ask )); then
            req_prompt "Not a JSON object or list: 1) edit again  2) keep as text  3) discard" "1" || return 1
            case ${REQ_REPLY,,} in
                1|e|edit) continue ;;
                3|d|discard) return 1 ;;
                2|k|keep|t|text) ;;
                *) req_err "choose 1-3"; continue ;;
            esac
        fi
        REQ_REPLY_JSON=$(jq -cn --arg t "$text" '$t')
        return 0
    done
}

# req_wizard_new <directory> - creates a request in the directory.
req_wizard_new() {
    local dir=$1 name method url desc="" headers="{}" query="{}" params="{}" raw="" json target
    req_ask_name "" || { req_cancelled; return 1; }
    name=$REQ_REPLY
    req_ask_method GET || { req_cancelled; return 1; }
    method=$REQ_REPLY
    target=$dir/$(req_request_filename "$name" "$method")
    [[ ! -e $target ]] || { req_err "$target already exists"; return 1; }
    req_ask_url "" || { req_cancelled; return 1; }
    url=$REQ_REPLY

    if req_confirm "Add optional fields (description, headers, query, parameters)?" n; then
        req_prompt "Description" "" && desc=$REQ_REPLY
        REQ_PRESET=none
        req_ask_preset && headers=$REQ_REPLY_JSON
        req_ask_pairs "Headers" ":" "$headers" && headers=$REQ_REPLY_JSON
        req_ask_pairs "Query" "=" "{}" && query=$REQ_REPLY_JSON
        case $method in
            POST|PUT|PATCH)
                # With a format preset the body is usually raw: offer the editor first, and
                # ask for form parameters only when it is declined (or there is no preset).
                if [[ $REQ_PRESET != none ]] &&
                   req_confirm "Write the body (raw data) in your editor?" y; then
                    # Only JSON is questioned when the text is not an object or list.
                    local ask=0; [[ $REQ_PRESET == json ]] && ask=1
                    req_ask_raw_data "" "$ask" && raw=$REQ_REPLY_JSON
                else
                    req_ask_pairs "Parameters" "=" "{}" && params=$REQ_REPLY_JSON
                fi ;;
        esac
    fi

    json=$(jq -cn --arg d "$desc" --argjson h "$headers" --argjson q "$query" --argjson p "$params" \
        --arg r "$raw" \
        '{description: $d, headers: $h, query: $q, parameters: $p}
         + (if $r == "" then {} else {raw_data: ($r | fromjson)} end)')
    REQ_LAST_FILE=$(req_request_write "$dir" "$name" "$method" "$url" "$json") || return 1
    printf 'Created %s\n' "$REQ_LAST_FILE"
}

# req_edit_show <json> - prints the numbered fields of the request being edited.
req_edit_show() {
    jq -r '
        def count: length | if . == 1 then "1 entry" else "\(.) entries" end;
        "  1) name         \(.name)",
        "  2) method       \(.method)",
        "  3) url          \(.url)",
        "  4) description  \(.description // "")",
        "  5) headers      \((.headers // {}) | count)",
        "  6) query        \((.query // {}) | count)",
        "  7) parameters   \((.parameters // {}) | count)",
        "  8) raw data     \(.raw_data // "" | if . == "" then "none"
                              elif type == "string" then "text, \(length) chars"
                              elif type == "array" then "JSON list, \(length) items"
                              else "JSON object, \(length) keys" end)"' <<<"$1"
}

# req_wizard_edit <file> - field menu for a request. Changing the name or the
# method renames the file. Returns 0 after saving and 1 when cancelled.
req_wizard_edit() {
    local file=$1 dir json name method url target fields newfile cur ask
    dir=$(dirname "$file")
    req_request_check "$file" 2>/dev/null || {
        req_err "cannot edit an invalid request, fix the file first: $(req_abs_path "$file")"; return 1; }
    json=$(<"$file")

    while :; do
        printf 'Editing %s\n' "${file##*/}"
        req_edit_show "$json"
        req_prompt "Field to edit (1-8), s to save, q to cancel" "" || { req_cancelled; return 1; }
        case ${REQ_REPLY,,} in
            1) req_ask_name "$(jq -r .name <<<"$json")" &&
                   json=$(jq -c --arg v "$REQ_REPLY" '.name = $v' <<<"$json") ;;
            2) req_ask_method "$(jq -r .method <<<"$json")" &&
                   json=$(jq -c --arg v "$REQ_REPLY" '.method = $v' <<<"$json") ;;
            3) req_ask_url "$(jq -r .url <<<"$json")" &&
                   json=$(jq -c --arg v "$REQ_REPLY" '.url = $v' <<<"$json") ;;
            4) cur=$(jq -r '.description // ""' <<<"$json")
               if req_prompt "Description (- clears)" "$cur"; then
                   [[ $REQ_REPLY == - ]] && REQ_REPLY=""
                   json=$(jq -c --arg v "$REQ_REPLY" '.description = $v' <<<"$json")
               fi ;;
            5) req_ask_pairs "Headers" ":" "$(jq -c '.headers // {}' <<<"$json")" &&
                   json=$(jq -c --argjson v "$REQ_REPLY_JSON" '.headers = $v' <<<"$json") ;;
            6) req_ask_pairs "Query" "=" "$(jq -c '.query // {}' <<<"$json")" &&
                   json=$(jq -c --argjson v "$REQ_REPLY_JSON" '.query = $v' <<<"$json") ;;
            7) req_ask_pairs "Parameters" "=" "$(jq -c '.parameters // {}' <<<"$json")" &&
                   json=$(jq -c --argjson v "$REQ_REPLY_JSON" '.parameters = $v' <<<"$json") ;;
            8) cur=$(jq -c '.raw_data // ""' <<<"$json")
               [[ $cur == '""' ]] && cur=""
               # Free text is not questioned when the request declares a non-JSON Content-Type.
               ask=$(jq -r '[(.headers // {}) | to_entries[] | select(.key | ascii_downcase == "content-type")
                             | .value | tostring | ascii_downcase] as $c
                            | if ($c | length) > 0 and ($c | all(contains("json") | not)) then 0 else 1 end' <<<"$json")
               if req_ask_raw_data "$cur" "$ask"; then
                   if [[ -z $REQ_REPLY_JSON ]]; then
                       json=$(jq -c 'del(.raw_data)' <<<"$json")
                   else
                       json=$(jq -c --argjson v "$REQ_REPLY_JSON" '.raw_data = $v' <<<"$json")
                   fi
               fi ;;
            s|save)
                name=$(jq -r .name <<<"$json"); method=$(jq -r '.method | ascii_upcase' <<<"$json")
                url=$(jq -r .url <<<"$json")
                target=$dir/$(req_request_filename "$name" "$method")
                if [[ $target != "$file" && -e $target ]]; then
                    req_err "$target already exists"
                    continue
                fi
                fields=$(jq -c 'del(.name, .method, .url)' <<<"$json")
                newfile=$(req_request_write "$dir" "$name" "$method" "$url" "$fields") || continue
                [[ $newfile == "$file" ]] || rm -f "$file"
                REQ_LAST_FILE=$newfile
                printf 'Saved %s\n' "$newfile"
                return 0 ;;
            q|quit|cancel) req_cancelled; return 1 ;;
            *) req_err "choose 1-8, s or q" ;;
        esac
    done
}

# req_wizard_copy_request <file> [name] - copies a request under a new name, asked for
# (default <name>-copy) unless given; no edit follows. REQ_LAST_FILE is the copy.
req_wizard_copy_request() {
    local file=$1 name=${2-} dir oname method url fields target
    dir=$(dirname "$file")
    req_request_check "$file" 2>/dev/null || {
        req_err "cannot copy an invalid request, fix the file first: $(req_abs_path "$file")"; return 1; }
    oname=$(req_request_get "$file" name)
    method=$(req_request_get "$file" method); method=${method^^}
    url=$(req_request_get "$file" url)
    fields=$(jq -c 'del(.name, .method, .url)' "$file")

    if [[ -z $name ]]; then
        while :; do
            req_ask_name "$oname-copy" || { req_cancelled; return 1; }
            target=$dir/$(req_request_filename "$REQ_REPLY" "$method")
            [[ ! -e $target ]] && break
            req_err "$target already exists"
        done
        name=$REQ_REPLY
    else
        req_valid_name "$name" || {
            req_err "invalid name: \"$name\" (use lowercase letters, digits and hyphens)"; return 1; }
        target=$dir/$(req_request_filename "$name" "$method")
        [[ ! -e $target ]] || { req_err "$target already exists"; return 1; }
    fi
    REQ_LAST_FILE=$(req_request_write "$dir" "$name" "$method" "$url" "$fields") || return 1
    printf 'Created %s\n' "$REQ_LAST_FILE"
}

# req_wizard_duplicate <file> - copies a request under a new name, then opens the
# edit menu on the copy. Cancelling the edit keeps the copy.
req_wizard_duplicate() {
    req_wizard_copy_request "$1" || return 1
    req_wizard_edit "$REQ_LAST_FILE"
    return 0
}

# req_wizard_mkdir <parent> [name] - creates a directory inside <parent> (the workspace at
# the menu root). The name is asked for unless given. REQ_LAST_DIR is the new directory.
req_wizard_mkdir() {
    local parent=$1 name=${2-}
    if [[ -z $name ]]; then
        req_ask_name "" "Directory name" || { req_cancelled; return 1; }
        name=$REQ_REPLY
    fi
    req_valid_name "$name" || {
        req_err "invalid directory name: \"$name\" (use a slug: lowercase letters, digits and hyphens)"
        return 1; }
    [[ ! -e $parent/$name ]] || { req_err "$parent/$name already exists"; return 1; }
    mkdir "$parent/$name" 2>/dev/null || { req_err "cannot create $parent/$name"; return 1; }
    REQ_LAST_DIR=$parent/$name
    printf 'Created directory %s\n' "$REQ_LAST_DIR"
}

# req_wizard_rename_dir <directory> [name] - renames a directory (the last component of
# its path); the new name is asked for unless given. Returns 0 after renaming;
# REQ_LAST_DIR is the new path. An unchanged name returns 1 without touching anything.
req_wizard_rename_dir() {
    local dir=${1%/} name=${2-} target
    [[ -d $dir ]] || { req_err "directory does not exist: $dir"; return 1; }
    if [[ -z $name ]]; then
        req_ask_name "${dir##*/}" "New directory name" || { req_cancelled; return 1; }
        name=$REQ_REPLY
    fi
    req_valid_name "$name" || {
        req_err "invalid directory name: \"$name\" (use a slug: lowercase letters, digits and hyphens)"
        return 1; }
    dir=$(req_abs_path "$dir")
    target=${dir%/*}/$name
    if [[ $target == "$dir" ]]; then
        printf 'Name unchanged.\n'
        return 1
    fi
    [[ ! -e $target ]] || { req_err "$target already exists"; return 1; }
    mv -- "$dir" "$target" 2>/dev/null || { req_err "cannot rename $dir"; return 1; }
    REQ_LAST_DIR=$target
    printf 'Renamed %s to %s\n' "$dir" "$target"
}

# req_wizard_copy_dir <directory> [name] - copies a directory with everything inside it,
# next to the original. The name of the copy is asked for (default <name>-copy) unless
# given. Returns 0 after copying; REQ_LAST_DIR is the copy.
req_wizard_copy_dir() {
    local dir=${1%/} name=${2-} target
    [[ -d $dir ]] || { req_err "directory does not exist: $dir"; return 1; }
    dir=$(req_abs_path "$dir")
    if [[ -z $name ]]; then
        while :; do
            req_ask_name "${dir##*/}-copy" "Name of the copy" || { req_cancelled; return 1; }
            [[ ! -e ${dir%/*}/$REQ_REPLY ]] && break
            req_err "${dir%/*}/$REQ_REPLY already exists"
        done
        name=$REQ_REPLY
    fi
    req_valid_name "$name" || {
        req_err "invalid directory name: \"$name\" (use a slug: lowercase letters, digits and hyphens)"
        return 1; }
    target=${dir%/*}/$name
    [[ ! -e $target ]] || { req_err "$target already exists"; return 1; }
    cp -RP -- "$dir" "$target" 2>/dev/null || {
        rm -rf -- "$target"; req_err "cannot copy $dir"; return 1; }
    REQ_LAST_DIR=$target
    printf 'Copied %s to %s\n' "$dir" "$target"
}

# req_wizard_remove_request <file> - asks "[y/N]" and removes the request file. It
# works for invalid requests too (only the file name matters). Returns 0 after
# removing; REQ_LAST_FILE is the removed path. Anything but "y" keeps the file.
req_wizard_remove_request() {
    local file=$1
    [[ -f $file ]] || { req_err "request not found: $file"; return 1; }
    printf 'Remove %s\n' "$(req_abs_path "$file")"
    if ! req_confirm "Remove this request?" n; then
        printf 'Kept.\n'
        return 1
    fi
    rm -f -- "$file" 2>/dev/null || { req_err "cannot remove $file"; return 1; }
    REQ_LAST_FILE=$file
    printf 'Removed %s\n' "$file"
}

# req_wizard_remove_dir <directory> <workspace> - removes a directory and everything inside
# it, after a red warning with the full path and the size of the contents and a "[y/N]"
# question (default no). Only a directory strictly inside the workspace (physical path) is
# ever deleted, and never a symbolic link: the workspace itself, its parents, anything
# outside it and links are refused. Returns 0 after removing; REQ_LAST_DIR is the directory.
req_wizard_remove_dir() {
    local dir=${1%/} root abs files dirs red reset
    [[ -d $dir ]] || { req_err "directory does not exist: $dir"; return 1; }
    abs=$(req_abs_path "$dir")
    root=$(cd -P "$2" 2>/dev/null && pwd) || { req_err "workspace not found: $2"; return 1; }
    if [[ -L $dir ]]; then
        req_err "refusing to remove $abs: it is a symbolic link (links are not accepted)"
        return 1
    fi
    if [[ $abs != "$root"/?* ]]; then
        req_err "refusing to remove $abs: it is not a directory inside the workspace ($root)"
        return 1
    fi
    red=$(req_color err); reset=$(req_color reset)
    files=$(find "$abs" -mindepth 1 ! -type d | wc -l)
    dirs=$(find "$abs" -mindepth 1 -type d | wc -l)
    printf '%sRemove the directory %s and everything inside it: %d files in %d subdirectories. This cannot be undone.%s\n' \
        "$red" "$abs" "${files//[[:space:]]/}" "${dirs//[[:space:]]/}" "$reset"
    if ! req_confirm "Remove it?" n; then
        printf 'Kept.\n'
        return 1
    fi
    rm -rf -- "$abs" 2>/dev/null
    [[ ! -e $abs ]] || { req_err "could not remove everything in $abs"; return 1; }
    REQ_LAST_DIR=$dir
    printf 'Removed %s\n' "$abs"
}

# ==== lib/cmd.sh
# cmd.sh - command mode (":") for the interactive menu.
#
# Commands:
#   :n            new request in the current directory (wizard)
#   :nd [name]    new directory (alias :mkdir); at the root it is also listed in the .req
#   :ed [name]    rename the selected directory
#   :cp [name]    copy the selected directory or request, asking for the new name (default <name>-copy)
#   :rm           remove the selected request or directory (with its contents), after a [y/N] confirmation
#   :e            edit the selected request (alias :edit)
#   :d            duplicate the selected request and edit the copy (alias :dup)
#   :q            quit without asking (alias :quit)
#   :env [name]   show the project's environments, or switch the session to one
#   :log [yes|no] switch the log of requests and responses for this session
#   :v [yes|no]   switch the verbose mode (>> and <<) for this session
#   :config [-g] [k=v] show the settings, or set one for the project or, with -g, globally (~/.req/config)
#   :h            help: every key and command (alias :help)
# Esc leaves command mode; Backspace on an empty line does too.

# shellcheck disable=SC2034  # the REQ_* state below is shared with nav.sh

REQ_CMD_ACTIVE=0        # 1 while a command is being typed
REQ_CMD_BUF=""          # the command typed so far
REQ_STATUS=""           # one-shot message shown under the menu
REQ_QUIT=0              # set by :q, ends the main loop

# The help screen (:h) is built from this single table, "keys|description"; a line
# without "|" is a section title. Every new key or command gets a row here.
REQ_HELP_ROWS=(
    "Keys"
    "up/down|move the selection (wraps around)"
    "Enter|open a directory or request; on the details, run it"
    "Esc|go back (details, then list, then parent directory)"
    ":|command mode (Esc cancels)"
    "Commands"
    ":n|new request in the current directory"
    ":nd [name]|new directory (alias :mkdir)"
    ":ed [name]|rename the directory under the cursor (a request is edited with :e)"
    ":cp [name]|copy the directory (with its contents) or request under the cursor"
    ":rm|remove the selected request or directory, with a y/N question first"
    ":e|edit the selected request (alias :edit)"
    ":d|duplicate the selected request (alias :dup)"
    ":env [name]|show the environments of the project, or switch to one (REQ_ENV)"
    ":log [yes|no]|switch the log of requests and responses in this session (setting: log)"
    ":v [yes|no]|switch the verbose mode (>> sent, << received) in this session (REQ_VERBOSE)"
    ":config [-g] [key=value]|show the settings, or change one (this project's; -g: global ~/.req/config)"
    ":h|this help (alias :help)"
    ":q|quit (alias :quit)"
)
REQ_HELP_BACK=list      # view to return to when the help screen closes

# req_cmd_key <key> - handles one key while in command mode.
req_cmd_key() {
    local key=$1 line
    case $key in
        esc)
            REQ_CMD_ACTIVE=0; REQ_CMD_BUF="" ;;
        enter)
            line=$REQ_CMD_BUF
            REQ_CMD_ACTIVE=0; REQ_CMD_BUF=""
            req_cmd_run "$line" ;;
        backspace)
            if [[ -z $REQ_CMD_BUF ]]; then
                REQ_CMD_ACTIVE=0
            else
                REQ_CMD_BUF=${REQ_CMD_BUF%?}
                REQ_NAV_DIRTY=0     # only the prompt line changes
            fi ;;
        up|down|other) REQ_NAV_DIRTY=0 ;;
        *)
            if (( ${#key} == 1 )); then
                REQ_CMD_BUF+=$key
                REQ_NAV_DIRTY=0
            fi ;;
    esac
    return 0
}

# req_cmd_run <line> - runs one command line.
req_cmd_run() {
    local line cmd arg
    line=$(req_trim "$1")
    cmd=${line%%[[:space:]]*}
    arg=$(req_trim "${line#"$cmd"}")
    case $cmd in
        '')           ;;
        q|quit)       REQ_QUIT=1 ;;
        n|new)        req_cmd_new ;;
        nd|mkdir)     req_cmd_mkdir "$arg" ;;
        ed)           req_cmd_rename_dir "$arg" ;;
        cp)           req_cmd_copy "$arg" ;;
        rm)           req_cmd_remove ;;
        e|edit)       req_cmd_edit ;;
        d|dup)        req_cmd_dup ;;
        env)          req_cmd_env "$arg" ;;
        config)       req_cmd_config "$arg" ;;
        log)          req_cmd_log "$arg" ;;
        v|verbose)    req_cmd_verbose "$arg" ;;
        h|help)       REQ_HELP_BACK=$REQ_VIEW; REQ_VIEW=help ;;
        *)            REQ_STATUS="unknown command :$cmd (:h lists the commands)" ;;
    esac
    return 0
}

# req_nav_prompt_begin / req_nav_prompt_end - hand the terminal over to the
# prompts (menu erased, cursor and echo on) and take it back afterwards.
req_nav_prompt_begin() {
    req_screen_erase
    [[ -t 1 ]] && printf '\033[?25h'
    [[ -t 0 ]] && stty echo 2>/dev/null
    return 0
}

req_nav_prompt_end() {
    [[ -t 0 ]] && stty -echo 2>/dev/null
    [[ -t 1 ]] && printf '\033[?25l'
    REQ_SCREEN_DRAWN=0
    return 0
}

# req_nav_selected_request - prints the request file the commands act on: the open
# one on the details screen, or the selected request on the list.
req_nav_selected_request() {
    if [[ $REQ_VIEW == detail ]]; then
        printf '%s' "$REQ_DETAIL_FILE"
    elif (( ${#REQ_ITEM_KIND[@]} > 0 )) && [[ ${REQ_ITEM_KIND[REQ_SEL]} == r ]]; then
        printf '%s' "${REQ_ITEM_PATH[REQ_SEL]}"
    else
        return 1
    fi
}

# req_nav_selected_dir - prints the directory under the cursor on the list.
req_nav_selected_dir() {
    [[ $REQ_VIEW == list ]] && (( ${#REQ_ITEM_KIND[@]} > 0 )) && [[ ${REQ_ITEM_KIND[REQ_SEL]} == d ]] || return 1
    printf '%s' "${REQ_ITEM_PATH[REQ_SEL]}"
}

req_cmd_rename_dir() {
    local dir
    if ! dir=$(req_nav_selected_dir); then
        if req_nav_selected_request >/dev/null; then
            REQ_STATUS=":ed renames a directory; edit a request with :e"
        else
            REQ_STATUS="select a directory on the list first"
        fi
        return 0
    fi
    req_nav_prompt_begin
    if req_wizard_rename_dir "$dir" "$1"; then
        req_nav_refresh "$REQ_LAST_DIR"
        REQ_STATUS="renamed to ${REQ_LAST_DIR##*/}"
    fi
    req_nav_prompt_end
}

# req_cmd_copy [name] - :cp on the item under the cursor: a directory is copied with its
# contents, a request is copied as it is; the new name is asked for, no edit menu follows.
req_cmd_copy() {
    local target
    if target=$(req_nav_selected_request); then
        req_nav_prompt_begin
        if req_wizard_copy_request "$target" "$1"; then
            [[ $REQ_VIEW == detail ]] && REQ_VIEW=list
            req_nav_refresh "$REQ_LAST_FILE"
            REQ_STATUS="copied to ${REQ_LAST_FILE##*/}"
        fi
        req_nav_prompt_end
    elif target=$(req_nav_selected_dir); then
        req_nav_prompt_begin
        if req_wizard_copy_dir "$target" "$1"; then
            req_nav_refresh "$REQ_LAST_DIR"
            REQ_STATUS="copied to ${REQ_LAST_DIR##*/}"
        fi
        req_nav_prompt_end
    else
        REQ_STATUS="select a request or a directory first"
    fi
}

req_cmd_remove() {
    local target sel=$REQ_SEL kind=request
    if target=$(req_nav_selected_request); then :
    elif target=$(req_nav_selected_dir); then kind=directory
    else REQ_STATUS="select a request or a directory first"; return 0
    fi
    req_nav_prompt_begin
    if [[ $kind == directory ]]; then
        req_wizard_remove_dir "$target" "$REQ_NAV_ROOT" && REQ_LAST_FILE=$REQ_LAST_DIR || REQ_LAST_FILE=""
    else
        req_wizard_remove_request "$target" || REQ_LAST_FILE=""
    fi
    if [[ -n $REQ_LAST_FILE ]]; then
        REQ_VIEW=list
        req_nav_refresh ""
        # Stay near where the removed row was.
        (( sel >= ${#REQ_ITEM_KIND[@]} )) && sel=$(( ${#REQ_ITEM_KIND[@]} - 1 ))
        (( sel < 0 )) && sel=0
        REQ_SEL=$sel
        REQ_STATUS="removed ${REQ_LAST_FILE##*/}"
    fi
    req_nav_prompt_end
}

req_cmd_new() {
    req_nav_prompt_begin
    printf 'New request in %s\n' "$(req_nav_crumb)"
    if req_wizard_new "${REQ_CUR_DIR:-$REQ_NAV_ROOT}"; then
        REQ_VIEW=list
        req_nav_refresh "$REQ_LAST_FILE"
        REQ_STATUS="created ${REQ_LAST_FILE##*/}"
    fi
    req_nav_prompt_end
}

req_cmd_mkdir() {
    req_nav_prompt_begin
    if req_wizard_mkdir "${REQ_CUR_DIR:-$REQ_NAV_ROOT}" "$1"; then
        REQ_VIEW=list
        req_nav_refresh "$REQ_LAST_DIR"
        REQ_STATUS="created directory ${REQ_LAST_DIR##*/}"
    fi
    req_nav_prompt_end
}

req_cmd_edit() {
    local file
    file=$(req_nav_selected_request) || { REQ_STATUS="select a request first"; return 0; }
    req_nav_prompt_begin
    if req_wizard_edit "$file"; then
        [[ $REQ_VIEW == detail ]] && REQ_DETAIL_FILE=$REQ_LAST_FILE
        req_nav_refresh "$REQ_LAST_FILE"
        REQ_STATUS="saved ${REQ_LAST_FILE##*/}"
    fi
    req_nav_prompt_end
}

req_cmd_dup() {
    local file
    file=$(req_nav_selected_request) || { REQ_STATUS="select a request first"; return 0; }
    req_nav_prompt_begin
    if req_wizard_duplicate "$file"; then
        REQ_VIEW=list
        req_nav_refresh "$REQ_LAST_FILE"
        REQ_STATUS="duplicated as ${REQ_LAST_FILE##*/}"
    elif [[ -f $REQ_LAST_FILE && $REQ_LAST_FILE != "$file" ]]; then
        # The copy was created even though its edit was cancelled.
        REQ_VIEW=list
        req_nav_refresh "$REQ_LAST_FILE"
    fi
    req_nav_prompt_end
}

# req_cmd_config [-g] [key=value] - :config. Without an argument it opens the settings screen
# (every known key, its value and its default). With key=value it checks the key and the
# value against the table (req_config_valid) and writes the open project's file, which is
# where settings belong by default; with -g it writes the global file (~/.req/config)
# instead. The project's file wins over the global one.
req_cmd_config() {
    local arg=$1 key value file scope=project
    if [[ $arg == -g || $arg == "-g "* ]]; then
        scope=global; arg=$(req_trim "${arg#-g}")
    fi
    if [[ -z $arg && $scope == project ]]; then
        req_config_load 2>/dev/null
        REQ_HELP_BACK=$REQ_VIEW; REQ_VIEW=config
        return 0
    fi
    if [[ $arg != *=* ]]; then
        REQ_STATUS="usage: :config [-g] [key=value] (known keys: ${REQ_CONFIG_KEYS[*]})"
        return 0
    fi
    if [[ $scope == project && -z $REQ_PROJECT_ID ]]; then
        REQ_STATUS="no project is open: use :config -g key=value to change the global setting"
        return 0
    fi
    key=$(req_trim "${arg%%=*}"); value=$(req_trim "${arg#*=}")
    if ! req_config_known "$key"; then
        REQ_STATUS="unknown setting \"$key\" (known keys: ${REQ_CONFIG_KEYS[*]})"
        return 0
    fi
    if ! req_config_valid "$key" "$value"; then
        REQ_STATUS="$key must be $(req_config_expect "$key"), not \"$value\""
        return 0
    fi
    if [[ $scope == project ]]; then file=$(req_config_local_file); else file=$(req_config_file); fi
    if req_kv_set "$file" "$key" "$value" 2>/dev/null; then
        req_config_load 2>/dev/null
        REQ_STATUS="$key=$value saved in $file"
    else
        REQ_STATUS="cannot write $file"
    fi
    return 0
}

# req_cmd_switch <yes|no|""> <current: yes|no> - prints the new value: the argument
# (also on|off), or the opposite of the current one. Fails for any other argument.
req_cmd_switch() {
    case $1 in
        yes|on)  printf yes ;;
        no|off)  printf no ;;
        '')      [[ $2 == yes ]] && printf no || printf yes ;;
        *)       return 1 ;;
    esac
}

# shellcheck disable=SC2034  # REQ_LOG_SESSION is read by req_log_enabled
# req_cmd_log [yes|no] - :log. Switches the log of requests and responses for this
# session (the "log" setting is not changed); it needs an open project to keep the log in.
req_cmd_log() {
    local now=no new
    if [[ -z $REQ_PROJECT_ID ]]; then
        REQ_STATUS="no project is open, so there is no log to switch"
        return 0
    fi
    req_log_enabled && now=yes
    if ! new=$(req_cmd_switch "$1" "$now"); then
        REQ_STATUS="usage: :log [yes|no]"
        return 0
    fi
    REQ_LOG_SESSION=$new
    if [[ $new == yes ]]; then REQ_STATUS="log on for this session: $(req_log_file)"
    else REQ_STATUS="log off for this session"; fi
    return 0
}

# shellcheck disable=SC2034  # REQ_VERBOSE is read by the verbose functions in http.sh
# req_cmd_verbose [yes|no] - :v. Switches the verbose mode for this session.
req_cmd_verbose() {
    local now=no new
    req_verbose_on && now=yes
    if ! new=$(req_cmd_switch "$1" "$now"); then
        REQ_STATUS="usage: :v [yes|no]"
        return 0
    fi
    if [[ $new == yes ]]; then REQ_VERBOSE=1; REQ_STATUS="verbose on for this session (>> sent, << received)"
    else REQ_VERBOSE=0; REQ_STATUS="verbose off for this session"; fi
    return 0
}

# shellcheck disable=SC2034  # REQ_ENV is read by req_run_request and the header
# req_cmd_env [name] - :env. Without an argument it lists the project's environments and
# the one in use. With a name it switches the session to that environment (REQ_ENV, shown
# in the header and used by the next request) when the project has a file for it
# ("default" always works); otherwise it says which ones exist and where to create it.
req_cmd_env() {
    local name=$1 current=${REQ_ENV:-default} list
    list=$(req_env_list | tr '\n' ' '); list=${list% }
    if [[ -z $name ]]; then
        if [[ -n $list ]]; then
            REQ_STATUS="environments: ${list// /, } (in use: $current)"
        else
            REQ_STATUS="no environments yet (in use: $current); add a file in $(req_project_state_dir "${REQ_PROJECT_ID:-<project>}" env)"
        fi
        return 0
    fi
    if ! req_valid_name "$name"; then
        REQ_STATUS="invalid environment name \"$name\" (use a slug: lowercase letters, digits and hyphens)"
    elif ! req_env_exists "$name"; then
        REQ_STATUS="unknown environment \"$name\""
        [[ -z $list ]] || REQ_STATUS+=" (known: ${list// /, })"
        if [[ -n $REQ_PROJECT_ID ]]; then
            REQ_STATUS+="; create it with a file at $(req_env_file "$REQ_PROJECT_ID" "$name")"
        else
            REQ_STATUS+="; the project state in $(req_config_dir) is not available"
        fi
    else
        REQ_ENV=$name
        REQ_STATUS="environment: $name"
    fi
    return 0
}

# ==== lib/env.sh
# env.sh - environments and variables.
#
# A project keeps its variables in the central directory (see home.sh):
#   $REQ_CONFIG_DIR/projects/<id>/vars        variables shared by every environment
#   $REQ_CONFIG_DIR/projects/<id>/env/<env>   variables of one environment
# Both are plain "key=value" files. The environment wins over the project variables.
# An invalid file is only reported, never fixed or overwritten. The old format
# ($REQ_CONFIG_DIR/env/<env>/secrets.json, T5.1) is not read and not migrated.

declare -gA REQ_VARS=()      # variables of the last loaded environment (key -> value)

# req_env_file <project id> <env> - path of the file of an environment.
req_env_file() {
    req_project_state_dir "$1" "env/$2"
}

# req_vars_file <project id> - path of the project variables.
req_vars_file() {
    req_project_state_dir "$1" vars
}

# req_env_legacy_file <env> - path of the T5.1 secrets file, which is no longer read.
req_env_legacy_file() {
    printf '%s/env/%s/secrets.json' "$(req_config_dir)" "$1"
}

# shellcheck disable=SC2034  # REQ_VARS is read by the callers
# req_vars_load <env> [project id] - loads the variables of the project (default: the
# one in REQ_PROJECT_ID) and then those of the environment into REQ_VARS, so the
# environment wins. A missing file is not an error. Without a project (its state could
# not be saved) nothing is loaded. If a file is invalid, every problem is reported with
# its absolute path, REQ_VARS stays empty and the status is 1. When the old
# secrets.json of the environment exists, a warning says where the variables live now.
req_vars_load() {
    local env=$1 id=${2-$REQ_PROJECT_ID} file legacy line
    local -A loaded=()
    REQ_VARS=()
    req_valid_name "$env" || {
        req_err "invalid environment name: \"$env\" (use a slug: lowercase letters, digits and hyphens)"
        return 1; }
    legacy=$(req_env_legacy_file "$env")
    [[ -f $legacy ]] && req_warn "$(req_abs_path "$legacy") is no longer read: put its variables as key=value lines in $(req_abs_path "$(req_env_file "${id:-<project>}" "$env")")"
    [[ -n $id ]] || return 0
    req_valid_name "$id" || { req_err "invalid project id: \"$id\""; return 1; }

    local -a files=("$(req_vars_file "$id")" "$(req_env_file "$id" "$env")")
    local status=0
    for file in "${files[@]}"; do req_kv_check "$file" || status=1; done
    (( status )) && return 1

    local -A seen=()
    for file in "${files[@]}"; do
        seen=()
        while IFS= read -r line; do
            req_kv_parse_line "$line" || continue
            [[ -n ${seen[$REQ_KV_KEY]+x} ]] && continue     # the first line of a key wins
            seen[$REQ_KV_KEY]=1
            loaded[$REQ_KV_KEY]=$REQ_KV_VALUE
        done < <(req_kv_list "$file")
    done
    local k
    for k in "${!loaded[@]}"; do REQ_VARS[$k]=${loaded[$k]}; done
    return 0
}

# req_env_var_name <env> <key> - the name of the process variable that overrides a key in
# an environment: both in capitals, hyphens of the environment turned into underscores
# ("dev" and "url" give DEV_URL, "pre-prod" and "token" give PRE_PROD_TOKEN).
req_env_var_name() {
    local env=${1^^} key=${2^^}
    printf '%s_%s' "${env//-/_}" "$key"
}

REQ_RESOLVED=""        # the value found by req_resolve_key_var

# shellcheck disable=SC2034  # REQ_RESOLVED is read by req_resolve_key and req_subst
# req_resolve_key_var <env> <key> - the engine of req_resolve_key, with no subshell: puts
# the value in REQ_RESOLVED and succeeds, or fails (REQ_RESOLVED empty) when nothing
# defines the key. Precedence: the process variable <ENV>_<KEY> (req_env_var_name), then
# the environment file, then the project variables; the last two come from REQ_VARS,
# so req_vars_load <env> must have run for that environment. A set but empty process
# variable counts as a value.
req_resolve_key_var() {
    local env=$1 key=$2 name
    REQ_RESOLVED=""
    req_kv_valid_key "$key" || return 1
    name=$(req_env_var_name "$env" "$key")
    if [[ -n ${!name+x} ]]; then
        REQ_RESOLVED=${!name}
    elif [[ -n ${REQ_VARS[$key]+x} ]]; then
        REQ_RESOLVED=${REQ_VARS[$key]}
    else
        return 1
    fi
}

# req_resolve_key <env> <key> - prints the value of a key (see req_resolve_key_var) and
# succeeds, or fails printing nothing.
req_resolve_key() {
    req_resolve_key_var "$1" "$2" || return 1
    printf '%s\n' "$REQ_RESOLVED"
}

REQ_SUBST_OUT=""        # the text produced by req_subst

# req_subst_fail <env> <project id> <key>... - the error for keys that have no value: one
# line listing them and, for each, the process variable and the files of the project's
# environment that would define it (the files only when there is a project).
req_subst_fail() {
    local env=$1 id=$2 key list="" where=""
    shift 2
    for key in "$@"; do list+=", $key"; done
    req_err "no value for ${list#, } in environment \"$env\""
    if [[ -n $id ]] && req_valid_name "$id"; then
        where="$(req_abs_path "$(req_env_file "$id" "$env")") (or $(req_abs_path "$(req_vars_file "$id")") for every environment)"
    fi
    for key in "$@"; do
        printf '  %s: set the variable %s' "$key" "$(req_env_var_name "$env" "$key")" >&2
        [[ -z $where ]] || printf ', or add %s=... to %s' "$key" "$where" >&2
        printf '\n' >&2
    done
}

# shellcheck disable=SC2034  # REQ_SUBST_OUT is read by the callers
# req_subst <text> <env> [project id] - replaces every ${key} (a valid key name between
# braces) in the text by its value in the environment (req_resolve_key_var) and puts the
# result in REQ_SUBST_OUT, so trailing line breaks survive. A value is never expanded
# again, and anything else that looks like ${...} is left as it is. When some keys have no
# value nothing is replaced: the status is 1, REQ_SUBST_OUT is empty and one error lists
# every missing key (once each, in order of appearance) and says how to define it: the
# process variable and the files of the project's environment.
req_subst() {
    local rest=$1 env=$2 id=${3-$REQ_PROJECT_ID} out="" token key
    local -a missing=()
    local -A seen=()
    REQ_SUBST_OUT=""
    while [[ $rest =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; do
        token=${BASH_REMATCH[0]}; key=${BASH_REMATCH[1]}
        out+=${rest%%"$token"*}
        if req_resolve_key_var "$env" "$key"; then
            out+=$REQ_RESOLVED
        else
            out+=$token
            [[ -n ${seen[$key]+x} ]] || { seen[$key]=1; missing+=("$key"); }
        fi
        rest=${rest#*"$token"}
    done
    if (( ${#missing[@]} > 0 )); then
        req_subst_fail "$env" "$id" "${missing[@]}"
        return 1
    fi
    REQ_SUBST_OUT=$out$rest
}

# The executable fields of a request (the ones sent to curl), where req_subst_json works.
# Names of properties are never substituted, only values.
REQ_SUBST_FIELDS='["url","headers","query","parameters","raw_data","files"]'

# shellcheck disable=SC2034  # REQ_SUBST_OUT is read by the callers
# req_subst_json <request json> <env> [project id] - like req_subst, for a request: every
# ${key} in the string values of url, headers, query, parameters, raw_data and files (also the
# strings inside a raw_data that is native JSON) is replaced, and the result, still valid
# JSON, goes to REQ_SUBST_OUT. Other fields (name, description) are left alone. The keys
# are resolved first: when some are missing, nothing is replaced, the status is 1 and
# req_subst_fail lists them all.
req_subst_json() {
    local json=$1 env=$2 id=${3-$REQ_PROJECT_ID} key map='{}'
    local -a missing=()
    local -A seen=()
    REQ_SUBST_OUT=$json
    while IFS= read -r key; do
        [[ -n $key && -z ${seen[$key]+x} ]] || continue
        seen[$key]=1
        if req_resolve_key_var "$env" "$key"; then
            map=$(jq -c --arg k "$key" --arg v "$REQ_RESOLVED" '. + {($k): $v}' <<<"$map")
        else
            missing+=("$key")
        fi
    done < <(jq -r --argjson f "$REQ_SUBST_FIELDS" '
        [to_entries[] | select(.key | IN($f[])) | .value | .. | strings
         | scan("\\$\\{([A-Za-z_][A-Za-z0-9_]*)\\}") | .[0]] | .[]' <<<"$json")
    if (( ${#missing[@]} > 0 )); then
        REQ_SUBST_OUT=""
        req_subst_fail "$env" "$id" "${missing[@]}"
        return 1
    fi
    (( ${#seen[@]} > 0 )) || return 0
    REQ_SUBST_OUT=$(jq -c --argjson m "$map" --argjson f "$REQ_SUBST_FIELDS" '
        def fill: walk(if type == "string"
                       then gsub("\\$\\{(?<k>[A-Za-z_][A-Za-z0-9_]*)\\}"; $m[.k]) else . end);
        with_entries(if (.key | IN($f[])) then .value |= fill else . end)' <<<"$json")
}

# req_env_list [project id] - prints the names of the project's environments (the files
# in projects/<id>/env/ whose name is a slug), one per line, sorted. Nothing without a
# project or a folder.
req_env_list() {
    local id=${1-$REQ_PROJECT_ID} dir f name
    [[ -n $id ]] || return 0
    dir=$(req_project_state_dir "$id" env)
    [[ -d $dir ]] || return 0
    for f in "$dir"/*; do
        [[ -f $f ]] || continue
        name=${f##*/}
        req_valid_name "$name" && printf '%s\n' "$name"
    done | LC_ALL=C sort
}

# req_env_exists <env> [project id] - succeeds when the environment can be used: it has a
# file in the project, or it is "default", which needs none.
req_env_exists() {
    local env=$1 id=${2-$REQ_PROJECT_ID}
    req_valid_name "$env" || return 1
    [[ $env == default ]] && return 0
    [[ -n $id && -f $(req_env_file "$id" "$env") ]]
}

# ==== lib/home.sh
# home.sh - the user's central directory (~/.req): projects, configuration, cursor.
#
# Layout (one directory per project; see TASKS.md in the req_context repository, "Central project control"):
#   ~/.req/current                 project=<id>: the project in use
#   ~/.req/config                  global configuration
#   ~/.req/projects/<id>/project   name=<folder name> and path=<absolute path of the project>
#   ~/.req/projects/<id>/config    project configuration (wins over the global one)
#   ~/.req/projects/<id>/vars      project variables
#   ~/.req/projects/<id>/env/<e>   variables of environment <e>
#   ~/.req/projects/<id>/cursor    last position in the menu
# The directory is $REQ_CONFIG_DIR when set (tests use it), otherwise ~/.req.
#
# The first part below holds the "key=value" text files everything in there is made of
# (project settings, variables, environments, configuration, cursor). Format:
#   - one "key=value" per line; the key matches [A-Za-z_][A-Za-z0-9_]*;
#   - blank lines and lines starting with "#" are ignored;
#   - spaces around the key and around the value are not significant, the value is
#     everything after the first "=" (so it may contain "=") and has one line;
#   - no quotes or escapes: the value is the text as it is.
# When a key appears twice, the first line wins; req_kv_set keeps only that one.
# Writing keeps comments, blank lines and the order of the other lines, and the file
# is rewritten in place (mode and symlinks are kept). New files and directories are
# private (0600 and 0700), since they may hold credentials.

REQ_KV_KEY=""       # set by req_kv_parse_line
REQ_KV_VALUE=""

# req_kv_valid_key <key> - succeeds for a valid key name.
req_kv_valid_key() {
    [[ $1 =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

# req_kv_parse_line <line> - puts the key and value of a line in REQ_KV_KEY and
# REQ_KV_VALUE. Fails for blank lines, comments and lines that are not "key=value".
req_kv_parse_line() {
    local line=${1%$'\r'} key value
    line=${line#"${line%%[![:space:]]*}"}
    [[ -z $line || $line == \#* || $line != *=* ]] && return 1
    key=${line%%=*}
    value=${line#*=}
    key=${key%"${key##*[![:space:]]}"}
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    req_kv_valid_key "$key" || return 1
    REQ_KV_KEY=$key
    REQ_KV_VALUE=$value
}

# req_kv_get <file> <key> - prints the value of a key. Fails (status 1) when the
# file or the key does not exist.
req_kv_get() {
    local line
    [[ -f $1 ]] || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        if req_kv_parse_line "$line" && [[ $REQ_KV_KEY == "$2" ]]; then
            printf '%s\n' "$REQ_KV_VALUE"
            return 0
        fi
    done <"$1"
    return 1
}

# req_kv_list <file> - prints every "key=value" in file order, normalized. A missing
# file lists nothing.
req_kv_list() {
    local line
    [[ -f $1 ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
        req_kv_parse_line "$line" && printf '%s=%s\n' "$REQ_KV_KEY" "$REQ_KV_VALUE"
    done <"$1"
    return 0
}

# req_kv_check <file> - reports, with the absolute path and the line number, every
# line that is neither blank, a comment nor a valid "key=value". Fails when there is
# any. A missing file is fine.
req_kv_check() {
    local file=$1 line n=0 abs status=0
    [[ -f $file ]] || return 0
    abs=$(req_abs_path "$file")
    while IFS= read -r line || [[ -n $line ]]; do
        n=$(( n + 1 ))
        req_kv_parse_line "$line" && continue
        line=${line%$'\r'}
        line=${line#"${line%%[![:space:]]*}"}
        [[ -z $line || $line == \#* ]] && continue
        req_err "$abs:$n: expected key=value (a key uses letters, digits and underscores)"
        status=1
    done <"$file"
    return "$status"
}

# req_kv_rewrite <file> <set|unset> <key> [value] - the engine of set and unset: the
# first line of the key is replaced (set) and the other lines of that key are dropped;
# unset drops them all. Fails with status 1 when unset finds nothing to remove.
req_kv_rewrite() {
    local file=$1 mode=$2 key=$3 value=${4-} tmp line found=0
    tmp=$(mktemp "${file}.XXXXXX") || { req_err "cannot write to $file"; return 1; }
    while IFS= read -r line || [[ -n $line ]]; do
        if req_kv_parse_line "$line" && [[ $REQ_KV_KEY == "$key" ]]; then
            [[ $mode == set && $found == 0 ]] && printf '%s=%s\n' "$key" "$value"
            found=1
            continue
        fi
        printf '%s\n' "$line"
    done <"$file" >"$tmp"
    if (( ! found )); then
        if [[ $mode == unset ]]; then rm -f "$tmp"; return 1; fi
        printf '%s=%s\n' "$key" "$value" >>"$tmp"
    fi
    cat "$tmp" >"$file" || { rm -f "$tmp"; req_err "cannot write $file"; return 1; }
    rm -f "$tmp"
}

# req_kv_set <file> <key> <value> - sets a key, creating the file (and its directory)
# when needed. The key must be valid and the value must be a single line.
req_kv_set() {
    local file=$1 key=$2 value=$3
    req_kv_valid_key "$key" || {
        req_err "invalid key \"$key\" (use letters, digits and underscores)"; return 1; }
    [[ $value != *$'\n'* && $value != *$'\r'* ]] || {
        req_err "the value of \"$key\" must be a single line"; return 1; }
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    if [[ ! -e $file ]]; then
        (umask 077; mkdir -p "$(dirname "$file")" && : >"$file") 2>/dev/null ||
            { req_err "cannot create $file"; return 1; }
    fi
    req_kv_rewrite "$file" set "$key" "$value"
}

# req_kv_unset <file> <key> - removes a key. Fails when the file or the key does not exist.
req_kv_unset() {
    [[ -f $1 ]] || return 1
    req_kv_rewrite "$1" unset "$2"
}

# --- central directory and projects --------------------------------------------

# req_config_dir - the central directory (default: ~/.req).
req_config_dir() {
    printf '%s' "${REQ_CONFIG_DIR:-$HOME/.req}"
}

# req_projects_dir - the directory holding one directory per project.
req_projects_dir() {
    printf '%s/projects' "$(req_config_dir)"
}

# req_project_state_dir <id> [subpath] - where a project keeps its files in ~/.req.
req_project_state_dir() {
    printf '%s/%s' "$(req_projects_dir)" "$1"
    [[ -z ${2-} ]] || printf '/%s' "$2"
}

# req_project_slug <folder> - a slug made from the folder's name (lowercase letters,
# digits and hyphens); "project" when nothing is left of it.
req_project_slug() {
    local name=${1%/} slug
    name=${name##*/}
    slug=$(LC_ALL=C tr '[:upper:]' '[:lower:]' <<<"$name" | LC_ALL=C tr -cs 'a-z0-9' '-')
    slug=${slug#-}; slug=${slug%-}
    printf '%s' "${slug:-project}"
}

# req_project_find_id <project dir> - prints the id of the project registered for that
# directory (matched by the absolute path in its "project" file). Fails when none.
req_project_find_id() {
    local abs dir id
    abs=$(req_abs_path "$1")
    for dir in "$(req_projects_dir)"/*/; do
        [[ -f ${dir}project ]] || continue
        [[ $(req_kv_get "${dir}project" path) == "$abs" ]] || continue
        id=${dir%/}; printf '%s\n' "${id##*/}"
        return 0
    done
    return 1
}

# req_project_new_id <project dir> - prints a free id for a new project: the folder's
# slug, with -2, -3... added when another project already uses it.
req_project_new_id() {
    local slug id n=1
    slug=$(req_project_slug "$1")
    id=$slug
    while [[ -e $(req_project_state_dir "$id") ]]; do
        n=$(( n + 1 )); id=$slug-$n
    done
    printf '%s\n' "$id"
}

# req_project_create <project dir> - creates the control directory of a project and its
# "project" file (name and path), and prints the new id. Does not check whether the
# directory is already registered (req_project_find_id does).
req_project_create() {
    local abs id file
    [[ -d $1 ]] || { req_err "directory does not exist: $1"; return 1; }
    abs=$(req_abs_path "$1")
    [[ $abs != *$'\n'* ]] || { req_err "the project path must not contain line breaks: $abs"; return 1; }
    id=$(req_project_new_id "$abs")
    file=$(req_project_state_dir "$id" project)
    if ! { req_kv_set "$file" name "${abs##*/}" && req_kv_set "$file" path "$abs"; }; then
        req_err "cannot create the project control in $(req_project_state_dir "$id")"
        return 1
    fi
    printf '%s\n' "$id"
}

# req_current_get - prints the id of the project in use (from ~/.req/current). Fails
# when there is none or the project's directory is gone.
req_current_get() {
    local id
    id=$(req_kv_get "$(req_config_dir)/current" project) || return 1
    req_valid_name "$id" && [[ -d $(req_project_state_dir "$id") ]] || return 1
    printf '%s\n' "$id"
}

# req_current_set <id> - makes a registered project the one in use.
req_current_set() {
    if ! { req_valid_name "$1" && [[ -d $(req_project_state_dir "$1") ]]; }; then
        req_err "unknown project: $1"
        return 1
    fi
    req_kv_set "$(req_config_dir)/current" project "$1"
}

REQ_PROJECT_ID=""       # id of the project opened by req_project_activate

# shellcheck disable=SC2034  # REQ_PROJECT_ID is read by the environment and cursor code
# req_project_activate <project dir> - registers the project in ~/.req when it is not
# there yet and makes it the one in use. Sets REQ_PROJECT_ID. When ~/.req cannot be
# written, one warning is printed, REQ_PROJECT_ID stays empty, nothing else is affected
# (the menu works without saved state) and the status is 1.
req_project_activate() {
    local dir=$1 id problem
    REQ_PROJECT_ID=""
    if ! id=$(req_project_find_id "$dir"); then
        id=$(req_project_create "$dir" 2>&1) || { problem=$id; id=""; }
    fi
    if [[ -n $id ]]; then
        problem=$(req_current_set "$id" 2>&1) || id=""
    fi
    if [[ -z $id ]]; then
        req_warn "the project state in $(req_config_dir) cannot be saved; continuing without it"
        problem=${problem%%$'\n'*}
        printf '  %s\n' "${problem#req: error: }" >&2
        return 1
    fi
    REQ_PROJECT_ID=$id
}

# req_cursor_file <id> - the file where a project keeps the last position of its menu.
req_cursor_file() {
    req_project_state_dir "$1" cursor
}

# req_cursor_save <id> <dir> <item> - writes the position: the directory shown and the
# item selected in it, both relative to the workspace ("" is the workspace itself, or no
# item). Fails when the file cannot be written.
req_cursor_save() {
    local file
    file=$(req_cursor_file "$1")
    req_kv_set "$file" dir "$2" && req_kv_set "$file" item "$3"
}

# --- the .req file: workspace ---------------------------------------------------

# req_project_workspace <.req file> - prints the absolute path of the project's workspace,
# the only directory req looks at. It comes from the "workspace" key of the .req (a
# key=value file): a path relative to the folder of the .req, or "." (the default, also
# used when the key is absent) for that folder. Lines of the .req that are not key=value,
# like the old one-directory-per-line entries, are ignored.
# The path must be relative, exist, be a real directory inside the project folder and
# have no symbolic link in it (links of any kind are refused; a directory cannot be hard
# linked, so a component that is not a plain directory is refused). Every component is
# checked in order, including those a later ".." cancels, so "link/../x" is refused too.
# On a problem it prints the reason with the absolute path of the .req and fails.
req_project_workspace() {
    local pfile=$1 base abs value comp cur
    local -a parts
    [[ -f $pfile ]] || { req_err "project file not found: $pfile"; return 1; }
    abs=$(req_abs_path "$pfile")
    base=$(cd -P "$(dirname "$pfile")" && pwd) || { req_err "$abs: cannot enter the project folder"; return 1; }
    value=$(req_kv_get "$pfile" workspace) || value=.
    if [[ -z $value ]]; then
        req_err "$abs: workspace is empty (use . for the project folder)"; return 1
    fi
    if [[ $value == /* ]]; then
        req_err "$abs: workspace \"$value\" must be a relative path"; return 1
    fi

    cur=$base
    IFS=/ read -r -a parts <<<"$value"
    for comp in "${parts[@]}"; do
        case $comp in
            ''|.) continue ;;
            ..)
                cur=${cur%/*}
                if [[ $cur != "$base" && $cur != "$base"/* ]]; then
                    req_err "$abs: workspace \"$value\" leaves the project folder"; return 1
                fi
                continue ;;
        esac
        cur=$cur/$comp
        if [[ -L $cur ]]; then
            req_err "$abs: workspace \"$value\" goes through a symbolic link ($comp); links are not accepted"; return 1
        fi
        if [[ ! -e $cur ]]; then
            req_err "$abs: workspace \"$value\" does not exist"; return 1
        fi
        if [[ ! -d $cur ]]; then
            req_err "$abs: workspace \"$value\" is not a directory ($comp)"; return 1
        fi
    done
    printf '%s\n' "$cur"
}

# ==== lib/config.sh
# config.sh - the global configuration ($REQ_CONFIG_DIR/config, default ~/.req/config).
#
# A "key=value" file (see home.sh for the format). The project can have its own file,
# $REQ_CONFIG_DIR/projects/<id>/config, with the same keys: its values win over the global
# ones (REQ_CONFIG_LOCAL lists the keys it set). The known keys, with their type,
# default and description, are listed once, in REQ_CONFIG_KEYS below; every other part
# of req (the :config command, the presentation code) goes through that table. Reading
# never blocks the menu: an unknown key, a value of the wrong type or a malformed line
# is reported as a warning with the absolute path and the line number, and ignored.

# Known keys, in the order they are listed. Types: bool (yes or no), int (a whole number,
# 0 or more).
REQ_CONFIG_KEYS=(time_stats time_stat_total restore_cursor log log_request_limit max_redirects)
declare -gA REQ_CONFIG_TYPE=(
    [time_stats]=bool
    [time_stat_total]=bool
    [restore_cursor]=bool
    [log]=bool
    [log_request_limit]=int
    [max_redirects]=int
)
declare -gA REQ_CONFIG_DEFAULT=(
    [time_stats]=yes
    [time_stat_total]=yes
    [restore_cursor]=yes
    [log]=no
    [log_request_limit]=500
    [max_redirects]=10
)
# shellcheck disable=SC2034  # read by :config (TR2.6)
declare -gA REQ_CONFIG_DESC=(
    [time_stats]="show the timing profile after a request runs"
    [time_stat_total]="show the total time line after a request runs"
    [restore_cursor]="reopen the menu where it was left"
    [log]="write the requests and responses to the project's log"
    [log_request_limit]="lines kept in the log, the oldest go first (0: no limit)"
    [max_redirects]="most redirects followed by a request with follow_redirects"
)

declare -gA REQ_CONFIG=()       # values of the loaded files (key -> value)
declare -gA REQ_CONFIG_LOCAL=() # keys whose value comes from the project's file

# req_config_file - path of the global configuration file.
req_config_file() {
    printf '%s/config' "$(req_config_dir)"
}

# req_config_local_file - path of the configuration file of the open project
# (REQ_PROJECT_ID).
req_config_local_file() {
    req_project_state_dir "$REQ_PROJECT_ID" config
}

# req_config_known <key> - succeeds when the key is in the table.
req_config_known() {
    [[ -n ${REQ_CONFIG_TYPE[$1]+x} ]]
}

# req_config_valid <key> <value> - succeeds when the key is known and the value fits
# its type.
req_config_valid() {
    req_config_known "$1" || return 1
    case ${REQ_CONFIG_TYPE[$1]} in
        bool) [[ $2 == yes || $2 == no ]] ;;
        int)  [[ $2 =~ ^[0-9]{1,9}$ ]] ;;
        *)    return 1 ;;
    esac
}

# req_config_expect <key> - prints what the key accepts, for error messages.
req_config_expect() {
    case ${REQ_CONFIG_TYPE[$1]-} in
        bool) printf 'yes or no' ;;
        int)  printf 'a whole number (0 or more)' ;;
    esac
}

# req_config_load - fills REQ_CONFIG from the global file and then, when a project is
# open (REQ_PROJECT_ID), from its own file, which wins.
req_config_load() {
    local status=0
    req_config_load_file "$(req_config_file)" || status=1
    req_config_load_local || status=1
    return "$status"
}

# req_config_load_local - layers the open project's file over what is loaded. Does nothing
# without a project; a missing file is fine.
req_config_load_local() {
    REQ_CONFIG_LOCAL=()
    [[ -n $REQ_PROJECT_ID ]] || return 0
    req_config_load_file "$(req_config_local_file)" overlay
}

# req_config_load_file <file> [overlay] - fills REQ_CONFIG with the file's values (first
# emptying it, unless "overlay" is given: then the values replace the loaded ones and the
# keys are listed in REQ_CONFIG_LOCAL). A missing file is fine. Problems are warnings; the
# status is 1 when there was any. The first line of a repeated key wins.
req_config_load_file() {
    local file=$1 line n=0 abs status=0
    local -A seen=()
    if [[ ${2-} != overlay ]]; then REQ_CONFIG=(); REQ_CONFIG_LOCAL=(); fi
    [[ -f $file ]] || return 0
    abs=$(req_abs_path "$file")
    while IFS= read -r line || [[ -n $line ]]; do
        n=$(( n + 1 ))
        if ! req_kv_parse_line "$line"; then
            line=${line%$'\r'}; line=${line#"${line%%[![:space:]]*}"}
            [[ -z $line || $line == \#* ]] && continue
            req_warn "$abs:$n: expected key=value; line ignored"
            status=1; continue
        fi
        if ! req_config_known "$REQ_KV_KEY"; then
            req_warn "$abs:$n: unknown setting \"$REQ_KV_KEY\" (known: ${REQ_CONFIG_KEYS[*]}); ignored"
            status=1; continue
        fi
        [[ -n ${seen[$REQ_KV_KEY]+x} ]] && continue
        if ! req_config_valid "$REQ_KV_KEY" "$REQ_KV_VALUE"; then
            req_warn "$abs:$n: $REQ_KV_KEY must be $(req_config_expect "$REQ_KV_KEY"), not \"$REQ_KV_VALUE\"; ignored"
            status=1; continue
        fi
        seen[$REQ_KV_KEY]=1
        REQ_CONFIG[$REQ_KV_KEY]=$REQ_KV_VALUE
        # shellcheck disable=SC2034  # read by the settings screen (nav.sh)
        [[ ${2-} == overlay ]] && REQ_CONFIG_LOCAL[$REQ_KV_KEY]=1
    done <"$file"
    return "$status"
}

# req_config_get <key> - prints the loaded value of a key, or its default when the file
# does not set it. Fails for an unknown key.
req_config_get() {
    req_config_known "$1" || return 1
    printf '%s\n' "${REQ_CONFIG[$1]-${REQ_CONFIG_DEFAULT[$1]}}"
}

# ==== lib/log.sh
# log.sh - the project's log of what req sends: $REQ_CONFIG_DIR/projects/<id>/req.log.
#
# One line per event, in plain text: a timestamp, the kind of event and its data, with
# line breaks inside values written as \n so a line never wraps. It is written only when
# the "log" setting is yes (see config.sh) and a project is open. Values are logged as
# they are sent, with the real value of every ${key} (nothing is masked, see TASKS.md in the req_context repository).
# A log that cannot be written is one warning per run, never a reason to stop a request.

# req_log_file - path of the open project's log.
req_log_file() {
    req_project_state_dir "$REQ_PROJECT_ID" req.log
}

REQ_LOG_SESSION=""      # yes or no after :log (it wins over the setting until req quits)

# req_log_enabled - succeeds when the log is on (the session's choice, else the "log"
# setting) and there is a project to keep it in.
req_log_enabled() {
    [[ -n $REQ_PROJECT_ID && ${REQ_LOG_SESSION:-$(req_config_get log)} == yes ]]
}

# req_log_escape <text> - prints the text on one line (line breaks become \n).
req_log_escape() {
    local text=${1//$'\r'/}
    printf '%s' "${text//$'\n'/\\n}"
}

# req_log_trim <file> - keeps only the last log_request_limit lines of the log (the
# oldest go first). 0 means no limit. A log that cannot be rewritten stays as it is.
req_log_trim() {
    local limit lines tmp
    limit=$(req_config_get log_request_limit)
    (( limit > 0 )) || return 0
    lines=$(wc -l <"$1") || return 1
    (( lines > limit )) || return 0
    tmp=$(mktemp "$1.XXXXXX") || return 1
    if tail -n "$limit" "$1" >"$tmp" 2>/dev/null && mv "$tmp" "$1" 2>/dev/null; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# req_log_write <event> <text> - appends "<timestamp> <EVENT> <text>" to the log, then
# trims it to log_request_limit lines. Does nothing when the log is off.
req_log_write() {
    req_log_enabled || return 0
    local file
    file=$(req_log_file)
    if ! printf '%s %s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" "$(req_log_escape "$2")" >>"$file" 2>/dev/null; then
        req_warn "cannot write the log $file; continuing without it"
        return 1
    fi
    req_log_trim "$file" || req_warn "cannot trim the log $file to log_request_limit lines"
    return 0
}

# req_log_request <request file> <environment> - logs the request just prepared by
# req_build_curl_args (REQ_P_*, REQ_BODY): file name, environment, method, url, then the
# headers, the form fields (when there is no raw_data) and the body, separated by " | ".
req_log_request() {
    local text item
    req_log_enabled || return 0
    text="file=${1##*/} env=$2 $REQ_P_METHOD $REQ_P_URL"
    for item in "${REQ_P_HEADERS[@]}"; do text+=" | header: $item"; done
    for item in "${REQ_P_FORM[@]}"; do text+=" | form: $item"; done
    for item in "${REQ_P_FILES[@]}"; do text+=" | file: $item"; done
    (( REQ_P_RAWSET )) && text+=" | body: $REQ_BODY"
    req_log_write REQUEST "$text"
}

# req_log_response - logs the response just received by req_curl_exec (REQ_RESP_*): the
# status code, the Content-Type, the total time in seconds and the whole body.
req_log_response() {
    req_log_enabled || return 0
    req_log_write RESPONSE "status=$REQ_RESP_STATUS type=${REQ_RESP_CTYPE:--} total=${REQ_RESP_TIMES[5]}s | body: $REQ_RESP_BODY"
}

# req_log_failure <curl exit code> - logs a request that got no HTTP response.
req_log_failure() {
    req_log_write ERROR "no response (curl exit code $1)"
}

# ==== bin/req
# req - The interactive request tool for your terminal.


req_usage() {
    cat <<'USAGE'
usage: req                  open the interactive menu (uses the .req in the current directory)
       req init             initialize a req project in the current directory
       req run <file>       run a request and show the result
       req --version | --help
USAGE
}

main() {

    case ${1-} in
        -v|--version) printf 'req %s\n' "$REQ_VERSION"; return 0 ;;
        -h|--help)    req_usage; return 0 ;;
    esac

    req_check_bash
    req_check_deps
    req_setup_traps
    req_config_load || true     # warnings only: a bad setting never stops req

    case ${1-} in
        init)
            req_project_init . || return 1
            req_project_activate . || true     # only a warning: the project itself exists
            printf 'Initialized req project in %s\n  %s (workspace: .)\n' "$PWD" "$REQ_PROJECT_FILE"
            printf 'Use :n to create a new request.\n'
            ;;
        run)
            [[ -n ${2-} ]] || req_die "usage: req run <file.<method>.json>"
            # The project of the current folder, if it is registered, gives the environment files.
            if req_project_find . >/dev/null; then REQ_PROJECT_ID=$(req_project_find_id .) || REQ_PROJECT_ID=""; fi
            req_config_load_local || true
            req_run_request "$2"
            ;;
        '')
            req_nav_start
            ;;
        *)
            req_usage >&2
            return 1
            ;;
    esac
}

main "$@"
