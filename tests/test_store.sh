#!/usr/bin/env bash
# Testes de lib/store.sh.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/tests/helpers.sh"
source "$ROOT/lib/core.sh"
source "$ROOT/lib/store.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# check_out <arquivo> - saída (stderr) de req_request_check.
check_out() { req_request_check "$1" 2>&1; }

test_names() {
    echo "store: nomes e arquivos"
    assert_eq "login.post.json" "$(req_request_filename login POST)" "nome de arquivo com método minúsculo"
    assert_eq "listar-usuarios.patch.json" "$(req_request_filename listar-usuarios PATCH)" "slug com hífen e PATCH"
    assert_eq $'login\tPOST' "$(req_parse_filename /x/login.post.json)" "extrai nome e método"
    assert_eq $'api-v2\tPATCH' "$(req_parse_filename api-v2.patch.json)" "slug com número"
    req_parse_filename notes.json >/dev/null;        assert_eq "1" "$?" "rejeita sem método"
    req_parse_filename x.head.json >/dev/null;       assert_eq "1" "$?" "rejeita método não suportado"
    req_parse_filename .get.json >/dev/null;         assert_eq "1" "$?" "rejeita nome vazio"
    req_parse_filename Login.get.json >/dev/null;    assert_eq "1" "$?" "rejeita maiúsculas"
    req_parse_filename api.v2.get.json >/dev/null;   assert_eq "1" "$?" "rejeita ponto no nome"
    req_parse_filename meu_nome.get.json >/dev/null; assert_eq "1" "$?" "rejeita underscore"
    local n
    for n in "a/b" ".x" "-x" "x-" "a--b" "A" "a b" ""; do
        req_valid_name "$n"; assert_eq "1" "$?" "slug inválido: \"$n\""
    done
    for n in ok a1 listar-usuarios v2-login; do
        req_valid_name "$n"; assert_eq "0" "$?" "slug válido: \"$n\""
    done
    for n in GET post Put patch DELETE; do
        req_valid_method "$n"; assert_eq "0" "$?" "método válido: $n"
    done
}

