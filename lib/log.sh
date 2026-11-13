#!/usr/bin/env bash
# log.sh - the project's log of what req sends: $REQ_CONFIG_DIR/projects/<id>/req.log.
#
# One line per event, in plain text: a timestamp, the kind of event and its data, with
# line breaks inside values written as \n so a line never wraps. It is written only when
# the "log" setting is yes (see config.sh) and a project is open. Values are logged as
# they are sent, with the real value of every ${key} (nothing is masked, see TASKS.md).
# A log that cannot be written is one warning per run, never a reason to stop a request.

# req_log_file - path of the open project's log.
req_log_file() {
    req_project_state_dir "$REQ_PROJECT_ID" req.log
}

# req_log_enabled - succeeds when the log is on and there is a project to keep it in.
req_log_enabled() {
    [[ -n $REQ_PROJECT_ID && $(req_config_get log) == yes ]]
}

# req_log_escape <text> - prints the text on one line (line breaks become \n).
req_log_escape() {
    local text=${1//$'\r'/}
    printf '%s' "${text//$'\n'/\\n}"
}

# req_log_write <event> <text> - appends "<timestamp> <EVENT> <text>" to the log. Does
# nothing when the log is off.
req_log_write() {
    req_log_enabled || return 0
    local file
    file=$(req_log_file)
    if ! printf '%s %s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" "$(req_log_escape "$2")" >>"$file" 2>/dev/null; then
        req_warn "cannot write the log $file; continuing without it"
        return 1
    fi
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
