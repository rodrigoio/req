#!/usr/bin/env bash
# Built from the sources by build.sh: do not edit, change the sources and run make build.

# ==== version.sh

REQ_VERSION="0.6.0"

# ==== lib/core.sh

REQ_REQUIRED_BASH_MAJOR=4
REQ_REQUIRED_CMDS=(curl jq)

req_err() {
    printf 'req: error: %s\n' "$*" >&2
}

req_warn() {
    if [[ ${REQ_NOTIFICATION_ACTIVE-0} == 1 ]]; then
        req_notification_warn "$*"
    else
        printf 'req: warning: %s\n' "$*" >&2
    fi
}

req_trim() {
    local s=$1
    s=${s#"${s%%[![:space:]]*}"}
    s=${s%"${s##*[![:space:]]}"}
    printf '%s' "$s"
}

req_abs_path() {
    local p=$1 dir
    if [[ -d $p ]]; then
        (cd -P "$p" && pwd)
        return
    fi
    dir=$(cd -P "$(dirname "$p")" 2>/dev/null && pwd) || { printf '%s' "$p"; return; }
    printf '%s/%s' "$dir" "${p##*/}"
}

req_die() {
    req_err "$@"
    exit 1
}

req_check_bash() {
    if (( BASH_VERSINFO[0] < REQ_REQUIRED_BASH_MAJOR )); then
        req_die "bash ${REQ_REQUIRED_BASH_MAJOR}+ is required (found: ${BASH_VERSION})."
    fi
}

req_missing_deps() {
    local cmd
    for cmd in "${REQ_REQUIRED_CMDS[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || printf '%s\n' "$cmd"
    done
}

req_check_deps() {
    local missing
    missing=$(req_missing_deps)
    [[ -z $missing ]] && return 0
    req_die "missing dependencies: $(req_color orange)${missing//$'\n'/ }$(req_color reset)"
}

req_editor() {
    local e
    local -a candidates=("$@")
    (( $# )) || candidates=(vim vi)
    if [[ -n ${VISUAL-} ]]; then printf '%s' "$VISUAL"; return 0; fi
    if [[ -n ${EDITOR-} ]]; then printf '%s' "$EDITOR"; return 0; fi
    for e in "${candidates[@]}"; do
        if command -v "$e" >/dev/null 2>&1; then printf '%s' "$e"; return 0; fi
    done
    return 1
}

req_edit_file() {
    local file=$1 editor
    shift
    editor=$(req_editor "$@") || return 2
    sh -c "$editor \"\$@\"" req-editor "$file" || return 1
}

REQ_EDIT_TEXT=""    # result of req_edit_text

req_edit_text() {
    local editor dir file status
    editor=$(req_editor) || return 2
    dir=$(mktemp -d "${TMPDIR:-/tmp}/req-edit.XXXXXX") || return 1
    file=$dir/raw_data${2-}
    printf '%s\n' "$1" >"$file"
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

req_restore_terminal() {
    [[ -t 1 ]] || return 0
    printf '\033[0m\033[?25h'
    [[ -t 0 ]] && stty sane 2>/dev/null
    return 0
}

REQ_EXIT_HOOK=""        # function to run first when the process exits (the menu saves its cursor)

req_on_exit() {
    [[ -z $REQ_EXIT_HOOK ]] || "$REQ_EXIT_HOOK"
    req_restore_terminal
}

req_trap_int_exit() {
    trap 'exit 130' INT
}

req_setup_traps() {
    trap req_on_exit EXIT
    req_trap_int_exit
    trap 'exit 143' TERM
}

# ==== lib/ui.sh

if [[ -t 1 && -z ${NO_COLOR-} ]]; then REQ_COLORS=1; else REQ_COLORS=0; fi

req_colors_enabled() {
    [[ $REQ_COLORS == 1 ]]
}

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
        notification) printf '\033[38;5;16;48;5;208m' ;;
        bold)   printf '\033[1m' ;;
        dim)    printf '\033[2m' ;;
        reset)  printf '\033[0m' ;;
    esac
}

req_method_color() {
    case ${1,,} in
        get|post|put|patch|delete) req_color "$1" ;;
    esac
}

req_paint_method() {
    req_method_color "$1"
    printf '%s' "${1^^}"
    req_color reset
}

req_paint_status() {
    case $1 in
        2*) req_color ok ;;
        3*) req_color warn ;;
        4*|5*) req_color err ;;
    esac
    printf '%s' "$1"
    req_color reset
}

req_utf8() {
    case ${LC_ALL:-${LC_CTYPE:-${LANG-}}} in
        *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) return 0 ;;
    esac
    return 1
}

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

req_rule() {
    local ch=${1:-=} line
    printf -v line '%*s' "$(req_term_cols)" ''
    printf '%s\n' "${line// /$ch}"
}

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

REQ_REPLY=""
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

REQ_METHODS=(GET POST PUT PATCH DELETE)
REQ_PROJECT_FILE=.req

REQ_JQ_LEAVES='
def leaves($p):
    if type == "object" then (to_entries[] | .key as $k | .value | leaves(if $p == "" then $k else "\($p)[\($k)]" end))
    elif type == "array" then (.[] | leaves("\($p)[]"))
    else [$p, tostring] end;
'

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

req_valid_method() {
    local m
    for m in "${REQ_METHODS[@]}"; do
        [[ ${1^^} == "$m" ]] && return 0
    done
    return 1
}

req_valid_name() {
    [[ $1 =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]
}

req_request_filename() {
    printf '%s.%s.json' "$1" "${2,,}"
}

req_parse_filename() {
    local base=${1##*/} stem method
    [[ $base == *.*.json ]] || return 1
    stem=${base%.json}
    method=${stem##*.}
    req_valid_method "$method" || return 1
    req_valid_name "${stem%.*}" || return 1
    printf '%s\t%s\n' "${stem%.*}" "${method^^}"
}

REQ_CHECK_JQ='
(if type == "object" then
    (.name   | if type == "string" then gsub("[\r\n]"; " ") else "" end),
    (.method | if type == "string" then gsub("[\r\n]"; " ") else "" end)
 else "", "" end),
('"$REQ_SCHEMA_JQ"')'

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

req_request_template() {
    jq -n --arg name "$1" --arg method "${2^^}" --arg url "$3" '{
        name: $name, method: $method, url: $url, description: "",
        headers: {}, query: {}, parameters: {}
    }'
}

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

req_request_get() {
    case $2 in
        headers|query|parameters) jq -c --arg f "$2" '.[$f] // {}' "$1" ;;
        *) jq -r --arg f "$2" '.[$f] // ""' "$1" ;;
    esac
}

req_project_find() {
    local file=${1:-.}/$REQ_PROJECT_FILE
    [[ -f $file ]] || return 1
    printf '%s\n' "$file"
}

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

REQ_CURL_FORMAT=$'\n%{http_code}|%{time_namelookup}|%{time_connect}|%{time_appconnect}|%{time_pretransfer}|%{time_starttransfer}|%{time_total}|%{content_type}'

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

REQ_URL_PROBLEM=""      # why req_url_check refused an address