test_write_read() {
    echo "store: gravação e leitura"
    local d=$TMP/w out
    mkdir -p "$d"
    out=$(req_request_write "$d" users GET http://x/users)
    assert_eq "$d/users.get.json" "$out" "devolve o caminho criado"
    assert_eq "0" "$(check_out "$d/users.get.json"; echo $?)" "request gerada é válida"
    assert_eq "GET" "$(req_request_get "$d/users.get.json" method)" "lê method"
    assert_eq "users" "$(req_request_get "$d/users.get.json" name)" "lê name"
    assert_eq "http://x/users" "$(req_request_get "$d/users.get.json" url)" "lê url"
    assert_eq "" "$(req_request_get "$d/users.get.json" description)" "description vazia"
    assert_eq "{}" "$(req_request_get "$d/users.get.json" headers)" "headers vazio"

    req_request_write "$d" create-user patch http://x/u \
        '{"description":"atualiza","headers":{"Content-Type":"application/json","X-N":5},"data_parameter":{"a":1,"b":true}}' >/dev/null
    assert_eq "PATCH" "$(req_request_get "$d/create-user.patch.json" method)" "method normalizado em maiúsculas"
    assert_eq "atualiza" "$(req_request_get "$d/create-user.patch.json" description)" "grava description"
    assert_eq '{"Content-Type":"application/json","X-N":5}' "$(req_request_get "$d/create-user.patch.json" headers)" "grava headers"
    assert_eq '{"a":1,"b":true}' "$(req_request_get "$d/create-user.patch.json" data_parameter)" "grava data_parameter"
    assert_eq "" "$(ls -A "$d" | grep '^\.req\.')" "sem arquivos temporários"

    out=$(req_request_write "$d" x GET http://x '{"name":"outro","url":"http://outra"}' 2>&1)
    assert_eq "http://x" "$(req_request_get "$d/x.get.json" url)" "argumentos prevalecem sobre o json"
    assert_eq "x" "$(req_request_get "$d/x.get.json" name)" "name segue o argumento"

    out=$(req_request_write "$d" bad GET http://x '{oops' 2>&1); assert_eq "1" "$?" "JSON inválido não é gravado"
    assert_contains "inválido" "$out" "erro indica JSON inválido"
    [[ ! -e $d/bad.get.json ]]; assert_eq "0" "$?" "arquivo não foi criado"

    out=$(req_request_write "$d" bad2 GET http://x '{"headers":{"X":[1]}}' 2>&1)
    assert_eq "1" "$?" "campo com tipo errado não é gravado"
    assert_contains "header \"X\"" "$out" "erro cita o header"
    [[ ! -e $d/bad2.get.json ]]; assert_eq "0" "$?" "arquivo inválido não foi criado"
    assert_eq "" "$(ls -A "$d" | grep '^\.req\.')" "sem temporários após falha"

    out=$(req_request_write "$d" "Meu Nome" GET http://x 2>&1);  assert_eq "1" "$?" "nome fora do slug é recusado"
    assert_contains "slug" "$out" "erro orienta o slug"
    req_request_write "$d" x HEAD http://x >/dev/null 2>&1;      assert_eq "1" "$?" "método inválido é recusado"
    out=$(req_request_write "$d" x GET "" 2>&1);                 assert_eq "1" "$?" "url vazia é recusada"
    assert_contains "url" "$out" "erro cita a url"
    req_request_write "$TMP/nao-existe" x GET http://x >/dev/null 2>&1; assert_eq "1" "$?" "diretório inexistente é recusado"
}

test_invalid_manual() {
    echo "store: JSON alterado manualmente"
    local d=$TMP/m out before after
    mkdir -p "$d"
    printf '{"name": "a" "method": "GET"}\n' >"$d/a.get.json"
    before=$(cat "$d/a.get.json")
    out=$(check_out "$d/a.get.json"); assert_eq "1" "$(req_request_check "$d/a.get.json" 2>/dev/null; echo $?)" "sintaxe inválida falha"
    assert_contains "a.get.json" "$out" "erro cita o arquivo"
    assert_contains "JSON inválido" "$out" "erro cita JSON inválido"
    after=$(cat "$d/a.get.json")
    assert_eq "$before" "$after" "arquivo não foi alterado"

    printf '{"name":"b","method":"GET","url":"http://x","headers":[],"query":"x"}\n' >"$d/b.get.json"
    out=$(check_out "$d/b.get.json")
    assert_contains '"headers" deve ser um objeto' "$out" "headers com tipo errado"
    assert_contains '"query" deve ser um objeto' "$out" "query com tipo errado"

    printf '{"name":"c","method":"POST","url":"http://x"}\n' >"$d/c.get.json"
    assert_contains "difere do nome do arquivo" "$(check_out "$d/c.get.json")" "método diverge do arquivo"

    printf '{"name":"outro","method":"GET","url":"http://x"}\n' >"$d/d.get.json"
    out=$(check_out "$d/d.get.json")
    assert_contains '"name" ("outro") difere do nome do arquivo ("d")' "$out" "name diverge do arquivo"

    printf '{"method":"GET","url":"http://x"}\n' >"$d/e.get.json"
    assert_contains '"name" obrigatório' "$(check_out "$d/e.get.json")" "name ausente"

    printf '{"name":"f","method":"GET"}\n' >"$d/f.get.json"
    assert_contains '"url" obrigatório' "$(check_out "$d/f.get.json")" "url ausente"
    printf '{"name":"f2","method":"GET","url":""}\n' >"$d/f2.get.json"
    assert_contains '"url" obrigatório' "$(check_out "$d/f2.get.json")" "url vazia"
    printf '{"name":"f3","method":"GET","url":42}\n' >"$d/f3.get.json"
    assert_contains '"url" obrigatório' "$(check_out "$d/f3.get.json")" "url com tipo errado"

    printf '[]\n' >"$d/g.get.json"
    assert_contains "raiz deve ser um objeto" "$(check_out "$d/g.get.json")" "raiz não objeto"

    printf '{"name":"h","method":"GET","url":"http://x"}\n' >"$d/h.get.json"
    check_out "$d/h.get.json"; assert_eq "0" "$(req_request_check "$d/h.get.json" 2>/dev/null; echo $?)" "campos opcionais podem faltar"

    printf '{"name":"i","method":"HEAD","url":"http://x"}\n' >"$d/i.get.json"
    assert_contains 'método "HEAD" não suportado' "$(check_out "$d/i.get.json")" "método fora da lista"

    printf '{"name":"Bad Name","method":"GET","url":"http://x"}\n' >"$d/j.get.json"
    assert_contains "slug" "$(check_out "$d/j.get.json")" "name fora do slug"

    printf '{"name":"k","method":"GET","url":"http://x","descricao":"x","timeout":5}\n' >"$d/k.get.json"
    out=$(check_out "$d/k.get.json")
    assert_contains 'campo desconhecido "descricao"' "$out" "campo desconhecido é invalidado"
    assert_contains 'campo desconhecido "timeout"' "$out" "outro campo desconhecido"

    printf '{"name":"l","method":"POST","url":"http://x","data_string":"x"}\n' >"$d/l.post.json"
    assert_contains '"data_string" ainda não é suportado' "$(check_out "$d/l.post.json")" "data_string reservado"

    printf '{"name":"m","method":"GET","url":"http://x","description":5}\n' >"$d/m.get.json"
    assert_contains '"description" deve ser texto' "$(check_out "$d/m.get.json")" "description com tipo errado"

    printf '{"name":"n","method":"GET","url":"http://x","headers":{"X-A":{"b":1},"X B":"v","X-C":"a\\nb","X-D":null}}\n' >"$d/n.get.json"
    out=$(check_out "$d/n.get.json")
    assert_contains 'header "X-A": o valor deve ser' "$out" "header com valor objeto"
    assert_contains 'header "X B": nome inválido' "$out" "header com nome inválido"
    assert_contains 'header "X-C": o valor não pode conter quebra de linha' "$out" "header com quebra de linha"
    assert_contains 'header "X-D": o valor deve ser' "$out" "header com valor nulo"

    printf '{"name":"o","method":"GET","url":"http://x","headers":{"X-A":"v","X-N":1,"X-B":true},"query":{"a":1,"b":"c","d":false}}\n' >"$d/o.get.json"
    assert_eq "0" "$(req_request_check "$d/o.get.json" 2>/dev/null; echo $?)" "headers e query com valores simples são válidos"

    printf '{"name":"p","method":"POST","url":"http://x","data_parameter":{"a":{"b":1},"c":[1]}}\n' >"$d/p.post.json"
    out=$(check_out "$d/p.post.json")
    assert_contains 'data_parameter "a": o valor deve ser' "$out" "data_parameter com objeto"
    assert_contains 'data_parameter "c": o valor deve ser' "$out" "data_parameter com lista"

    printf '{"name":"q","method":"GET","url":"http://x"}\n' >"$d/Q Nome.get.json"
    assert_contains "fora do padrão" "$(check_out "$d/Q Nome.get.json")" "arquivo fora do padrão"
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
    printf '{}\n' >"$d/Maiuscula.get.json"
    req_request_write "$d" beta POST http://x >/dev/null
    req_request_write "$d" alpha GET http://x >/dev/null
    req_request_write "$d" alpha DELETE http://x >/dev/null
    req_request_write "$d" alpha PATCH http://x >/dev/null
    out=$(req_list_dir "$d")
    assert_eq "$(printf 'd\talfa\t%s/alfa\nd\tzeta\t%s/zeta\nr\talpha\tDELETE\t%s/alpha.delete.json\nr\talpha\tGET\t%s/alpha.get.json\nr\talpha\tPATCH\t%s/alpha.patch.json\nr\tbeta\tPOST\t%s/beta.post.json' "$d" "$d" "$d" "$d" "$d" "$d")" \
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
