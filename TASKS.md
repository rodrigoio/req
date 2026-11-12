# Plano de tarefas — `req` (interactive request tool para terminal)

## Context
O `manifest` descreve o `req`: um utilitário interativo em bash + curl para cadastrar, navegar e disparar requisições HTTP, com persistência em arquivos JSON num diretório de projeto. O repositório está vazio (só `manifest`, `LICENSE`, `.gitignore`). Este plano organiza o manifest em fases incrementais, cada uma entregando uma estrutura ou feature verificável.

Nota: o `manifest` é local e não deve ser versionado; a linha `manifest` do `.gitignore` permanece.

## Decisões fechadas
- **Shell:** bash 4+. **Dependências:** apenas `curl` e `jq`.
- **Código:** organizado em funções, sem scripts procedurais soltos (boas práticas do manifest).
- **Ambientes:** troca interativa via `:env <nome>`.
- **Precedência:** variável de ambiente vence o arquivo de secrets.
- **Placeholder ausente:** `${chave}` sem valor gera erro amigável que indica ao usuário como proceder (arquivo e variável esperados, ex.: definir `DEV_URL` ou adicionar `url` em `~/.req/env/dev/secrets.json`); a requisição não é enviada.
- **JSON válido:** requests e secrets são sempre gravados como JSON válido. Se o usuário o invalidar manualmente, o `req` apenas indica o erro (arquivo e detalhe do jq), sem tentar corrigir nem sobrescrever.
- **Git:** `manifest` permanece no `.gitignore`.
- **Enter em duas etapas:** o 1º Enter em uma request abre os detalhes (url, params), o 2º dispara; Esc volta. Assim o usuário confere antes de executar.
- **Ambiente padrão:** `default`, usado quando `REQ_ENV` não está definido; troca em sessão via `:env <nome>`.
- **Secrets:** arquivo `~/.req/env/<env>/secrets.json` ou variáveis de ambiente com prefixo, `${url}` resolve para `DEV_URL` (ambiente `dev`, chave em maiúsculas).

## Fases

### Fase 0 — Fundação do projeto
- [x] T0.1 Layout: `bin/req` (entrypoint fino), `lib/*.sh` (módulos de funções), `tests/`.
- [x] T0.2 Checagem de dependências na inicialização (bash >= 4, curl, jq) com mensagem de erro clara.
- [x] T0.3 Módulo utilitário: cores ANSI (verde GET, azul POST, laranja PUT, vermelho DELETE), mensagens de erro, restauração do terminal (`trap`).
- [x] T0.4 README mínimo, manter `.gitignore` como está (ignora `manifest`), definir framework de testes (bats ou script próprio sem dependência).

### Fase 1 — Modelo de dados e persistência
- T1.1 Formato `<nome>.<method>.json` com campos `name`, `method`, `headers`, `query`, `data_parameter`, `data_string`.
- T1.2 Funções de leitura/escrita/validação do JSON via jq (o exemplo do manifest não tem vírgulas; o JSON gravado deve ser válido) e detecção de JSON inválido por edição manual, apenas reportando o erro.
- T1.3 Arquivo `.req` do projeto: lista de diretórios que compõem o projeto; parser e localização no diretório atual.
- T1.4 Listagem de um diretório distinguindo subdiretórios reais de arquivos de request.
- T1.5 Testes das funções de persistência e listagem.

### Fase 2 — Execução de requisições (núcleo curl)
- T2.1 Montar o comando curl a partir da request (url, querystring com encode, headers, body em `data_parameter` ou `data_string`).
- T2.2 Executar e exibir resposta no terminal sem gravar arquivos (stdout/pipe), com formatação para JSON, texto e HTML.
- T2.3 Perfil de tempo por etapa via `curl -w` (DNS, conexão, TLS, TTFB, total) exibido em barra horizontal por etapa.
- T2.4 Separador visual (`---` ou `===`) entre resultado e o menu remontado.
- T2.5 Testes com servidor local simples ou mock.

### Fase 3 — Navegação interativa
- T3.1 Loop infinito de menu: setas cima/baixo, Enter, Esc (captura de sequências de escape com `read -rsn`).
- T3.2 Menu raiz com os diretórios do `.req`; entrar em diretório lista subdiretórios e requests, com ícone/rótulo distinguindo cada um.
- T3.3 Tela de detalhes da request (url, params, headers); Enter dispara, Esc volta; na raiz Esc não faz nada.
- T3.4 Cores por método na listagem e nos detalhes.

### Fase 4 — Modo comando e gestão de requests
- T4.1 Entrada em modo comando com `:`; Esc cancela.
- T4.2 `:n` — wizard: nome e método, depois campos opcionais (header, querystring, parâmetros post/put/delete, body).
- T4.3 Wizard simplificado com presets de formato popular (headers para json, text, html).
- T4.4 `:e` — editar a request selecionada.
- T4.5 `:d` — duplicar a request selecionada e abrir edição.
- T4.6 `:q` — sair sem confirmação, restaurando o terminal.

### Fase 5 — Ambientes e secrets
- T5.1 Estrutura `~/.req/env/<env>/secrets.json` (gerado como JSON válido) e leitura via jq; JSON inválido apenas indica o erro.
- T5.2 Resolução via variável de ambiente com prefixo (`${url}` -> `DEV_URL`); variável precede arquivo.
- T5.3 Substituição de `${chave}` em url, headers, query e body; erro amigável para ausentes, orientando o usuário (variável ou chave no secrets.json).
- T5.4 `:env <nome>` troca o ambiente na sessão; ambiente ativo visível no cabeçalho do menu; validação de ambiente inexistente.
- T5.5 Mascaramento de secrets em logs e verbose.

### Fase 6 — Logs e verbose
- T6.1 Configuração global (`~/.req/config`) e local (no projeto) para habilitar logs; local sobrescreve global.
- T6.2 Gravação de requisição e resposta em arquivo de log com timestamp.
- T6.3 Modo verbose: parâmetros enviados (`>>`) e resultado (`<<`) no terminal.
- T6.4 Comando para alternar logs/verbose em sessão (ex.: `:log`, `:v`).

### Fase 7 — Portabilidade, qualidade e entrega
- T7.1 Validar em debian, centos e rhel (containers) com bash 4+.
- T7.2 shellcheck e revisão: tudo em funções, sem dependências extras.
- T7.3 Instalação (`install.sh` ou `make install`) e documentação de uso, formato de arquivos e ambientes.
- T7.4 Teste ponta a ponta do fluxo completo.

## Arquivos críticos (a criar)
`bin/req`, `lib/{core,ui,store,http,nav,cmd,env,log}.sh`, `tests/*`, `README.md`, `TASKS.md`.

## Verificação
Cada fase termina com seus testes passando e uma demonstração manual: Fase 2 dispara uma request real e mostra tempos; Fase 3 navega com setas/Enter/Esc; Fase 4 cria, edita e duplica requests geradas em disco; Fase 5 troca de ambiente com `:env` e resolve secrets; Fase 6 gera log e verbose com `>>`/`<<`; Fase 7 roda em containers debian/centos.
