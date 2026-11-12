# req

The interactive request tool for your terminal. Utilitário interativo em bash + curl para cadastrar, navegar e disparar requisições HTTP, com persistência em arquivos JSON.

> Em desenvolvimento. O plano de trabalho está em [TASKS.md](TASKS.md).

## Requisitos

- bash 4+
- curl
- jq

## Instalação

```sh
make install      # link simbólico em ~/.local/bin/req
make uninstall    # remove o link
```

Para instalar em outro lugar: `make install PREFIX=/usr/local` (ou `BINDIR=...`). Se o diretório não estiver no `PATH`, o `make install` avisa como adicioná-lo.

## Desenvolvimento

```sh
make test    # executa os testes
make lint    # shellcheck (se instalado) + verificação de sintaxe
make check   # lint + testes
```

## Uso

```sh
req run caminho/login.post.json   # executa uma request e mostra resposta e perfil de tempo
req --version
```

A resposta é exibida no terminal (JSON identado; texto e HTML como recebidos) e nada é gravado em disco. Variáveis opcionais: `REQ_TIMEOUT` (padrão 60s) e `REQ_CONNECT_TIMEOUT` (padrão 10s).

## Estrutura

```
bin/req        entrypoint fino (resolve o diretório e chama main)
lib/core.sh    dependências, erros e restauração do terminal
lib/ui.sh      cores ANSI e formatação por método HTTP
lib/store.sh   persistência de requests e arquivo .req
lib/http.sh    montagem do curl, execução, exibição e perfil de tempo
tests/         testes em bash puro (sem dependências; os de execução usam python3 para um servidor local e são pulados sem ele)
Makefile       test, lint, install e uninstall
```

Todo o código é organizado em funções dentro de `lib/`.

## Testes

```sh
make test   # equivale a tests/run.sh
```

Cada `tests/test_*.sh` é executado isoladamente; o runner falha se qualquer assert falhar.

## Formato dos arquivos

Cada request é um arquivo `<slug>.<método>.json` (métodos: GET, POST, PUT, PATCH, DELETE). O slug usa só minúsculas, números e hífens (ex.: `listar-usuarios`). O `name` no JSON é idêntico ao slug do arquivo e é o rótulo mostrado no menu.

```json
{
  "name": "login",
  "method": "POST",
  "url": "https://api.example.com/login",
  "description": "Autentica o usuário",
  "headers": {"Content-Type": "application/json"},
  "query": {},
  "data_parameter": {"user": "ana"}
}
```

- Obrigatórios: `name`, `method` e `url`. Opcionais: `description`, `headers`, `query` e `data_parameter`.
- `headers`, `query` e `data_parameter` são objetos de valores simples (texto, número ou booleano).
- `query` é anexada à url com url-encode.
- Corpo (enviado só em POST, PUT e PATCH): `data_parameter` é enviado como JSON quando o header `Content-Type` contém `json`, senão como formulário url-encoded.
- Campos desconhecidos ou com tipo errado invalidam a request.

Subdiretórios do projeto são diretórios reais.

O arquivo `.req` na raiz do projeto lista os diretórios que o compõem, um por linha, relativos ao próprio `.req`. Linhas em branco e iniciadas por `#` são ignoradas:

```
# projeto
api
auth
```

Arquivos JSON editados manualmente e inválidos não são corrigidos: o `req` apenas indica o erro.
