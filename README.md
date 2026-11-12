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
bin/req --version
```

## Estrutura

```
bin/req        entrypoint fino (resolve o diretório e chama main)
lib/core.sh    dependências, erros e restauração do terminal
lib/ui.sh      cores ANSI e formatação por método HTTP
lib/store.sh   persistência de requests e arquivo .req
tests/         testes em bash puro (sem dependências)
Makefile       test, lint, install e uninstall
```

Todo o código é organizado em funções dentro de `lib/`.

## Testes

```sh
make test   # equivale a tests/run.sh
```

Cada `tests/test_*.sh` é executado isoladamente; o runner falha se qualquer assert falhar.

## Formato dos arquivos

Cada request é um arquivo `<nome>.<método>.json` (métodos: GET, POST, PUT, DELETE):

```json
{
  "name": "login",
  "method": "POST",
  "headers": {"Content-Type": "application/json"},
  "query": {},
  "data_parameter": {},
  "data_string": ""
}
```

`name` e `method` são obrigatórios; os demais campos são opcionais. Subdiretórios do projeto são diretórios reais.

O arquivo `.req` na raiz do projeto lista os diretórios que o compõem, um por linha, relativos ao próprio `.req`. Linhas em branco e iniciadas por `#` são ignoradas:

```
# projeto
api
auth
```

Arquivos JSON editados manualmente e inválidos não são corrigidos: o `req` apenas indica o erro.
