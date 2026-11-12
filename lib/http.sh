#!/usr/bin/env bash
# http.sh - monta e executa a requisição via curl e exibe o resultado no terminal.
# A resposta é mantida em memória; nenhum arquivo é gravado no disco.

REQ_CURL_ARGS=()        # argumentos do curl montados por req_build_curl_args
REQ_BODY=""             # corpo enviado via stdin (--data-binary @-)
REQ_RESP_BODY=""        # corpo da última resposta
REQ_RESP_STATUS=""      # código HTTP da última resposta
REQ_RESP_CTYPE=""       # Content-Type da última resposta
REQ_RESP_TIMES=()       # dns connect tls pretransfer ttfb total (segundos, cumulativos)
REQ_BAR_WIDTH=30

# Metadados anexados pelo curl ao fim da saída; o Content-Type vai por último
# porque pode conter qualquer caractere exceto quebra de linha.
REQ_CURL_FORMAT=$'\n%{http_code}|%{time_namelookup}|%{time_connect}|%{time_appconnect}|%{time_pretransfer}|%{time_starttransfer}|%{time_total}|%{content_type}'

# req_build_url <json> - url com a querystring (url-encoded) anexada.
req_build_url() {
    local json=$1 url qs
    url=$(jq -r '.url // ""' <<<"$json")
    if [[ -z $url ]]; then
        req_err 'a request não tem "url"; defina o campo "url" no arquivo (ou edite com :e)'
        return 1
    fi
    qs=$(jq -r '(.query // {}) | to_entries
                | map("\(.key | @uri)=\(.value | tostring | @uri)") | join("&")' <<<"$json")
    if [[ -n $qs ]]; then
        [[ $url == *\?* ]] && url+="&$qs" || url+="?$qs"
    fi
    printf '%s' "$url"
}

# req_body_is_json <json> - sucesso se o header Content-Type da request indica JSON.
req_body_is_json() {
    jq -e '(.headers // {}) | to_entries
           | any((.key | ascii_downcase) == "content-type"
                 and (.value | tostring | ascii_downcase | contains("json")))' \
        <<<"$1" >/dev/null
}

# req_build_curl_args <json> - preenche REQ_CURL_ARGS e REQ_BODY.
# Corpo (enviado só em POST, PUT e PATCH): data_parameter, enviado como JSON se o Content-Type
# for JSON, ou como formulário url-encoded nos demais casos. O corpo JSON vai por
# stdin e o formulário usa "chave=valor", para que valores iniciados em "@" nunca
# sejam lidos como arquivo pelo curl.
req_build_curl_args() {
    local json=$1 method url line
    url=$(req_build_url "$json") || return 1
    method=$(jq -r '.method | ascii_upcase' <<<"$json")

    REQ_BODY=""
    REQ_CURL_ARGS=(-sS -g
        --connect-timeout "${REQ_CONNECT_TIMEOUT:-10}"
        --max-time "${REQ_TIMEOUT:-60}"
        -X "$method")

    while IFS= read -r line; do
        [[ -n $line ]] && REQ_CURL_ARGS+=(-H "$line")
    done < <(jq -r '(.headers // {}) | to_entries[] | "\(.key): \(.value)"' <<<"$json")

    if [[ $method == POST || $method == PUT || $method == PATCH ]]; then
        if [[ $(jq '(.data_parameter // {}) | length' <<<"$json") -gt 0 ]]; then
            if req_body_is_json "$json"; then
                REQ_BODY=$(jq -c '.data_parameter' <<<"$json")
                REQ_CURL_ARGS+=(--data-binary @-)
            else
                while IFS= read -r line; do
                    REQ_CURL_ARGS+=(--data-urlencode "$line")
                done < <(jq -r '.data_parameter | to_entries[] | "\(.key)=\(.value | tostring)"' <<<"$json")
            fi
        fi
    fi
    REQ_CURL_ARGS+=("$url")
}

# req_execute <json> - executa a request e preenche REQ_RESP_*.
# Devolve o status do curl (0 = a resposta HTTP foi recebida, qualquer código).
req_execute() {
    local json=$1 out meta status
    req_build_curl_args "$json" || return 1

    out=$(printf '%s' "$REQ_BODY" | curl "${REQ_CURL_ARGS[@]}" -w "$REQ_CURL_FORMAT")
    status=$?

    meta=${out##*$'\n'}
    REQ_RESP_BODY=${out%$'\n'*}
    IFS='|' read -r REQ_RESP_STATUS "REQ_RESP_TIMES[0]" "REQ_RESP_TIMES[1]" "REQ_RESP_TIMES[2]" \
        "REQ_RESP_TIMES[3]" "REQ_RESP_TIMES[4]" "REQ_RESP_TIMES[5]" REQ_RESP_CTYPE <<<"$meta"
    return "$status"
}

# req_timing_stages <dns> <connect> <tls> <pretransfer> <ttfb> <total>
# Converte os tempos cumulativos do curl em etapas. Imprime "<etapa>\t<ms>" por
# linha; TLS só aparece em conexões seguras. A última linha é o total.
req_timing_stages() {
    LC_ALL=C awk -v dns="$1" -v conn="$2" -v tls="$3" -v pre="$4" -v ttfb="$5" -v total="$6" '
        function clamp(x) { return x < 0 ? 0 : x }
        BEGIN {
            printf "DNS\t%.0f\n", clamp(dns) * 1000
            printf "TCP\t%.0f\n", clamp(conn - dns) * 1000
            if (tls > 0) printf "TLS\t%.0f\n", clamp(tls - conn) * 1000
            printf "Espera\t%.0f\n", clamp(ttfb - pre) * 1000
            printf "Download\t%.0f\n", clamp(total - ttfb) * 1000
            printf "Total\t%.0f\n", clamp(total) * 1000
        }'
}

# req_bar_char - bloco cheio em locales UTF-8, "#" nos demais.
req_bar_char() {
    case ${LC_ALL:-${LC_CTYPE:-${LANG-}}} in
        *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) printf '█' ;;
        *) printf '#' ;;
    esac
}

