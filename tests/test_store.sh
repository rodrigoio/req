#!/usr/bin/env bash
# Testes de lib/store.sh.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/tests/helpers.sh"
source "$ROOT/lib/core.sh"
source "$ROOT/lib/store.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

test_names() {
    echo "store: nomes e arquivos"
    assert_eq "login.post.json" "$(req_request_filename login POST)" "nome de arquivo com método minúsculo"
    assert_eq $'login\tPOST' "$(req_parse_filename /x/login.post.json)" "extrai nome e método"
    assert_eq $'api.v2\tGET' "$(req_parse_filename api.v2.get.json)" "nome com ponto"
    req_parse_filename notes.json >/dev/null;       assert_eq "1" "$?" "rejeita sem método"
    req_parse_filename x.patch.json >/dev/null;     assert_eq "1" "$?" "rejeita método não suportado"
    req_parse_filename .get.json >/dev/null;        assert_eq "1" "$?" "rejeita nome vazio"
    req_valid_name "a/b";   assert_eq "1" "$?" "nome com barra é inválido"
    req_valid_name ".x";    assert_eq "1" "$?" "nome oculto é inválido"
    req_valid_name "ok";    assert_eq "0" "$?" "nome simples é válido"
}

test_write_read() {
    echo "store: gravação e leitura"
    local d=$TMP/w out
    mkdir -p "$d"
    out=$(req_request_write "$d" users GET)
    assert_eq "$d/users.get.json" "$out" "devolve o caminho criado"
    assert_eq "0" "$(req_request_check "$d/users.get.json" 2>&1; echo $?)" "request gerada é válida"
    assert_eq "GET" "$(req_request_get "$d/users.get.json" method)" "lê method"
    assert_eq "users" "$(req_request_get "$d/users.get.json" name)" "lê name"
    assert_eq "{}" "$(req_request_get "$d/users.get.json" headers)" "headers vazio"

    req_request_write "$d" create post '{"headers":{"Content-Type":"application/json"},"data_string":"{\"a\":1}"}' >/dev/null
    assert_eq '{"Content-Type":"application/json"}' "$(req_request_get "$d/create.post.json" headers)" "grava headers"
    assert_eq '{"a":1}' "$(req_request_get "$d/create.post.json" data_string)" "grava data_string"
    assert_eq "POST" "$(req_request_get "$d/create.post.json" method)" "method normalizado em maiúsculas"
    assert_eq "" "$(ls -A "$d" | grep '^\.req\.')" "sem arquivos temporários"

    out=$(req_request_write "$d" bad GET '{oops' 2>&1); assert_eq "1" "$?" "JSON inválido não é gravado"
    assert_contains "inválido" "$out" "erro indica JSON inválido"
    [[ ! -e $d/bad.get.json ]]; assert_eq "0" "$?" "arquivo não foi criado"
    req_request_write "$d" "a/b" GET >/dev/null 2>&1; assert_eq "1" "$?" "nome inválido é recusado"
    req_request_write "$d" x PATCH >/dev/null 2>&1;   assert_eq "1" "$?" "método inválido é recusado"
    req_request_write "$TMP/nao-existe" x GET >/dev/null 2>&1; assert_eq "1" "$?" "diretório inexistente é recusado"
}

test_invalid_manual() {
    echo "store: JSON alterado manualmente"
    local d=$TMP/m out before after
    mkdir -p "$d"
    printf '{"name": "a" "method": "GET"}\n' >"$d/a.get.json"
    before=$(cat "$d/a.get.json")
    out=$(req_request_check "$d/a.get.json" 2>&1); assert_eq "1" "$?" "sintaxe inválida falha"
    assert_contains "a.get.json" "$out" "erro cita o arquivo"
    assert_contains "JSON inválido" "$out" "erro cita JSON inválido"
    after=$(cat "$d/a.get.json")
    assert_eq "$before" "$after" "arquivo não foi alterado"

    printf '{"name":"b","method":"GET","headers":[],"query":"x"}\n' >"$d/b.get.json"
    out=$(req_request_check "$d/b.get.json" 2>&1)
    assert_contains '"headers" deve ser objeto' "$out" "headers com tipo errado"
    assert_contains '"query" deve ser objeto' "$out" "query com tipo errado"

    printf '{"name":"c","method":"POST"}\n' >"$d/c.get.json"
    out=$(req_request_check "$d/c.get.json" 2>&1)
    assert_contains "difere do nome do arquivo" "$out" "método diverge do arquivo"

    printf '{"method":"GET"}\n' >"$d/e.get.json"
    out=$(req_request_check "$d/e.get.json" 2>&1)
    assert_contains '"name" obrigatório' "$out" "name ausente"

    printf '[]\n' >"$d/f.get.json"
    out=$(req_request_check "$d/f.get.json" 2>&1)
    assert_contains "raiz deve ser um objeto" "$out" "raiz não objeto"

    printf '{"name":"g","method":"GET"}\n' >"$d/g.get.json"
    req_request_check "$d/g.get.json" 2>&1; assert_eq "0" "$?" "campos opcionais podem faltar"
}

test_project() {
    echo "store: arquivo .req"
    local p=$TMP/proj out
    mkdir -p "$p/api" "$p/auth" "$p/vazio"
    printf '# projeto\napi\n\n  auth/  \n' >"$p/.req"
    assert_eq "$p/.req" "$(req_project_find "$p")" "encontra o .req"
    req_project_find "$p/api" >/dev/null; assert_eq "1" "$?" "sem .req no diretório"
    assert_eq "$p/api"$'\n'"$p/auth" "$(req_project_dirs "$p/.req")" "lista diretórios, ignora comentários e espaços"

    printf 'api\nfantasma\r\n' >"$p/.req"
    out=$(req_project_dirs "$p/.req" 2>&1); assert_contains "fantasma" "$out" "avisa diretório inexistente"
    assert_contains "$p/api" "$out" "mantém os existentes"
    req_project_dirs "$p/.req" >/dev/null 2>&1; assert_eq "1" "$?" "status 1 com entrada inexistente"
    req_project_dirs "$p/nada" >/dev/null 2>&1;  assert_eq "1" "$?" ".req inexistente"
}

test_list() {
    echo "store: listagem"
    local d=$TMP/l out
    mkdir -p "$d/zeta" "$d/alfa" "$d/.oculto"
    : >"$d/readme.md"
    printf '{}\n' >"$d/notes.json"
    req_request_write "$d" beta POST >/dev/null
    req_request_write "$d" alpha GET >/dev/null
    req_request_write "$d" alpha DELETE >/dev/null
    out=$(req_list_dir "$d")
    assert_eq "$(printf 'd\talfa\t%s/alfa\nd\tzeta\t%s/zeta\nr\talpha\tDELETE\t%s/alpha.delete.json\nr\talpha\tGET\t%s/alpha.get.json\nr\tbeta\tPOST\t%s/beta.post.json' "$d" "$d" "$d" "$d" "$d")" \
        "$out" "diretórios primeiro, requests depois, ordenados; ignora ocultos e fora do padrão"
    out=$(req_list_dir "$TMP/nao-existe" 2>&1); assert_contains "inexistente" "$out" "diretório inexistente"
    mkdir -p "$TMP/vazio"
    assert_eq "" "$(req_list_dir "$TMP/vazio")" "diretório vazio"
}

test_names
test_write_read
test_invalid_manual
test_project
test_list
test_summary
