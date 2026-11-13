#!/usr/bin/env bash
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
REQ_PREPARE_JQ='
((.method // "") | ascii_upcase) as $m
| (.headers // {}) as $h
| (.parameters // {}) as $d
| (.raw_data // "") as $r
| (.timeout // "") as $t
| ($m == "POST" or $m == "PUT" or $m == "PATCH") as $body
| (["method", $m],
   ["url", ((.url // "") as $u
            | ((.query // {}) | to_entries
               | map("\(.key | @uri)=\(.value | tostring | @uri)") | join("&")) as $q
            | if $q == "" then $u
              elif ($u | contains("?")) then $u + "&" + $q
              else $u + "?" + $q end)],
   ($h | to_entries[] | ["header", "\(.key): \(.value)"]),
   ["hasctype", ($h | keys | any(ascii_downcase == "content-type") | tostring)],
   (if $t != "" then ["timeout", ($t | tostring)] else empty end),
   (if $body and $r != "" then
        ["raw", (if ($r | type) == "string" then $r else ($r | tojson) end)],
        ["rawjson", (($r | type) != "string" | tostring)]
    elif $body and ($d | length) > 0 then
        ($d | to_entries[] | ["form", "\(.key)=\(.value | tostring)"])
    else empty end))
| .[] | (., "\u0000")'

REQ_P_METHOD=""; REQ_P_URL=""; REQ_P_HEADERS=(); REQ_P_HASCTYPE=false
REQ_P_RAW=""; REQ_P_RAWSET=0; REQ_P_RAWJSON=false; REQ_P_FORM=(); REQ_P_TIMEOUT=""

# req_prepare_request <json> - fills REQ_P_* from the request. Fails without a url.
req_prepare_request() {
    local tag val
    REQ_P_METHOD=""; REQ_P_URL=""; REQ_P_HEADERS=(); REQ_P_HASCTYPE=false
    REQ_P_RAW=""; REQ_P_RAWSET=0; REQ_P_RAWJSON=false; REQ_P_FORM=(); REQ_P_TIMEOUT=""
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
# "100 Continue") is skipped. Text that does not start with "HTTP/" is all body.
req_split_headers() {
    local rest=$1 block line crlf=$'\r\n'
    REQ_RESP_STATUSLINE=""; REQ_RESP_HEADERS=()
    while [[ $rest == HTTP/* && $rest == *"$crlf$crlf"* ]]; do
        block=${rest%%"$crlf$crlf"*}; rest=${rest#*"$crlf$crlf"}
        REQ_RESP_STATUSLINE=${block%%"$crlf"*}; REQ_RESP_HEADERS=()
        [[ $block == *"$crlf"* ]] && while IFS= read -r line; do
            [[ -z $line ]] || REQ_RESP_HEADERS+=("${line%$'\r'}")
        done <<<"${block#*"$crlf"}"
        [[ $REQ_RESP_STATUSLINE =~ ^HTTP/[0-9.]+\ 1[0-9][0-9] ]] || break
    done
    REQ_RESP_BODY=$rest
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
