#!/usr/bin/env bash
# log.sh - the project's log of what req sends: $REQ_CONFIG_DIR/projects/<id>/req.log.
#
# One plain-text line per event: a timestamp, the kind of event and its data, with line breaks inside values written
# as \n so a line never wraps. Written only when the "log" setting is yes (config.sh) and a project is open. Values are
# logged as they are sent, with the real value of every ${key} (nothing is masked). A log that cannot be written is
# one warning per run, never a reason to stop a request.

req_log_file() {
    req_project_state_dir "$REQ_PROJECT_ID" req.log
}

REQ_LOG_SESSION=""      # yes or no after :log (it wins over the setting until req quits)

# req_log_enabled - the log is on (the session's choice, else the "log" setting) and a project is open.
req_log_enabled() {
    [[ -n $REQ_PROJECT_ID && ${REQ_LOG_SESSION:-$(req_config_get log)} == yes ]]
}

req_log_escape() {
    local text=${1//$'\r'/}
    printf '%s' "${text//$'\n'/\\n}"
}

# req_log_trim <file> - keeps the last log_request_limit lines (0: no limit); a log that cannot be rewritten
# stays as it is.
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

# req_log_write <event> <text> - appends "<timestamp> <EVENT> <text>", then trims. Nothing when the log is
# off.
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

# req_log_request <request file> <environment> - logs the request just prepared (REQ_P_*, REQ_BODY): file,
# environment, method, url, then headers, form fields, files and the body, joined by " | ".
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

# req_log_response - logs the response just received (REQ_RESP_*): status, Content-Type, total time and the
# whole body.
req_log_response() {
    req_log_enabled || return 0
    req_log_write RESPONSE "status=$REQ_RESP_STATUS type=${REQ_RESP_CTYPE:--} total=${REQ_RESP_TIMES[5]}s | body: $REQ_RESP_BODY"
}

req_log_failure() {
    req_log_write ERROR "no response (curl exit code $1)"
}

REQ_LOG_FOLLOW_LINES=200    # lines "req log" shows before it starts to follow

# req_log_follow - "req log": follows the log of the project of the current folder with tail -F, never -f
# (req_log_trim replaces the file, and -f would go on reading the old one in silence; -F prints the new file
# again after a trim). With no log yet it says so and waits for the file. Ctrl-C ends it.
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