req_url_check() {
    local url=$1 scheme rest host
    REQ_URL_PROBLEM=""
    if [[ $url == *[[:space:]]* ]]; then REQ_URL_PROBLEM="it contains whitespace"; return 1; fi
    if [[ $url == *[[:cntrl:]]* ]]; then REQ_URL_PROBLEM="it contains control characters"; return 1; fi
    [[ $url == *"://"* ]] || return 0
    scheme=${url%%://*}; rest=${url#*://}
    if [[ $scheme != *'${'* ]]; then
        case ${scheme,,} in
            http|https) ;;
            *) REQ_URL_PROBLEM="the scheme \"$scheme\" is not http or https"; return 1 ;;
        esac
    fi
    host=${rest%%[/?#]*}                    # the authority, up to the path, query or fragment
    host=${host##*@}                        # without the user and password
    if [[ $host =~ ^(.*):[0-9]*$ ]]; then host=${BASH_REMATCH[1]}; fi     # without the port
    if [[ -z $host ]]; then REQ_URL_PROBLEM="there is no host after \"://\""; return 1; fi
    return 0
}

req_build_url() {
    req_prepare_request "$1" || return 1
    printf '%s' "$REQ_P_URL"
}

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
        [[ $REQ_P_FOLLOW == true && $REQ_RESP_STATUSLINE =~ ^HTTP/[0-9.]+\ 3[0-9][0-9] ]] || break
    done
    REQ_RESP_BODY=$rest
}

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

req_execute() {
    req_build_curl_args "$1" || return 1
    req_curl_exec
}

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

req_bar_char() {
    if req_utf8; then printf '█'; else printf '#'; fi
}

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

REQ_BODY_TEXT=""        # what req_body_format made of the last body
REQ_RESULT=""           # ok after a response, failed when the last request sent got none, empty before any

req_body_format() {
    local flags=()
    REQ_BODY_TEXT=$2
    [[ -n $2 && ${1,,} == *json* ]] || return 1
    [[ $3 == 1 ]] && flags=(-C)
    REQ_BODY_TEXT=$(jq "${flags[@]}" . <<<"$2" 2>/dev/null) && return 0
    REQ_BODY_TEXT=$2
    return 1
}

req_print_body() {
    local color=0
    if [[ -z $2 ]]; then
        req_color dim; printf '(no body)\n'; req_color reset
        return 0
    fi
    req_colors_enabled && color=1
    req_body_format "$1" "$2" "$color"
    printf '%s\n' "$REQ_BODY_TEXT"
}

req_result_check() {
    local cmd=less
    case ${REQ_RESULT-} in
        ok) ;;
        failed) req_warn "no response to view: the last request got none"; return 1 ;;
        *) req_warn "no response to view yet: run a request first"; return 1 ;;
    esac
    if [[ -n ${PAGER-} ]]; then
        cmd=${PAGER%%[[:space:]]*}
        command -v "$cmd" >/dev/null 2>&1 || { req_warn "the pager PAGER=$PAGER was not found: set PAGER to one that exists"; return 1; }
    else
        command -v less >/dev/null 2>&1 || { req_warn "no pager found: install less or set PAGER"; return 1; }
    fi
}

req_result_view() {
    local color=0 json=1 flags=() status
    [[ -z ${PAGER-} ]] && req_colors_enabled && color=1
    REQ_BODY_TEXT="(no body)"
    if [[ -n $REQ_RESP_BODY ]]; then
        req_body_format "$REQ_RESP_CTYPE" "$REQ_RESP_BODY" "$color" && json=0
    fi
    trap ':' INT
    if [[ -n ${PAGER-} ]]; then
        printf '%s\n' "$REQ_BODY_TEXT" | sh -c "$PAGER"
    else
        (( json == 0 && color )) && flags=(-R)
        printf '%s\n' "$REQ_BODY_TEXT" | LESS='' less "${flags[@]}"
    fi
    status=$?
    req_trap_int_exit
    (( status == 0 || status == 130 )) && return 0      # 130: the pager was stopped with Ctrl-C
    req_warn "the pager failed (exit code $status)"
    return 1
}

req_verbose_on() {
    [[ $REQ_VERBOSE == 1 ]]
}

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

req_verbose_response() {
    local line
    req_verbose_on || return 0
    for line in "$REQ_RESP_STATUSLINE" "${REQ_RESP_HEADERS[@]}"; do
        [[ -n $line ]] || continue
        req_color dim; printf '<<'; req_color reset; printf ' %s\n' "$line"
    done
    printf '\n'
}

