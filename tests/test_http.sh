#!/usr/bin/env bash
# Testes de lib/http.sh. Os de execução usam tests/mock_server.py (requer python3).

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/tests/helpers.sh"
source "$ROOT/lib/core.sh"
source "$ROOT/lib/ui.sh"
source "$ROOT/lib/store.sh"
source "$ROOT/lib/http.sh"

TMP=$(mktemp -d)
SERVER_PID=""
cleanup() { [[ -n $SERVER_PID ]] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

# has_arg <arg> - sucesso se REQ_CURL_ARGS contém exatamente o argumento.
has_arg() {
    local a
    for a in "${REQ_CURL_ARGS[@]}"; do [[ $a == "$1" ]] && return 0; done
    return 1
}

test_url() {
    echo "http: url e querystring"
    assert_eq "http://x/a?b=1&c=a%20b" "$(req_build_url '{"url":"http://x/a","query":{"b":1,"c":"a b"}}')" "anexa query com encode"
    assert_eq "http://x/a?z=9&b=1" "$(req_build_url '{"url":"http://x/a?z=9","query":{"b":1}}')" "usa & se já houver ?"
    assert_eq "http://x/a" "$(req_build_url '{"url":"http://x/a"}')" "sem query"
    local out; out=$(req_build_url '{"method":"GET"}' 2>&1); assert_eq "1" "$?" "url ausente falha"
    assert_contains '"url"' "$out" "erro cita o campo url"
}

test_args() {
    echo "http: argumentos do curl"
    req_build_curl_args '{"method":"get","url":"http://x","headers":{"X-A":"1","Accept":"text/html"}}'
    has_arg -X && has_arg GET && has_arg "X-A: 1" && has_arg "Accept: text/html" && has_arg http://x
    assert_eq "0" "$?" "método, headers e url"
    assert_eq "" "$REQ_BODY" "GET sem corpo"

    local m
    for m in GET DELETE; do
        req_build_curl_args "{\"method\":\"$m\",\"url\":\"http://x\",\"data_parameter\":{\"a\":1},\"headers\":{\"Content-Type\":\"application/json\"}}"
        has_arg --data-urlencode || has_arg --data-binary; assert_eq "1" "$?" "$m não envia corpo"
        assert_eq "" "$REQ_BODY" "$m sem corpo em stdin"
    done

    req_build_curl_args '{"method":"PATCH","url":"http://x","data_parameter":{"a":"@/etc/passwd"}}'
    has_arg -X && has_arg PATCH && has_arg "a=@/etc/passwd"; assert_eq "0" "$?" "PATCH; valor com @ segue literal"

    req_build_curl_args '{"method":"POST","url":"http://x","headers":{"content-type":"application/json"},"data_parameter":{"a":1,"b":"x"}}'
    assert_eq '{"a":1,"b":"x"}' "$REQ_BODY" "data_parameter vira JSON com Content-Type json"

    req_build_curl_args '{"method":"PUT","url":"http://x","data_parameter":{"a":1,"b":"x y"}}'
    has_arg --data-urlencode && has_arg "a=1" && has_arg "b=x y"
    assert_eq "0" "$?" "data_parameter vira formulário sem Content-Type json"
    assert_eq "" "$REQ_BODY" "formulário não usa stdin"
}

test_timing() {
    echo "http: etapas de tempo"
    assert_eq $'DNS\t10\nTCP\t20\nTLS\t30\nEspera\t100\nDownload\t40\nTotal\t200' \
        "$(req_timing_stages 0.010 0.030 0.060 0.060 0.160 0.200)" "etapas de conexão segura"
    assert_eq $'DNS\t5\nTCP\t5\nEspera\t90\nDownload\t10\nTotal\t110' \
        "$(req_timing_stages 0.005 0.010 0.000 0.010 0.100 0.110)" "sem TLS em http"
    assert_eq $'DNS\t0\nTCP\t0\nEspera\t0\nDownload\t0\nTotal\t0' \
        "$(req_timing_stages 0 0 0 0 0 0)" "tudo zerado"
}

test_print() {
    echo "http: exibição"
    local out
    out=$(req_print_body application/json '{"a":1}'); assert_eq $'{\n  "a": 1\n}' "$out" "JSON identado"
    out=$(req_print_body text/plain 'olá'); assert_eq "olá" "$out" "texto cru"
    out=$(req_print_body text/html '<h1>x</h1>'); assert_eq "<h1>x</h1>" "$out" "HTML cru"
    out=$(req_print_body application/json '{quebrado'); assert_eq "{quebrado" "$out" "JSON inválido sai cru"
    out=$(req_print_body text/plain ''); assert_eq "(sem corpo)" "$out" "corpo vazio"
    out=$(COLUMNS=10 req_rule =); assert_eq "==========" "$out" "linha na largura do terminal"
    out=$(COLUMNS=5 req_rule -); assert_eq "-----" "$out" "linha com outro caractere"

    REQ_RESP_TIMES=(0.010 0.030 0 0.030 0.130 0.150)
    out=$(LC_ALL=C req_print_profile)
    assert_contains "DNS" "$out" "perfil lista DNS"
    assert_contains "Espera" "$out" "perfil lista espera"
    assert_contains "150 ms" "$out" "perfil mostra o total"
    [[ $out != *TLS* ]]; assert_eq "0" "$?" "perfil omite TLS em http"
    assert_contains "#" "$out" "barra ASCII fora de UTF-8"
}

start_server() {
    command -v python3 >/dev/null 2>&1 || return 1
    python3 -I "$ROOT/tests/mock_server.py" >"$TMP/port" 2>/dev/null &
    SERVER_PID=$!
    local i
    for i in {1..50}; do
        [[ -s $TMP/port ]] && { PORT=$(<"$TMP/port"); return 0; }
        sleep 0.1
    done
    return 1
}

test_execute() {
    echo "http: execução (mock local)"
    if ! start_server; then
        echo "  skip python3 indisponível ou servidor não iniciou"
        return
    fi
    local base=http://127.0.0.1:$PORT out

    req_execute "{\"method\":\"GET\",\"url\":\"$base/x\",\"query\":{\"q\":\"a b\"},\"headers\":{\"X-Test\":\"ola\"}}"
    assert_eq "0" "$?" "GET executa"
    assert_eq "200" "$REQ_RESP_STATUS" "status 200"
    assert_eq "application/json" "$REQ_RESP_CTYPE" "content-type"
    assert_eq "GET" "$(jq -r .method <<<"$REQ_RESP_BODY")" "método chegou ao servidor"
    assert_eq "a b" "$(jq -r '.query.q[0]' <<<"$REQ_RESP_BODY")" "querystring chegou decodificada"
    assert_eq "ola" "$(jq -r .x_test <<<"$REQ_RESP_BODY")" "header chegou"
    assert_eq "6" "${#REQ_RESP_TIMES[@]}" "seis tempos capturados"

    req_execute "{\"method\":\"POST\",\"url\":\"$base/p\",\"headers\":{\"Content-Type\":\"application/json\"},\"data_parameter\":{\"a\":1}}"
    assert_eq '{"a":1}' "$(jq -r .body <<<"$REQ_RESP_BODY")" "POST com corpo JSON"

    req_execute "{\"method\":\"PUT\",\"url\":\"$base/p\",\"data_parameter\":{\"k\":\"v 1\"}}"
    # Versões do curl divergem: espaço sai como %20 ou +; ambos são válidos.
    out=$(jq -r .body <<<"$REQ_RESP_BODY")
    [[ $out == "k=v%201" || $out == "k=v+1" ]]; assert_eq "0" "$?" "PUT com formulário url-encoded"
    assert_contains "x-www-form-urlencoded" "$(jq -r .content_type <<<"$REQ_RESP_BODY")" "content-type do formulário"

    req_execute "{\"method\":\"PATCH\",\"url\":\"$base/p\",\"data_parameter\":{\"f\":\"@/etc/hostname\"}}"
    assert_eq "PATCH" "$(jq -r .method <<<"$REQ_RESP_BODY")" "PATCH chega ao servidor"
    out=$(jq -r .body <<<"$REQ_RESP_BODY")
    [[ $out == f=%40* ]]; assert_eq "0" "$?" "@ no valor é enviado literal, sem ler arquivo"

    req_execute "{\"method\":\"DELETE\",\"url\":\"$base/d\",\"data_parameter\":{\"a\":1}}"
    assert_eq "DELETE" "$(jq -r .method <<<"$REQ_RESP_BODY")" "DELETE chega ao servidor"
    assert_eq "" "$(jq -r .body <<<"$REQ_RESP_BODY")" "DELETE não envia corpo"

    req_execute "{\"method\":\"DELETE\",\"url\":\"$base/status/404\"}"
    assert_eq "404" "$REQ_RESP_STATUS" "DELETE com status 404"

    req_execute "{\"method\":\"GET\",\"url\":\"$base/empty\"}"
    assert_eq "204" "$REQ_RESP_STATUS" "204"; assert_eq "" "$REQ_RESP_BODY" "sem corpo"

    req_execute '{"method":"GET","url":"http://127.0.0.1:1/"}' 2>/dev/null
    assert_eq "7" "$?" "conexão recusada devolve código do curl"

    echo "http: req_run_request"
    req_request_write "$TMP" users GET "$base/text" >/dev/null
    out=$(NO_COLOR=1 COLUMNS=20 req_run_request "$TMP/users.get.json" 2>&1)
    assert_eq "0" "$?" "run termina com sucesso"
    assert_contains "GET $base/text" "$out" "mostra método e url"
    assert_contains "HTTP 200" "$out" "mostra status"
    assert_contains "olá texto" "$out" "mostra o corpo"
    assert_contains "Tempo" "$out" "mostra o perfil"
    assert_eq "====================" "$(tail -n 1 <<<"$out")" "termina com separador"
    assert_eq "" "$(find "$TMP" -newer "$TMP/port" -type f ! -name 'users.get.json' ! -name 'port')" "nenhum arquivo extra gravado"

    printf '{"name":"nourl","method":"GET"}\n' >"$TMP/nourl.get.json"
    out=$(req_run_request "$TMP/nourl.get.json" 2>&1); assert_eq "1" "$?" "request sem url falha"
    assert_contains '"url"' "$out" "orienta a definir a url"
    out=$(req_run_request "$TMP/inexistente.get.json" 2>&1); assert_eq "1" "$?" "arquivo inexistente falha"
}

test_url
test_args
test_timing
test_print
test_execute
test_summary