# req_print_profile - uma barra horizontal por etapa, proporcional ao tempo total.
req_print_profile() {
    local stages label ms total char bar n
    stages=$(req_timing_stages "${REQ_RESP_TIMES[@]}")
    total=$(tail -n 1 <<<"$stages"); total=${total#*$'\t'}
    char=$(req_bar_char)

    req_color dim; printf 'Tempo\n'; req_color reset
    while IFS=$'\t' read -r label ms; do
        if [[ $label == Total ]]; then
            printf '  %-9s %*s %5s ms\n' "$label" "$REQ_BAR_WIDTH" '' "$ms"
            continue
        fi
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

# req_print_body <content-type> <corpo> - JSON identado; texto e HTML como recebidos.
req_print_body() {
    local ctype=$1 body=$2 pretty flags=()
    if [[ -z $body ]]; then
        req_color dim; printf '(sem corpo)\n'; req_color reset
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

# req_run_request <arquivo> - valida, executa e mostra: resposta, perfil de tempo
# e uma linha de "=" que separa o resultado do menu remontado em seguida.
req_run_request() {
    local file=$1 json method url status
    req_request_check "$file" || return 1
    json=$(jq -c . "$file")
    url=$(req_build_url "$json") || return 1
    method=$(jq -r '.method | ascii_upcase' <<<"$json")

    req_method_color "$method"; printf '%s' "$method"; req_color reset
    printf ' %s\n' "$url"

    req_execute "$json"; status=$?
    if (( status != 0 )); then
        req_err "falha na requisição (curl código $status)"
        req_rule '='
        return 1
    fi

    printf 'HTTP '; req_paint_status "$REQ_RESP_STATUS"
    [[ -n $REQ_RESP_CTYPE ]] && printf '  %s' "$REQ_RESP_CTYPE"
    printf '\n\n'
    req_print_body "$REQ_RESP_CTYPE" "$REQ_RESP_BODY"
    printf '\n'
    req_print_profile
    req_rule '='
}