req_run_request() {
    local file=$1 json status env=${REQ_ENV:-default}
    req_request_check "$file" || return 1
    json=$(<"$file")
    req_vars_load "$env" || return 1
    req_subst_json "$json" "$env" || return 1
    REQ_REQUEST_DIR=$(dirname "$(req_abs_path "$file")")
    req_build_curl_args "$REQ_SUBST_OUT" || return 1
    if [[ ${REQ_NOTIFICATION_ACTIVE-0} == 1 ]] && ! req_url_check "$REQ_P_URL"; then
        req_notification_warn "invalid address: $REQ_URL_PROBLEM ($REQ_P_URL); sending it anyway"
    fi
    req_log_request "$file" "$env"

    req_method_color "$REQ_P_METHOD"; printf '%s' "$REQ_P_METHOD"; req_color reset
    printf ' %s\n' "$REQ_P_URL"
    req_verbose_request

    req_curl_exec; status=$?
    REQ_RESULT=ok; (( status == 0 )) || REQ_RESULT=failed
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

REQ_RAW_MAX_LINES=15    # lines of raw_data shown on the details screen
REQ_PROBLEMS_MAX_LINES=10   # problems listed on the details of an invalid request
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
REQ_VIEW=list           # list | detail | help | config | env
REQ_DETAIL_FILE=""
REQ_DETAIL_VALID=0
REQ_ENV_SEL=0           # selected row of the environment menu, an index of REQ_ENV_CHOICES
REQ_ENV_TOP=0           # first row of the environment menu that is shown
REQ_ENV_BACK=list       # the view the environment menu returns to (list or detail)
REQ_ENV_NEW_LABEL="+ new environment"     # the last row of the environment menu

REQ_ITEM_KIND=()        # d | r, per item of the current list
REQ_ITEM_LABEL=()
REQ_ITEM_METHOD=()
REQ_ITEM_PATH=()
REQ_SEL=0
REQ_TOP=0

REQ_NAV_DIRTY=1         # 1 when the screen must be rebuilt (0 while only the prompt changes)
REQ_BASE_LINES=()       # last built screen, reused while nothing but the prompt changes

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

req_screen_erase() {
    if [[ -t 1 && $REQ_SCREEN_DRAWN -gt 0 ]]; then
        printf '\033[%dA\r\033[J' "$REQ_SCREEN_DRAWN"
    fi
    REQ_SCREEN_DRAWN=0
}

req_nav_clear_screen() {
    [[ -t 1 ]] && printf '\033[H\033[2J'
    REQ_SCREEN_DRAWN=0
    return 0
}

req_screen_draw() {
    req_screen_erase
    printf '%s\n' "${REQ_SCREEN_LINES[@]}"
    [[ -t 1 ]] && REQ_SCREEN_DRAWN=$(( ${#REQ_SCREEN_LINES[@]} + REQ_SCREEN_EXTRA ))
    return 0
}

req_screen_add_long() {
    local cols
    cols=$(req_term_cols)
    REQ_SCREEN_LINES+=("$1")
    (( ${#1} > cols )) && REQ_SCREEN_EXTRA=$(( REQ_SCREEN_EXTRA + (${#1} - 1) / cols ))
    return 0
}

req_marker() {
    if req_utf8; then printf '▸'; else printf '>'; fi
}

req_nav_rel() {
    printf '%s' "${1#"$REQ_NAV_ROOT"/}"
}

req_nav_root() {
    REQ_NAV_ROOT=$(req_project_workspace "$1") || { REQ_NAV_ROOT=""; return 1; }
}

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

req_nav_init() {
    local pfile=$1
    [[ -f $pfile ]] || { req_err "project file not found: $pfile"; return 1; }
    req_nav_root "$pfile" || return 1
    REQ_NAV_PROJECT=$(req_abs_path "$(dirname "$pfile")"); REQ_NAV_PROJECT=${REQ_NAV_PROJECT##*/}
    REQ_CUR_DIR=""; REQ_STACK_DIR=(); REQ_STACK_SEL=()
    REQ_VIEW=list; REQ_DETAIL_FILE=""; REQ_DETAIL_VALID=0
    REQ_CMD_ACTIVE=0; REQ_CMD_BUF=""; REQ_QUIT=0; REQ_NAV_DIRTY=1
    REQ_STATUS=""
    req_notification_register root req_notification_root_check     # a persistent notice, only for root
    req_nav_load
}

req_nav_save_cursor() {
    local dir="" item=""
    [[ -n $REQ_PROJECT_ID && -n $REQ_NAV_ROOT ]] || return 0
    [[ -z $REQ_CUR_DIR ]] || dir=$(req_nav_rel "$REQ_CUR_DIR")
    (( ${#REQ_ITEM_PATH[@]} > REQ_SEL )) && item=$(req_nav_rel "${REQ_ITEM_PATH[REQ_SEL]}")
    req_cursor_save "$REQ_PROJECT_ID" "$dir" "$item" 2>/dev/null || true
    return 0
}

req_nav_cursor_path_ok() {
    local parts comp
    [[ -z $1 ]] && return 0
    [[ $1 != /* && $1 != */ ]] || return 1
    IFS=/ read -ra parts <<<"$1"
    for comp in "${parts[@]}"; do
        [[ -n $comp && $comp != . && $comp != .. ]] || return 1
    done
}

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

req_nav_refresh() {
    local want=$1 i
    req_nav_load
    for i in "${!REQ_ITEM_PATH[@]}"; do
        [[ ${REQ_ITEM_PATH[i]} == "$want" ]] && REQ_SEL=$i
    done
}

req_nav_crumb() {
    if [[ -z $REQ_CUR_DIR ]]; then printf '/'; else printf '/%s' "$(req_nav_rel "$REQ_CUR_DIR")"; fi
}

req_nav_build_list() {
    local n=${#REQ_ITEM_KIND[@]} cols rows visible i end width pos
    local c_dim c_bold c_reset c_sel tag label tail="" room
    cols=$(req_term_cols); rows=$(req_term_rows)
    c_dim=$(req_color dim); c_bold=$(req_color bold); c_reset=$(req_color reset)
    c_sel=$(req_color sel)
    REQ_SCREEN_LINES=(); REQ_SCREEN_EXTRA=0

    pos=""
    (( n > 0 )) && pos=" ($((REQ_SEL + 1))/$n)"
    room=$(( cols - 5 - ${#pos} ))
    if [[ -n $REQ_NAV_PROJECT ]]; then
        tail="  $REQ_NAV_PROJECT @ ${REQ_ENV:-default}"
        if (( room - ${#tail} >= 12 )); then room=$(( room - ${#tail} )); else tail=""; fi
    fi
    REQ_SCREEN_LINES+=("${c_bold}req${c_reset} $(req_trunc "$(req_nav_crumb)" "$room")${c_dim}${pos}${tail}${c_reset}")

    if (( n == 0 )); then
        REQ_SCREEN_LINES+=("  ${c_dim}(empty)${c_reset}")
    else
        visible=$(( rows - 3 - ${#REQ_NOTIFICATION_LINES[@]} )); (( visible < 3 )) && visible=3
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
                REQ_SCREEN_LINES+=("${c_sel}$(req_marker) ${tag} ${label}${c_reset}")
            elif [[ ${REQ_ITEM_KIND[i]} == d ]]; then
                REQ_SCREEN_LINES+=("  ${c_dim}${tag}${c_reset} ${c_bold}${label}${c_reset}")
            else
                REQ_SCREEN_LINES+=("  $(req_method_color "${REQ_ITEM_METHOD[i]}")${tag}${c_reset} ${label}")
            fi
        done
    fi
}

req_nav_build_detail() {
    local f=$REQ_DETAIL_FILE abs cols width c_dim c_bold c_reset problems line i
    local -a plist=()
    cols=$(req_term_cols); width=$(( cols - 4 ))
    c_dim=$(req_color dim); c_bold=$(req_color bold); c_reset=$(req_color reset)
    REQ_SCREEN_LINES=(); REQ_SCREEN_EXTRA=0

    if ! problems=$(req_request_check "$f" 2>&1); then
        REQ_DETAIL_VALID=0
        abs=$(req_abs_path "$f")
        while IFS= read -r line; do
            line=${line#"req: error: $abs: "}
            line=${line#"req: error: "}
            plist+=("$line")
        done <<<"$problems"
        REQ_SCREEN_LINES+=("$(req_notification_bar "$(req_notification_more "invalid request: ${plist[0]}" $(( ${#plist[@]} - 1 )))")")
        REQ_SCREEN_LINES+=("$(req_color err)Invalid request:${c_reset}")
        req_screen_add_long "$abs"      # whole and on its own line, ready to copy
        for (( i = 0; i < ${#plist[@]} && i < REQ_PROBLEMS_MAX_LINES; i++ )); do
            REQ_SCREEN_LINES+=("  $(req_trunc "${plist[i]}" "$width")")
        done
        (( ${#plist[@]} > REQ_PROBLEMS_MAX_LINES )) &&
            REQ_SCREEN_LINES+=("  ... ($(( ${#plist[@]} - REQ_PROBLEMS_MAX_LINES )) more)")
        REQ_SCREEN_LINES+=("${c_dim}Fix the file and open it again.${c_reset}")
        return 0
    fi

    REQ_DETAIL_VALID=1
    req_request_fields "$f"
    if ! req_url_check "$REQ_F_URL"; then
        REQ_SCREEN_LINES+=("$(req_notification_bar "invalid address in the url: $REQ_URL_PROBLEM")")
    fi
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
}

req_nav_build_help() {
    local cols row keys sec=0 c_dim c_bold c_reset
    local -a keyw=(0)
    cols=$(req_term_cols)
    c_dim=$(req_color dim); c_bold=$(req_color bold); c_reset=$(req_color reset)
    REQ_SCREEN_LINES=(); REQ_SCREEN_EXTRA=0
    for row in "${REQ_HELP_ROWS[@]}"; do
        if [[ $row == *'|'* ]]; then
            keys=${row%%|*}; (( ${#keys} > keyw[sec] )) && keyw[sec]=${#keys}
        else
            (( sec++ )); keyw[sec]=0
        fi
    done
    sec=0
    REQ_SCREEN_LINES+=("${c_bold}req${c_reset} help")
    for row in "${REQ_HELP_ROWS[@]}"; do
        if [[ $row == *'|'* ]]; then
            keys=$(printf '%-*s' "${keyw[sec]}" "${row%%|*}")
            REQ_SCREEN_LINES+=("  $(req_trunc "$keys  ${row#*|}" $((cols - 3)))")
        else
            (( sec++ ))
            REQ_SCREEN_LINES+=("${c_dim}${row}${c_reset}")
        fi
    done
}

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
    REQ_SCREEN_LINES+=("${c_dim}Change one with :config key=value (:config -g key=value for the global file)${c_reset}")
}

req_nav_build_env() {
    local total=$(( ${#REQ_ENV_CHOICES[@]} + 1 )) cols rows visible i end width label inuse current=${REQ_ENV:-default}
    local c_dim c_bold c_reset c_sel
    cols=$(req_term_cols); rows=$(req_term_rows)
    c_dim=$(req_color dim); c_bold=$(req_color bold); c_reset=$(req_color reset)
    c_sel=$(req_color sel)
    REQ_SCREEN_LINES=(); REQ_SCREEN_EXTRA=0
    REQ_SCREEN_LINES+=("${c_bold}req${c_reset} environments${c_dim}$(req_trunc "  $REQ_NAV_PROJECT  (in use: $current)" $(( cols - 16 )))${c_reset}")

    visible=$(( rows - 3 - ${#REQ_NOTIFICATION_LINES[@]} )); (( visible < 3 )) && visible=3
    (( total < visible )) && visible=$total
    (( REQ_ENV_SEL < REQ_ENV_TOP )) && REQ_ENV_TOP=$REQ_ENV_SEL
    (( REQ_ENV_SEL >= REQ_ENV_TOP + visible )) && REQ_ENV_TOP=$(( REQ_ENV_SEL - visible + 1 ))
    end=$(( REQ_ENV_TOP + visible ))
    width=$(( cols - 16 ))
    for (( i = REQ_ENV_TOP; i < end; i++ )); do
        inuse=""
        if (( i < total - 1 )); then
            label=$(req_trunc "${REQ_ENV_CHOICES[i]}" "$width")
            [[ ${REQ_ENV_CHOICES[i]} == "$current" ]] && inuse=" (in use)"
        else
            label=$REQ_ENV_NEW_LABEL
        fi
        if (( i == REQ_ENV_SEL )); then
            REQ_SCREEN_LINES+=("${c_sel}$(req_marker) ${label}${inuse}${c_reset}")
        elif (( i == total - 1 )); then
            REQ_SCREEN_LINES+=("  ${c_dim}${label}${c_reset}")
        else
            REQ_SCREEN_LINES+=("  ${label}${c_dim}${inuse}${c_reset}")
        fi
    done
}

req_nav_env_key() {
    local total=$(( ${#REQ_ENV_CHOICES[@]} + 1 ))
    case $1 in
        up)    REQ_ENV_SEL=$(( (REQ_ENV_SEL + total - 1) % total )) ;;
        down)  REQ_ENV_SEL=$(( (REQ_ENV_SEL + 1) % total )) ;;
        esc|q) REQ_VIEW=$REQ_ENV_BACK ;;
        enter) req_nav_env_enter ;;
    esac
    return 0
}

req_nav_env_enter() {
    if (( REQ_ENV_SEL < ${#REQ_ENV_CHOICES[@]} )); then
        REQ_VIEW=$REQ_ENV_BACK
        req_env_use "${REQ_ENV_CHOICES[REQ_ENV_SEL]}" now
    else
        req_nav_env_new
    fi
}

req_nav_env_new() {
    req_nav_prompt_begin
    if req_ask_name "" "Environment name" "staging"; then
        REQ_VIEW=$REQ_ENV_BACK
        req_env_use "$REQ_REPLY" now
    else
        req_cancelled
    fi
    req_nav_prompt_end
}

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

req_nav_back() {
    local last=$(( ${#REQ_STACK_DIR[@]} - 1 )) sel
    (( last >= 0 )) || return 0
    REQ_CUR_DIR=${REQ_STACK_DIR[last]}
    sel=${REQ_STACK_SEL[last]}
    unset "REQ_STACK_DIR[last]" "REQ_STACK_SEL[last]"
    req_nav_load
    REQ_SEL=$sel
}

req_nav_execute() {
    local errs=""
    req_screen_erase
    [[ ${REQ_NOTIFICATION_ACTIVE-0} == 1 ]] && errs=$(mktemp 2>/dev/null)
    if [[ -n $errs ]]; then
        req_run_request "$REQ_DETAIL_FILE" 2>"$errs"
        req_notification_warn_file "$errs"
        rm -f "$errs"
    else
        req_run_request "$REQ_DETAIL_FILE"
    fi
    return 0
}

req_nav_view_result() {
    req_result_check || return 0
    req_nav_prompt_begin
    req_result_view || true
    req_nav_prompt_end
    return 0
}

req_nav_handle() {
    local key=$1 n=${#REQ_ITEM_KIND[@]}
    REQ_NAV_DIRTY=1
    if [[ $key == $'\f' ]]; then     # Ctrl-L works in every view and while a command is typed, and changes nothing else
        req_nav_clear_screen
        return 0
    fi
    if (( REQ_CMD_ACTIVE )); then
        req_cmd_key "$key"
        return 0
    fi
    if [[ $REQ_VIEW == help || $REQ_VIEW == config ]]; then
        REQ_VIEW=$REQ_HELP_BACK     # any key closes the help and the settings
        return 0
    fi
    if [[ $REQ_VIEW == env ]]; then
        req_nav_env_key "$key"      # the environment menu has its own keys, and ":" is not one of them
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
            esc|q) REQ_VIEW=list ;;
            h)     req_nav_help ;;
            v)     req_nav_view_result ;;
        esac
    else
        case $key in
            up)    (( n > 0 )) && REQ_SEL=$(( (REQ_SEL + n - 1) % n )) ;;
            down)  (( n > 0 )) && REQ_SEL=$(( (REQ_SEL + 1) % n )) ;;
            enter) (( n > 0 )) && req_nav_open ;;
            esc)   req_nav_back ;;
            q)     if (( ${#REQ_STACK_DIR[@]} > 0 )); then req_nav_back; else REQ_QUIT=1; fi ;;
            h)     req_nav_help ;;
            v)     req_nav_view_result ;;
        esac
    fi
    return 0
}

req_nav_overlay() {
    local cursor='_'
    req_utf8 && cursor='█'
    (( REQ_CMD_ACTIVE )) && REQ_SCREEN_LINES+=(":${REQ_CMD_BUF}${cursor}")
}

req_nav_run() {
    req_nav_init "$1" || return 1
    req_nav_restore_cursor
    REQ_EXIT_HOOK=req_nav_save_cursor      # a signal ends the process: save the cursor then too
    [[ -t 1 ]] && printf '\033[?25l'
    [[ -t 0 ]] && stty -echo 2>/dev/null
    while :; do
        req_notification_collect        # the bars of this draw, before the list is sized
        if (( REQ_NAV_DIRTY )); then
            case $REQ_VIEW in
                detail) req_nav_build_detail ;;
                help)   req_nav_build_help ;;
                config) req_nav_build_config ;;
                env)    req_nav_build_env ;;
                *)      req_nav_build_list ;;
            esac
            REQ_BASE_LINES=("${REQ_SCREEN_LINES[@]}"); REQ_BASE_EXTRA=$REQ_SCREEN_EXTRA
            REQ_NAV_DIRTY=0
        else
            REQ_SCREEN_LINES=("${REQ_BASE_LINES[@]}"); REQ_SCREEN_EXTRA=$REQ_BASE_EXTRA
        fi
        req_nav_overlay
        req_notification_overlay        # the bars go above everything else
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

req_nav_start() {
    local pfile status
    [[ -t 0 && -t 1 ]] || req_die "interactive mode needs a terminal (use 'req run <file>' in scripts)"
    req_nav_clear_screen
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
    REQ_NOTIFICATION_ACTIVE=1          # from here a warning goes to the bar at the top, not to the terminal
    req_project_activate "$(dirname "$pfile")"
    req_config_load_local || true      # the project's settings win over the global ones
    req_nav_run "$pfile"; status=$?
    REQ_NOTIFICATION_ACTIVE=0
    return "$status"
}

# ==== lib/notification.sh

REQ_NOTIFICATION_LINES=()      # the bar lines of the current draw, from the top of the screen
REQ_NOTIFICATION_IDS=()        # the persistent notifications, in registration order
REQ_NOTIFICATION_CHECKS=()     # their check functions, in the same order
REQ_NOTIFICATION_TEXT=""       # what a check that has something to say puts in its bar
REQ_NOTIFICATION_ACTIVE=0      # 1 while the menu is open: req_warn then goes through the warning bar
REQ_NOTIFICATION_WARN=""       # the warning that waits for the next draw ("" when there is none)
REQ_NOTIFICATION_WARN_MORE=0   # how many more came after it before that draw
REQ_NOTIFICATION_PRODUCERS=(req_notification_persistent_lines req_notification_warn_lines req_notification_status_lines)

req_notification_bar() {
    local cols room text pad
    cols=$(req_term_cols)
    if ! req_colors_enabled; then
        req_trunc "! $1" $(( cols - 1 ))
        return 0
    fi
    room=$(( cols - 3 ))                        # a space on each side and the last column
    (( room < 1 )) && room=1
    text=$(req_trunc "$1" "$room")
    pad=$(( cols - 2 - ${#text} ))
    (( pad < 0 )) && pad=0                      # a negative width would pad on the other side
    printf '%s %s%*s%s' "$(req_color notification)" "$text" "$pad" '' "$(req_color reset)"
}

req_notification_more() {
    local suffix=""
    (( $2 > 0 )) && suffix=" (+$2 more)"
    printf '%s%s' "$(req_trunc "$1" $(( $(req_term_cols) - 3 - ${#suffix} )))" "$suffix"
}

req_notification_collect() {
    local producer
    REQ_NOTIFICATION_LINES=()
    for producer in "${REQ_NOTIFICATION_PRODUCERS[@]}"; do
        if declare -F "$producer" >/dev/null; then "$producer"; fi
    done
    return 0
}

req_notification_overlay() {
    (( ${#REQ_NOTIFICATION_LINES[@]} > 0 )) || return 0
    REQ_SCREEN_LINES=("${REQ_NOTIFICATION_LINES[@]}" "${REQ_SCREEN_LINES[@]}")
}

req_notification_register() {
    local id=$1 check=$2 i
    [[ -n $id && -n $check ]] || return 1
    for i in "${!REQ_NOTIFICATION_IDS[@]}"; do
        if [[ ${REQ_NOTIFICATION_IDS[i]} == "$id" ]]; then
            REQ_NOTIFICATION_CHECKS[i]=$check
            return 0
        fi
    done
    REQ_NOTIFICATION_IDS+=("$id")
    REQ_NOTIFICATION_CHECKS+=("$check")
}

req_notification_persistent_lines() {
    local check
    for check in "${REQ_NOTIFICATION_CHECKS[@]}"; do
        REQ_NOTIFICATION_TEXT=""
        declare -F "$check" >/dev/null || continue
        if "$check" && [[ -n $REQ_NOTIFICATION_TEXT ]]; then
            REQ_NOTIFICATION_LINES+=("$(req_notification_bar "$REQ_NOTIFICATION_TEXT")")
        fi
    done
    return 0
}

req_notification_warn() {
    local msg=$*
    msg=${msg//$'\n'/ }
    [[ -n $msg ]] || return 0
    if [[ -z $REQ_NOTIFICATION_WARN ]]; then
        REQ_NOTIFICATION_WARN=$msg
    else
        REQ_NOTIFICATION_WARN_MORE=$(( REQ_NOTIFICATION_WARN_MORE + 1 ))
    fi
    return 0
}

req_notification_warn_file() {
    local line text=""
    [[ -s $1 ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line#req: error: }; line=${line#req: warning: }
        line=${line#"${line%%[![:space:]]*}"}          # without the indentation
        [[ -n $line ]] || continue
        text+="${text:+; }$line"
    done <"$1"
    req_notification_warn "$text"
}

req_notification_warn_lines() {
    local text
    [[ -n $REQ_NOTIFICATION_WARN ]] || return 0
    text=$(req_notification_more "$REQ_NOTIFICATION_WARN" "$REQ_NOTIFICATION_WARN_MORE")
    REQ_NOTIFICATION_WARN=""; REQ_NOTIFICATION_WARN_MORE=0
    REQ_NOTIFICATION_LINES+=("$(req_notification_bar "$text")")
    return 0
}

req_notification_status_lines() {
    local text=${REQ_STATUS-}
    [[ -n $text ]] || return 0
    REQ_STATUS=""
    REQ_NOTIFICATION_LINES+=("$(req_notification_bar "${text//$'\n'/ }")")
    return 0
}

req_notification_is_root() {
    (( EUID == 0 ))
}

req_notification_root_check() {
    req_notification_is_root || return 1
    REQ_NOTIFICATION_TEXT="running as root: files you create or edit may end up owned by root, not you"
}

# ==== lib/wizard.sh

REQ_REPLY_JSON="{}"     # last object built by req_ask_pairs / req_ask_preset
REQ_PRESET=none         # format chosen by the last req_ask_preset: json, text, html or none
REQ_LAST_FILE=""        # last request file written by a wizard
REQ_LAST_DIR=""         # last directory created by a wizard

req_cancelled() {
    printf 'Cancelled.\n'
    return 1
}

req_ask_name() {
    local def=${1-} what=${2:-Name} example=${3:-list-users} label
    label="$what (a slug, e.g. $example)"
    [[ -z $def ]] && label+=" - empty to cancel"
    while :; do
        req_prompt "$label" "$def" || return 1
        [[ -n $REQ_REPLY ]] || return 1
        req_valid_name "$REQ_REPLY" && return 0
        req_err "invalid name: use lowercase letters, digits and hyphens"
    done
}

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

req_ask_url() {
    while :; do
        req_prompt "URL" "${1-}" || return 1
        [[ -n $REQ_REPLY ]] && return 0
        req_err "the url is required"
    done
}

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

req_ask_pairs() {
    local title=$1 json=${2:-"{}"} line key val
    printf '%s: key=value per line, "-key" removes, empty line to finish\n' "$title"
    while :; do
        req_prompt "  $title" "" || break
        line=$(req_trim "$REQ_REPLY")
        [[ -n $line ]] || break
        if [[ $line == -* ]]; then
            key=$(req_trim "${line#-}")
            json=$(jq -c --arg k "$key" 'del(.[$k])' <<<"$json")
            continue
        fi
        if [[ $line != *=* ]]; then
            req_err "expected key=value"
            continue
        fi
        key=$(req_trim "${line%%=*}")
        val=$(req_trim "${line#*=}")
        if [[ -z $key ]]; then
            req_err "the key cannot be empty"
            continue
        fi
        json=$(jq -c --arg k "$key" --arg v "$val" '. + {($k): $v}' <<<"$json")
    done
    REQ_REPLY_JSON=$json
}

req_raw_text() {
    [[ -n ${1-} ]] || return 0
    if [[ $(jq -r type <<<"$1") == string ]]; then jq -r . <<<"$1"; else jq . <<<"$1"; fi
}

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
        req_ask_pairs "Headers" "$headers" && headers=$REQ_REPLY_JSON
        req_ask_pairs "Query" "{}" && query=$REQ_REPLY_JSON
        case $method in
            POST|PUT|PATCH)
                if [[ $REQ_PRESET != none ]] &&
                   req_confirm "Write the body (raw data) in your editor?" y; then
                    local ask=0; [[ $REQ_PRESET == json ]] && ask=1
                    req_ask_raw_data "" "$ask" && raw=$REQ_REPLY_JSON
                else
                    req_ask_pairs "Parameters" "{}" && params=$REQ_REPLY_JSON
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
            5) req_ask_pairs "Headers" "$(jq -c '.headers // {}' <<<"$json")" &&
                   json=$(jq -c --argjson v "$REQ_REPLY_JSON" '.headers = $v' <<<"$json") ;;
            6) req_ask_pairs "Query" "$(jq -c '.query // {}' <<<"$json")" &&
                   json=$(jq -c --argjson v "$REQ_REPLY_JSON" '.query = $v' <<<"$json") ;;
            7) req_ask_pairs "Parameters" "$(jq -c '.parameters // {}' <<<"$json")" &&
                   json=$(jq -c --argjson v "$REQ_REPLY_JSON" '.parameters = $v' <<<"$json") ;;
            8) cur=$(jq -c '.raw_data // ""' <<<"$json")
               [[ $cur == '""' ]] && cur=""
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

req_wizard_duplicate() {
    req_wizard_copy_request "$1" || return 1
    req_wizard_edit "$REQ_LAST_FILE"
    return 0
}

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

REQ_CMD_ACTIVE=0        # 1 while a command is being typed
REQ_CMD_BUF=""          # the command typed so far
REQ_STATUS=""           # one-shot message of a command (a confirmation); req_notification_status_lines draws it in a bar
REQ_QUIT=0              # set by :q, ends the main loop

REQ_HELP_ROWS=(
    "Keys"
    "up/down|move the selection (wraps around)"
    "Enter|open a directory or request; run it on the details; pick in :env"
    "Esc / q|go back one level; at the root q quits, Esc does nothing"
    "h|this help (same as :h)"
    "v|show the last response in a pager; q leaves it (Esc does not)"
    "Ctrl-L|clear the screen; the menu is drawn again at the top"
    "Ctrl-C|quit"
    ":|command mode (Esc cancels)"
    "any key|closes this help and the settings screen (:config)"
    "Commands"
    ":n|new request in the current directory"
    ":nd [name]|new directory (alias :mkdir)"
    ":ed [name]|rename the directory under the cursor (a request is edited with :e)"
    ":cp [name]|copy the directory (with its contents) or request under the cursor"
    ":rm|remove the selected request or directory, with a y/N question first"
    ":e|edit the selected request (alias :edit)"
    ":d|duplicate the selected request (alias :dup)"
    ":env [name]|menu to pick or create one, or jump to <name>"
    ":vars|edit the project variables in your editor (alias :var)"
    ":log [yes|no]|switch the log of requests and responses in this session (setting: log)"
    ":v [yes|no]|switch the verbose mode (>> sent, << received) in this session (REQ_VERBOSE)"
    ":config [-g] [key=value]|show the settings, or change one (this project's; -g: global ~/.req/config)"
    ":h|this help (alias :help)"
    ":q|quit (alias :quit)"
    "Outside the menu"
    "req log|follow the project's log from another terminal (tail -F)"
)
REQ_HELP_BACK=list      # view to return to when the help screen closes

req_nav_help() {
    REQ_HELP_BACK=$REQ_VIEW
    REQ_VIEW=help
}

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
        var|vars)     req_cmd_vars "$arg" ;;
        config)       req_cmd_config "$arg" ;;
        log)          req_cmd_log "$arg" ;;
        v|verbose)    req_cmd_verbose "$arg" ;;
        h|help)       req_nav_help ;;
        *)            req_notification_warn "unknown command :$cmd (:h lists the commands)" ;;
    esac
    return 0
}

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

req_nav_selected_request() {
    if [[ $REQ_VIEW == detail ]]; then
        printf '%s' "$REQ_DETAIL_FILE"
    elif (( ${#REQ_ITEM_KIND[@]} > 0 )) && [[ ${REQ_ITEM_KIND[REQ_SEL]} == r ]]; then
        printf '%s' "${REQ_ITEM_PATH[REQ_SEL]}"
    else
        return 1
    fi
}

req_nav_selected_dir() {
    [[ $REQ_VIEW == list ]] && (( ${#REQ_ITEM_KIND[@]} > 0 )) && [[ ${REQ_ITEM_KIND[REQ_SEL]} == d ]] || return 1
    printf '%s' "${REQ_ITEM_PATH[REQ_SEL]}"
}

req_cmd_rename_dir() {
    local dir
    if ! dir=$(req_nav_selected_dir); then
        if req_nav_selected_request >/dev/null; then
            req_notification_warn ":ed renames a directory; edit a request with :e"
        else
            req_notification_warn "select a directory on the list first"
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
        req_notification_warn "select a request or a directory first"
    fi
}

req_cmd_remove() {
    local target sel=$REQ_SEL kind=request
    if target=$(req_nav_selected_request); then :
    elif target=$(req_nav_selected_dir); then kind=directory
    else req_notification_warn "select a request or a directory first"; return 0
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
    file=$(req_nav_selected_request) || { req_notification_warn "select a request first"; return 0; }
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
    file=$(req_nav_selected_request) || { req_notification_warn "select a request first"; return 0; }
    req_nav_prompt_begin
    if req_wizard_duplicate "$file"; then
        REQ_VIEW=list
        req_nav_refresh "$REQ_LAST_FILE"
        REQ_STATUS="duplicated as ${REQ_LAST_FILE##*/}"
    elif [[ -f $REQ_LAST_FILE && $REQ_LAST_FILE != "$file" ]]; then
        REQ_VIEW=list
        req_nav_refresh "$REQ_LAST_FILE"
    fi
    req_nav_prompt_end
}

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
        req_notification_warn "usage: :config [-g] [key=value] (known keys: ${REQ_CONFIG_KEYS[*]})"
        return 0
    fi
    if [[ $scope == project && -z $REQ_PROJECT_ID ]]; then
        req_notification_warn "no project is open: use :config -g key=value to change the global setting"
        return 0
    fi
    key=$(req_trim "${arg%%=*}"); value=$(req_trim "${arg#*=}")
    if ! req_config_known "$key"; then
        req_notification_warn "unknown setting \"$key\" (known keys: ${REQ_CONFIG_KEYS[*]})"
        return 0
    fi
    if ! req_config_valid "$key" "$value"; then
        req_notification_warn "$key must be $(req_config_expect "$key"), not \"$value\""
        return 0
    fi
    if [[ $scope == project ]]; then file=$(req_config_local_file); else file=$(req_config_file); fi
    if req_kv_set "$file" "$key" "$value" 2>/dev/null; then
        req_config_load 2>/dev/null
        REQ_STATUS="$key=$value saved in $file"
    else
        req_notification_warn "cannot write $file"
    fi
    return 0
}

req_cmd_switch() {
    case $1 in
        yes|on)  printf yes ;;
        no|off)  printf no ;;
        '')      [[ $2 == yes ]] && printf no || printf yes ;;
        *)       return 1 ;;
    esac
}

req_cmd_log() {
    local now=no new
    if [[ -z $REQ_PROJECT_ID ]]; then
        req_notification_warn "no project is open, so there is no log to switch"
        return 0
    fi
    req_log_enabled && now=yes
    if ! new=$(req_cmd_switch "$1" "$now"); then
        req_notification_warn "usage: :log [yes|no]"
        return 0
    fi
    REQ_LOG_SESSION=$new
    if [[ $new == yes ]]; then REQ_STATUS="log on for this session: $(req_log_file)"
    else REQ_STATUS="log off for this session"; fi
    return 0
}

req_cmd_verbose() {
    local now=no new
    req_verbose_on && now=yes
    if ! new=$(req_cmd_switch "$1" "$now"); then
        req_notification_warn "usage: :v [yes|no]"
        return 0
    fi
    if [[ $new == yes ]]; then REQ_VERBOSE=1; REQ_STATUS="verbose on for this session (>> sent, << received)"
    else REQ_VERBOSE=0; REQ_STATUS="verbose off for this session"; fi
    return 0
}

req_env_activate() {
    local name=$1 made=${2-} errs ok=1 note n
    REQ_ENV=$name
    if errs=$(mktemp 2>/dev/null); then
        req_vars_load "$name" 2>"$errs" || ok=0
        req_notification_warn_file "$errs"
        rm -f "$errs"
    else
        req_vars_load "$name" 2>/dev/null || { ok=0; req_notification_warn "cannot load the variables of environment \"$name\""; }
    fi
    if (( ok )); then
        n=${#REQ_VARS[@]}
        case $n in
            0) note="no variables" ;;
            1) note="1 variable" ;;
            *) note="$n variables" ;;
        esac
    else
        note="variables not loaded"
    fi
    REQ_STATUS="environment: $name${made:+, created in $made} ($note)"
}

req_env_use() {
    local name=$1 mode=${2:-ask} file err
    if ! req_valid_name "$name"; then
        req_notification_warn "invalid environment name \"$name\" (use a slug: lowercase letters, digits and hyphens)"
        return 0
    fi
    if req_env_exists "$name"; then
        req_env_activate "$name"
        return 0
    fi
    if [[ -z $REQ_PROJECT_ID ]]; then
        req_notification_warn "unknown environment \"$name\"; the project state in $(req_config_dir) is not available"
        return 0
    fi
    if [[ $mode == ask ]]; then
        req_nav_prompt_begin
        req_confirm "Create environment \"$name\"?" y || {
            req_nav_prompt_end
            REQ_STATUS="environment \"$name\" not created (in use: ${REQ_ENV:-default})"
            return 0; }
        req_nav_prompt_end
    fi
    file=$(req_env_file "$REQ_PROJECT_ID" "$name")
    if ! err=$(req_env_create "$name" 2>&1); then
        req_notification_warn "${err#req: error: }"
        return 0
    fi
    req_env_activate "$name" "$(req_abs_path "$file")"
    return 0
}

req_cmd_env() {
    local name=$1 current=${REQ_ENV:-default} i
    if [[ -n $name ]]; then
        req_env_use "$name"
        return 0
    fi
    if [[ -z $REQ_PROJECT_ID ]]; then
        req_notification_warn "the project state in $(req_config_dir) is not available, so only the default environment can be used (in use: $current)"
        return 0
    fi
    req_env_choices
    REQ_ENV_SEL=0; REQ_ENV_TOP=0
    for i in "${!REQ_ENV_CHOICES[@]}"; do
        [[ ${REQ_ENV_CHOICES[i]} == "$current" ]] && REQ_ENV_SEL=$i
    done
    REQ_ENV_BACK=$REQ_VIEW; REQ_VIEW="env"
    return 0
}

req_vars_howto() {
    printf 'No editor found (tried $VISUAL, $EDITOR, vim and nano).\n'
    printf 'The variables of the project, shared by every environment, are in:\n\n  %s\n\n' "$1"
    printf 'Add one per line, as key=value, for example:\n\n  host=https://api.example.com\n\n'
    printf 'and use it in a request as ${host}. Set $EDITOR, or install vim or nano, to edit them with :vars.\n\n'
    req_prompt "Press Enter to go back" "" || true
}

req_cmd_vars() {
    local file abs err status
    if [[ -n $1 ]]; then
        req_notification_warn "usage: :vars (no argument: it opens the variables shared by every environment)"
        return 0
    fi
    if [[ -z $REQ_PROJECT_ID ]]; then
        req_notification_warn "the project state in $(req_config_dir) is not available, so there are no variables to edit"
        return 0
    fi
    if ! err=$(req_vars_create 2>&1); then
        req_notification_warn "${err#req: error: }"
        return 0
    fi
    file=$(req_vars_file "$REQ_PROJECT_ID")
    abs=$(req_abs_path "$file")
    req_nav_prompt_begin
    req_edit_file "$file" vim nano; status=$?
    (( status == 2 )) && req_vars_howto "$abs"
    req_nav_prompt_end
    case $status in
        0) req_env_activate "${REQ_ENV:-default}" ;;
        1) req_notification_warn "the editor failed; $abs is as the editor left it" ;;
    esac
    return 0
}

# ==== lib/env.sh

declare -gA REQ_VARS=()      # variables of the last loaded environment (key -> value)

req_env_file() {
    req_project_state_dir "$1" "env/$2"
}

req_vars_file() {
    req_project_state_dir "$1" vars
}

req_env_legacy_file() {
    printf '%s/env/%s/secrets.json' "$(req_config_dir)" "$1"
}

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

req_env_var_name() {
    local env=${1^^} key=${2^^}
    printf '%s_%s' "${env//-/_}" "$key"
}

REQ_RESOLVED=""        # the value found by req_resolve_key_var

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

req_resolve_key() {
    req_resolve_key_var "$1" "$2" || return 1
    printf '%s\n' "$REQ_RESOLVED"
}

REQ_SUBST_OUT=""        # the text produced by req_subst

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

REQ_SUBST_FIELDS='["url","headers","query","parameters","raw_data","files"]'

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

req_env_exists() {
    local env=$1 id=${2-$REQ_PROJECT_ID}
    req_valid_name "$env" || return 1
    [[ $env == default ]] && return 0
    [[ -n $id && -f $(req_env_file "$id" "$env") ]]
}

req_env_ensure_dir() {
    local id=${1-$REQ_PROJECT_ID} dir
    [[ -n $id ]] || { req_err "no project is open, so there is no folder for its environments"; return 1; }
    req_valid_name "$id" || { req_err "invalid project id: \"$id\""; return 1; }
    dir=$(req_project_state_dir "$id" env)
    [[ -d $dir ]] && return 0
    (umask 077; mkdir -p "$dir") 2>/dev/null || { req_err "cannot create $(req_abs_path "$dir")"; return 1; }
}

req_env_create() {
    local env=$1 id=${2-$REQ_PROJECT_ID} file abs
    req_valid_name "$env" || {
        req_err "invalid environment name: \"$env\" (use a slug: lowercase letters, digits and hyphens)"
        return 1; }
    req_env_ensure_dir "$id" || return 1
    file=$(req_env_file "$id" "$env")
    abs=$(req_abs_path "$file")
    [[ -f $file ]] && return 0
    [[ ! -e $file && ! -L $file ]] || { req_err "$abs exists and is not a file"; return 1; }
    (umask 077; set -o noclobber; : >"$file") 2>/dev/null || { req_err "cannot create $abs"; return 1; }
}

req_vars_template() {
    printf '%s\n' \
        '# Variables of this project, shared by every environment (the file of an environment wins).' \
        '# One per line, key=value: the key uses letters, digits and underscores; the value is the rest of the line.' \
        '# Lines that start with # are comments. A request uses a variable as ${key}, for example ${host}/users.' \
        '#' \
        '# host=https://api.example.com' \
        ''
}

req_vars_create() {
    local id=${1-$REQ_PROJECT_ID} file abs
    [[ -n $id ]] || { req_err "no project is open, so there are no variables to make"; return 1; }
    req_valid_name "$id" || { req_err "invalid project id: \"$id\""; return 1; }
    file=$(req_vars_file "$id")
    abs=$(req_abs_path "$file")
    [[ -f $file ]] && return 0
    [[ ! -e $file && ! -L $file ]] || { req_err "$abs exists and is not a file"; return 1; }
    (umask 077; mkdir -p "${file%/*}"; set -o noclobber; req_vars_template >"$file") 2>/dev/null ||
        { req_err "cannot create $abs"; return 1; }
}

declare -ga REQ_ENV_CHOICES=()      # the environments to choose from (req_env_choices)

req_env_choices() {
    local id=${1-$REQ_PROJECT_ID} name
    REQ_ENV_CHOICES=(default)
    while IFS= read -r name; do
        [[ -z $name || $name == default ]] || REQ_ENV_CHOICES+=("$name")
    done < <(req_env_list "$id")
    return 0
}

# ==== lib/home.sh

REQ_KV_KEY=""       # set by req_kv_parse_line
REQ_KV_VALUE=""

req_kv_valid_key() {
    [[ $1 =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

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

req_kv_list() {
    local line
    [[ -f $1 ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
        req_kv_parse_line "$line" && printf '%s=%s\n' "$REQ_KV_KEY" "$REQ_KV_VALUE"
    done <"$1"
    return 0
}

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

req_kv_unset() {
    [[ -f $1 ]] || return 1
    req_kv_rewrite "$1" unset "$2"
}

req_config_dir() {
    printf '%s' "${REQ_CONFIG_DIR:-$HOME/.req}"
}

req_projects_dir() {
    printf '%s/projects' "$(req_config_dir)"
}

req_project_state_dir() {
    printf '%s/%s' "$(req_projects_dir)" "$1"
    [[ -z ${2-} ]] || printf '/%s' "$2"
}

req_project_slug() {
    local name=${1%/} slug
    name=${name##*/}
    slug=$(LC_ALL=C tr '[:upper:]' '[:lower:]' <<<"$name" | LC_ALL=C tr -cs 'a-z0-9' '-')
    slug=${slug#-}; slug=${slug%-}
    printf '%s' "${slug:-project}"
}

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

req_project_new_id() {
    local slug id n=1
    slug=$(req_project_slug "$1")
    id=$slug
    while [[ -e $(req_project_state_dir "$id") ]]; do
        n=$(( n + 1 )); id=$slug-$n
    done
    printf '%s\n' "$id"
}

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

req_current_get() {
    local id
    id=$(req_kv_get "$(req_config_dir)/current" project) || return 1
    req_valid_name "$id" && [[ -d $(req_project_state_dir "$id") ]] || return 1
    printf '%s\n' "$id"
}

req_current_set() {
    if ! { req_valid_name "$1" && [[ -d $(req_project_state_dir "$1") ]]; }; then
        req_err "unknown project: $1"
        return 1
    fi
    req_kv_set "$(req_config_dir)/current" project "$1"
}

REQ_PROJECT_ID=""       # id of the project opened by req_project_activate

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
    problem=$(req_env_create default "$id" 2>&1) || req_warn "${problem#req: error: }"
    return 0
}

req_cursor_file() {
    req_project_state_dir "$1" cursor
}

req_cursor_save() {
    local file
    file=$(req_cursor_file "$1")
    req_kv_set "$file" dir "$2" && req_kv_set "$file" item "$3"
}

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

req_config_file() {
    printf '%s/config' "$(req_config_dir)"
}

req_config_local_file() {
    req_project_state_dir "$REQ_PROJECT_ID" config
}

req_config_known() {
    [[ -n ${REQ_CONFIG_TYPE[$1]+x} ]]
}

req_config_valid() {
    req_config_known "$1" || return 1
    case ${REQ_CONFIG_TYPE[$1]} in
        bool) [[ $2 == yes || $2 == no ]] ;;
        int)  [[ $2 =~ ^[0-9]{1,9}$ ]] ;;
        *)    return 1 ;;
    esac
}

req_config_expect() {
    case ${REQ_CONFIG_TYPE[$1]-} in
        bool) printf 'yes or no' ;;
        int)  printf 'a whole number (0 or more)' ;;
    esac
}

req_config_load() {
    local status=0
    req_config_load_file "$(req_config_file)" || status=1
    req_config_load_local || status=1
    return "$status"
}

req_config_load_local() {
    REQ_CONFIG_LOCAL=()
    [[ -n $REQ_PROJECT_ID ]] || return 0
    req_config_load_file "$(req_config_local_file)" overlay
}

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
        [[ ${2-} == overlay ]] && REQ_CONFIG_LOCAL[$REQ_KV_KEY]=1
    done <"$file"
    return "$status"
}

req_config_get() {
    req_config_known "$1" || return 1
    printf '%s\n' "${REQ_CONFIG[$1]-${REQ_CONFIG_DEFAULT[$1]}}"
}

# ==== lib/log.sh

req_log_file() {
    req_project_state_dir "$REQ_PROJECT_ID" req.log
}

REQ_LOG_SESSION=""      # yes or no after :log (it wins over the setting until req quits)

req_log_enabled() {
    [[ -n $REQ_PROJECT_ID && ${REQ_LOG_SESSION:-$(req_config_get log)} == yes ]]
}

req_log_escape() {
    local text=${1//$'\r'/}
    printf '%s' "${text//$'\n'/\\n}"
}

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

req_log_response() {
    req_log_enabled || return 0
    req_log_write RESPONSE "status=$REQ_RESP_STATUS type=${REQ_RESP_CTYPE:--} total=${REQ_RESP_TIMES[5]}s | body: $REQ_RESP_BODY"
}

req_log_failure() {
    req_log_write ERROR "no response (curl exit code $1)"
}

REQ_LOG_FOLLOW_LINES=200    # lines "req log" shows before it starts to follow

req_log_follow() {
    local id file
    if ! req_project_find . >/dev/null; then
        req_err "no $REQ_PROJECT_FILE in $PWD: run 'req log' in the folder of a req project ('req init' starts one)"
        return 1
    fi
    if ! id=$(req_project_find_id .); then
        req_err "$PWD/$REQ_PROJECT_FILE is not registered yet: open the project once with 'req'"
        return 1
    fi
    file=$(req_project_state_dir "$id" req.log)
    if [[ ! -e $file ]]; then
        printf 'req: waiting for the log %s (a request writes it with the log on: :log yes in the menu, or :config log=yes)\n' "$file" >&2
        until [[ -e $file ]]; do sleep 0.5; done
    fi
    tail -n "$REQ_LOG_FOLLOW_LINES" -F -- "$file"
}

# ==== bin/req

req_usage() {
    cat <<'USAGE'
usage: req                  open the interactive menu (uses the .req in the current directory)
       req init             initialize a req project in the current directory
       req run <file>       run a request and show the result
       req log              follow the project's log (tail -F), from another terminal
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
    if [[ -z ${1-} && -t 0 && -t 1 ]]; then REQ_NOTIFICATION_ACTIVE=1; fi
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
            if req_project_find . >/dev/null; then REQ_PROJECT_ID=$(req_project_find_id .) || REQ_PROJECT_ID=""; fi
            req_config_load_local || true
            req_run_request "$2"
            ;;
        log)
            [[ -z ${2-} ]] || { req_usage >&2; return 1; }
            req_log_follow
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
