#!/usr/bin/env bash
# wizard.sh - interactive prompts to create, edit and duplicate requests and directories.
# All answers come from REQ_INPUT_FD, so the flows can be driven by tests.
#
# Conventions: an empty name (or end of input) cancels a flow; any other prompt
# accepts its default with Enter.

REQ_REPLY_JSON="{}"     # last object built by req_ask_pairs / req_ask_preset
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
# headers object ends up in REQ_REPLY_JSON.
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

# req_wizard_new <directory> - creates a request in the directory.
req_wizard_new() {
    local dir=$1 name method url desc="" headers="{}" query="{}" params="{}" json target
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
        req_ask_preset && headers=$REQ_REPLY_JSON
        req_ask_pairs "Headers" ":" "$headers" && headers=$REQ_REPLY_JSON
        req_ask_pairs "Query" "=" "{}" && query=$REQ_REPLY_JSON
        case $method in
            POST|PUT|PATCH) req_ask_pairs "Parameters" "=" "{}" && params=$REQ_REPLY_JSON ;;
        esac
    fi

    json=$(jq -cn --arg d "$desc" --argjson h "$headers" --argjson q "$query" --argjson p "$params" \
        '{description: $d, headers: $h, query: $q, data_parameter: $p}')
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
        "  7) parameters   \((.data_parameter // {}) | count)"' <<<"$1"
}

# req_wizard_edit <file> - field menu for a request. Changing the name or the
# method renames the file. Returns 0 after saving and 1 when cancelled.
req_wizard_edit() {
    local file=$1 dir json name method url target fields newfile cur
    dir=$(dirname "$file")
    req_request_check "$file" 2>/dev/null || {
        req_err "cannot edit an invalid request, fix the file first: $(req_abs_path "$file")"; return 1; }
    json=$(<"$file")

    while :; do
        printf 'Editing %s\n' "${file##*/}"
        req_edit_show "$json"
        req_prompt "Field to edit (1-7), s to save, q to cancel" "" || { req_cancelled; return 1; }
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
            7) req_ask_pairs "Parameters" "=" "$(jq -c '.data_parameter // {}' <<<"$json")" &&
                   json=$(jq -c --argjson v "$REQ_REPLY_JSON" '.data_parameter = $v' <<<"$json") ;;
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
            *) req_err "choose 1-7, s or q" ;;
        esac
    done
}

# req_wizard_duplicate <file> - copies a request under a new name, then opens the
# edit menu on the copy. Cancelling the edit keeps the copy.
req_wizard_duplicate() {
    local file=$1 dir name method url fields target
    dir=$(dirname "$file")
    req_request_check "$file" 2>/dev/null || {
        req_err "cannot duplicate an invalid request, fix the file first: $(req_abs_path "$file")"; return 1; }
    name=$(req_request_get "$file" name)
    method=$(req_request_get "$file" method); method=${method^^}
    url=$(req_request_get "$file" url)
    fields=$(jq -c 'del(.name, .method, .url)' "$file")

    while :; do
        req_ask_name "$name-copy" || { req_cancelled; return 1; }
        target=$dir/$(req_request_filename "$REQ_REPLY" "$method")
        [[ ! -e $target ]] && break
        req_err "$target already exists"
    done
    REQ_LAST_FILE=$(req_request_write "$dir" "$REQ_REPLY" "$method" "$url" "$fields") || return 1
    printf 'Created %s\n' "$REQ_LAST_FILE"
    req_wizard_edit "$REQ_LAST_FILE"
    return 0
}

# req_wizard_mkdir <parent> [.req file] [name] - creates a directory. With a .req
# file (the project root) the directory is created next to it and listed in it;
# otherwise it is created inside <parent>. The name is asked for unless given.
req_wizard_mkdir() {
    local parent=$1 pfile=${2-} name=${3-} base
    if [[ -z $name ]]; then
        req_ask_name "" "Directory name" || { req_cancelled; return 1; }
        name=$REQ_REPLY
    fi
    if [[ -n $pfile ]]; then
        req_project_add_dir "$pfile" "$name" || return 1
        base=$(cd -P "$(dirname "$pfile")" && pwd)
        REQ_LAST_DIR=$base/$name
    else
        req_valid_name "$name" || {
            req_err "invalid directory name: \"$name\" (use a slug: lowercase letters, digits and hyphens)"
            return 1; }
        [[ ! -e $parent/$name ]] || { req_err "$parent/$name already exists"; return 1; }
        mkdir "$parent/$name" 2>/dev/null || { req_err "cannot create $parent/$name"; return 1; }
        REQ_LAST_DIR=$parent/$name
    fi
    printf 'Created directory %s\n' "$REQ_LAST_DIR"
}
