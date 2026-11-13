# Plano de tarefas — `req` (interactive request tool para terminal)

## Context
O `manifest` descreve o `req`: um utilitário interativo em bash + curl para cadastrar, navegar e disparar requisições HTTP, com persistência em arquivos JSON num diretório de projeto. O repositório está vazio (só `manifest`, `LICENSE`, `.gitignore`). Este plano organiza o manifest em fases incrementais, cada uma entregando uma estrutura ou feature verificável.

**Escopo de uso (definição do projeto):** o `req` é, inicialmente, uma solução para ser usada fora do escopo de um projeto de desenvolvimento: o diretório do projeto `req` contém apenas coisas do `req` (requests e seus diretórios). Usá-lo na raiz de um repositório de código não é um objetivo, e por isso o menu lista tudo o que não for oculto no diretório de trabalho, sem filtros nem lista de ignorados. Quando houver outros conteúdos na pasta, a variável `workspace` do `.req` (R11) aponta o subdiretório que o `req` enxerga.

## Estado atual (para retomar)
- Feito: Fases 0 a 4, a T5.1, as Revisões 1 (TR.1 a TR.13 e TR.15; a TR.14 segue adiada até o usuário decidir), 2 (TR2.1 a TR2.10) e 3 (TR3.1 a TR3.7). Próxima tarefa: **T6.2** (Fase 6; a T6.1 está feita; a Fase 5 está concluída, com a T5.7 descartada).
- Ordem combinada: a Fase 6 segue, pois a Fase 5 está concluída.
- Suíte: `make check` com 1153 asserts, 0 falhas, e `shellcheck` 0.9.0 limpo em `bin/`, `lib/` e `tests/` (`make lint`).
- Pendências ainda não confirmadas estão na seção "Adicionais" (TA.2 a TA.13), antes da Fase 8.
- Arquitetura, convenções, armadilhas já encontradas e a lista de pontos de navegação a validar com usuários estão em `DEVELOPMENT.md` (em inglês). Achados das validações entram aqui como novas tarefas.

## Decisões fechadas
- **Shell:** bash 4+. **Dependências:** apenas `curl` e `jq`.
- **Código:** organizado em funções, sem scripts procedurais soltos (boas práticas do manifest).
- **Ambientes:** troca interativa via `:env <nome>`.
- **Configuração local por padrão (decidido):** assume-se que o usuário trabalha e configura um projeto local; por isso toda configuração é do projeto (`projects/<id>/config`) e `:config chave=valor` grava ali. A global (`~/.req/config`) é a exceção e exige `-g`; a do projeto vence a global.
- **Precedência:** variável de ambiente vence o arquivo do ambiente, que vence as variáveis do projeto (ver "Controle central de projetos").
- **Placeholder ausente:** `${chave}` sem valor gera erro amigável que indica ao usuário como proceder (arquivo e variável esperados, ex.: definir `DEV_URL` ou adicionar `url=...` no arquivo do ambiente `dev` do projeto); a requisição não é enviada.
- **JSON válido:** as requests são sempre gravadas como JSON válido. Se o usuário o invalidar manualmente, o `req` apenas indica o erro (arquivo e detalhe do jq), sem tentar corrigir nem sobrescrever.
- **Git:** `manifest` permanece no `.gitignore`.
- **`.req` e `workspace` (R11, decidido):** o `.req` indica que o projeto foi inicializado no diretório e traz a variável `workspace` (formato `chave=valor`), o diretório de trabalho do `req`: um caminho relativo ao diretório do `.req` ou `.` (o próprio diretório, o padrão). O `req` só enxerga o `workspace`: a raiz do menu é ele e os diretórios são lidos dinamicamente, sem o mapeamento de linhas do `.req`; as linhas antigas são ignoradas, sem migração. Validação (confirmada pelo usuário): só caminho relativo válido, que existe, é um diretório e fica dentro do diretório do projeto; recusa caminho absoluto, `..` que saia do projeto e qualquer tipo de link (simbólico ou hard) no caminho. Assim a proteção do `:rm` continua valendo. Substitui o mapeamento das TR.9 a TR.13 (marcadas como feitas, mas parte do código sai na Revisão 3).
- **Raiz lista tudo (R11):** o menu lista todos os itens do `workspace` com o seu tipo (diretório ou request `.json`), e os comandos agem conforme o tipo do item sob o cursor. Isso fecha a TA.6: `:n` na raiz cria a request ali. **Comandos de item (decidido na TR3.5):** `:ed` abre o modo de edição para mudar o nome do diretório (só diretório; a request se edita com `:e`); `:cp` (antes `:c`) copia o diretório **ou** a request e já pergunta o novo nome, sem abrir a edição; `:rm` remove um ou outro.
- **`req init` (R11):** só grava o `.req` (com `workspace=.`), sem criar diretórios, e sugere ao usuário criar uma request: `Use :n to create a new request.`
- **Enter em duas etapas:** o 1º Enter em uma request abre os detalhes (url, params), o 2º dispara; Esc volta. Assim o usuário confere antes de executar.
- **Ambiente padrão:** `default`, usado quando `REQ_ENV` não está definido; troca em sessão via `:env <nome>`.
- **Campos da request:** obrigatórios `name`, `method` e `url` (a `url` pode usar `${chave}`); opcionais `description`, `headers`, `query`, `parameters` e `raw_data`. `parameters` é o novo nome de `data_parameter` (feito na TR.3).
- **Nome slug:** `name` é um slug (minúsculas, números e hífens, ex.: `listar-usuarios`), idêntico ao nome do arquivo (`<slug>.<método>.json`) e usado como rótulo no menu.
- **Validação estrita:** campo desconhecido ou com tipo errado invalida a request e é indicado ao usuário; o arquivo nunca é alterado.
- **Headers genéricos:** qualquer nome de header válido, com valor texto, número ou booleano.
- **Corpo (Revisão 1, vale a partir das TR.3 e TR.4):** enviado apenas em POST, PUT e PATCH (GET e DELETE não levam corpo). `parameters` são campos de formulário (chave e valor simples), sempre enviados url-encoded. `raw_data` é o corpo bruto: JSON nativo (objeto ou lista) quando o texto é JSON, string nos demais formatos; string vazia ou campo ausente significa sem corpo bruto. `raw_data` preenchido tem precedência sobre `parameters`. JSON sem header `Content-Type` sai com `application/json`; texto livre não ganha header automático.
- **Nomes antigos:** arquivos com `data_parameter` ou `data_string` não são migrados; a validação indica o nome novo.
- **Editor externo:** `raw_data` é editado no editor do usuário, como o git faz: `$VISUAL`, `$EDITOR`, `vim`, `vi`. Sem nenhum deles, vale um prompt de uma linha.
- **Comandos de diretório:** `:ed [nome]` renomeia e `:cp [nome]` (antes `:c`) copia com tudo dentro o diretório sob o cursor; o `:cp` vale também para request. `:rm` remove a request ou o diretório inteiro sob o cursor, sempre com confirmação `[y/N]`; para diretório o aviso é em vermelho e só se apaga dentro do projeto.
- **Ajuda:** `:h` lista todas as teclas e comandos; todo comando novo entra nela.
- **Erro de dependências:** só nomeia os pacotes faltantes, em laranja, sem comandos de instalação.
- **Métodos:** GET (verde), POST (azul), PUT (laranja), PATCH (marrom), DELETE (vermelho).
- **Variáveis (antes "secrets"):** arquivo `chave=valor` do ambiente do projeto (ver abaixo) ou variáveis de ambiente com prefixo; `${url}` resolve para `DEV_URL` (ambiente `dev`, chave em maiúsculas). O formato antigo `~/.req/env/<env>/secrets.json` (T5.1) é substituído pela TR2.4, sem migração.
- **Sem distinção de secrets, sem mascaramento (decidido):** as variáveis de cada projeto ficam isoladas fisicamente em `~/.req/projects/<id>/`, então todas valem como secretas e não há um tipo "secret" à parte, nem na interpolação nem nos nomes (`req_vars_load`, `REQ_VARS`). As requests enviadas e as respostas são do conhecimento de quem usa o `req`, então nada é mascarado: a url mostrada ao executar, o verbose e os logs trazem os valores reais. Isso descarta a T5.7.
- **Controle central de projetos (R10, a partir da TR2.1):** tudo que não é do repositório do usuário fica em `~/.req`, um diretório por projeto. Tudo é texto `chave=valor` (linhas em branco e `#` ignoradas), pois são só flags e variáveis simples. Layout (confirmado na TR2.2):
  ```
  ~/.req/
    current                  ponteiro: id do projeto em uso
    config                   configurações globais
    projects/<id>/
      project                name=... e path=... (diretório do .req)
      config                 configurações do projeto (vencem as globais)
      vars                   variáveis do projeto (valem em todos os ambientes)
      env/<ambiente>         variáveis do ambiente (vencem as do projeto)
      cursor                 última posição no menu (R8)
  ```
  O `<id>` é o slug do nome da pasta do projeto (minúsculas, números e hífens), com sufixo `-2`, `-3`... se já existir para outro caminho (confirmado com o usuário). O vínculo com o projeto é o `path` do arquivo `project`; `current` contém `project=<id>`.
- **Configuração (R9):** `:config` lista as chaves e `:config chave=valor` grava em `~/.req/config`; chaves conhecidas ficam numa tabela única (tipo, padrão, descrição), como a ajuda `:h`. Chave desconhecida ou valor inválido é recusado com mensagem.
- **Cursor (R8):** ao sair, o `req` grava o diretório e o item selecionado em `projects/<id>/cursor` e, ao abrir, volta para lá; a chave `restore_cursor` (padrão `yes`) desliga isso.
- **Tarefas prontas:** o que já está implementado conta como feito, sem nova validação; o trabalho segue apenas com o que falta.
- **Tamanho das tarefas (revisão):** cada tarefa entrega um único comportamento, em cerca de 100 a 200 linhas contando os testes, e vira um commit. Infraestrutura (helpers) entra em commit próprio, antes da feature que a usa. Cada tarefa leva só os testes do seu comportamento; os cenários integrados ficam numa tarefa de verificação no fim da fase. Se uma tarefa estourar o tamanho, ela é dividida antes de commitar.

## Fases

### Fase 0 — Fundação do projeto
- [x] T0.1 Layout: `bin/req` (entrypoint fino), `lib/*.sh` (módulos de funções), `tests/`.
- [x] T0.2 Checagem de dependências na inicialização (bash >= 4, curl, jq) com mensagem de erro clara.
- [x] T0.3 Módulo utilitário: cores ANSI (verde GET, azul POST, laranja PUT, vermelho DELETE), mensagens de erro, restauração do terminal (`trap`).
- [x] T0.4 README mínimo, manter `.gitignore` como está (ignora `manifest`), definir framework de testes (bats ou script próprio sem dependência).

### Extra — Makefile (feito antes da Fase 2)
- [x] `make test`, `make lint`, `make check`, `make install` e `make uninstall` (link simbólico em `~/.local/bin`, configurável via `PREFIX`/`BINDIR`).

### Extra — Inicialização e idioma (feito antes da Fase 4)
- [x] `req init` cria `.req` e `requests/`; sem `.req` no diretório, o modo interativo oferece inicializar o projeto (`[Y/n]`).
- [x] Todo o código, mensagens, comentários, testes e README foram traduzidos para o inglês (idioma único do projeto).
- `shellcheck` é só ferramenta de desenvolvimento (`make lint`), não é dependência de runtime.

### Fase 1 — Modelo de dados e persistência
- [x] T1.1 Formato `<nome>.<method>.json` com campos `name`, `method`, `url`, `headers`, `query`, `data_parameter`, `data_string` (`url` e `description` acrescentados; ver Decisões fechadas). PATCH incluído, na cor marrom; `data_string` removido por ora.
- [x] T1.2 Funções de leitura/escrita/validação do JSON via jq (o exemplo do manifest não tem vírgulas; o JSON gravado deve ser válido) e detecção de JSON inválido por edição manual, apenas reportando o erro.
- [x] T1.3 Arquivo `.req` do projeto: lista de diretórios que compõem o projeto; parser e localização no diretório atual.
- [x] T1.4 Listagem de um diretório distinguindo subdiretórios reais de arquivos de request.
- [x] T1.5 Testes das funções de persistência e listagem.

### Fase 2 — Execução de requisições (núcleo curl)
- [x] T2.1 Montar o comando curl a partir da request (url, querystring com encode, headers, body em `data_parameter` ou `data_string`).
- [x] T2.2 Executar e exibir resposta no terminal sem gravar arquivos (stdout/pipe), com formatação para JSON, texto e HTML.
- [x] T2.3 Perfil de tempo por etapa via `curl -w` (DNS, conexão, TLS, TTFB, total) exibido em barra horizontal por etapa.
- [x] T2.4 Separador visual (`---` ou `===`) entre resultado e o menu remontado.
- [x] T2.5 Testes com servidor local simples ou mock.

### Fase 3 — Navegação interativa
- [x] T3.1 Loop infinito de menu: setas cima/baixo, Enter, Esc (captura de sequências de escape com `read -rsn`).
- [x] T3.2 Menu raiz com os diretórios do `.req`; entrar em diretório lista subdiretórios e requests, com ícone/rótulo distinguindo cada um.
- [x] T3.3 Tela de detalhes da request (url, description, params, headers); Enter dispara, Esc volta; na raiz Esc não faz nada.
- [x] T3.4 Cores por método na listagem e nos detalhes.

### Fase 4 — Modo comando e gestão de requests e diretórios
- [x] T4.1 Helpers de entrada: `req_trim`, `req_prompt` (uma linha, com padrão) e `req_confirm` com padrão `[y/N]`.
- [x] T4.2 Modo comando: `:` abre o prompt no rodapé, digitação, Backspace, Esc cancela, comando vazio ou desconhecido mostra mensagem de status.
- [x] T4.3 `:q` sai sem pedir confirmação, restaurando o terminal.
- [x] T4.4 `req_project_add_dir`: cria o diretório e o lista no `.req` (função e testes, sem UI).
- [x] T4.5 `:nd [nome]` (alias `:mkdir`): na raiz cria e lista no `.req`; dentro de um diretório cria um subdiretório real; atualiza a lista e seleciona o novo.
- [x] T4.6 `:n` mínimo: pergunta nome (slug), método e url e cria a request no diretório atual; erro amigável na raiz.
- [x] T4.7 `:n` campos opcionais simples: description, querystring e parâmetros (só POST, PUT e PATCH).
- [x] T4.8 `:n` headers: presets json, text e html e pares `chave: valor`.
- [x] T4.9 `:e` campos simples: menu para name, method, url e description, com renomeio do arquivo e proteção contra sobrescrita.
- [x] T4.10 `:e` coleções: headers, query e parâmetros (par `chave=valor` define, `-chave` remove).
- [x] T4.11 `:d`: duplica a request selecionada e abre o menu de edição na cópia.
- [x] T4.13 Caminho absoluto em requests inválidas: a tela de detalhes e as mensagens de validação mostram o caminho completo, em linha própria e sem truncar, para copiar e corrigir em outro terminal.
- [x] T4.12 Verificação da fase: fluxo integrado pelo laço principal, demonstração em terminal real e seção de comandos no README.

### Revisão 1 — achados da validação de uso (antes da Fase 5)
Primeira sessão de uso real, em 2026-11-13. Os achados ficaram no arquivo local `reviews` (não versionado, como o `manifest`); o resumo abaixo é o registro no repositório. Ordem de execução: primeiro o que a revisão trata como obrigatório (R7, R5, R6), depois os casos raros de diretório (R2 a R4); o R1 foi adiado.

Achados:
- **R1** Ao executar, o resultado aparece acima dos dados da request; com resposta grande fica difícil comparar. Sugestão: dados da request acima, resposta abaixo.
- **R2** Não há como renomear um diretório existente. Sugestão: `:ed` com o diretório sob o cursor.
- **R3** Não há como duplicar um diretório com tudo dentro. Sugestão: `:c` com o diretório sob o cursor.
- **R4** Não há como remover um diretório, inclusive recursivamente. Sugestão: `:rm`, com aviso em vermelho e confirmação sim ou não.
- **R5** Falta um menu de ajuda com todas as opções: `:h`.
- **R6** Deve ser possível enviar um POST com JSON digitado pelo usuário, com a opção no menu de edição; havendo `vim` ou `vi`, chamar o editor no meio do programa, como o git, e voltar ao fluxo.
- **R7** O erro de dependências não deve trazer comandos `sudo` ou `install`; só indicar os pacotes faltantes em outra cor (laranja).

Tarefas:
- [x] TR.1 (R7) Erro de dependências: uma linha que só nomeia os pacotes faltantes, em laranja, sem `sudo` nem `install`.
- [x] TR.2 (R5) `:h` (alias `:help`): tela de ajuda com todas as teclas e comandos, a partir de uma tabela única; qualquer tecla volta. O aviso de comando desconhecido e os rodapés passam a apontar para `:h`.
- [x] TR.3 (R6) Renomear `data_parameter` para `parameters`, sem mudar o envio; o nome antigo vira erro de validação que indica o novo.
- [x] TR.4 (R6) `raw_data` no formato e no envio: objeto, lista ou string; precedência sobre `parameters`, que passa a ser sempre formulário url-encoded; JSON sem `Content-Type` sai com `application/json`.
- [x] TR.5 (R6) Tela de detalhes mostra o `raw_data` (JSON indentado ou texto, com teto de linhas) e avisa quando `parameters` não é enviado.
- [x] TR.6 (R6) Helper de editor externo (`req_editor`, `req_edit_text`): `$VISUAL`, `$EDITOR`, `vim`, `vi`, em arquivo temporário, como o git. Infraestrutura, commit próprio.
- [x] TR.7 (R6) Menu de edição: a opção `8) raw data` abre o editor com o JSON; JSON válido é gravado nativo, texto que não é JSON oferece editar de novo ou guardar como texto; sem editor, prompt de uma linha.
- [x] TR.8 (R6) `:n` com preset de formato (json, text, html) oferece o corpo bruto no editor em vez de pedir `parameters`.
- [x] TR.9 (R2 a R4) Helpers do `.req`: localizar, trocar, remover e acrescentar uma entrada, preservando comentários e ordem. Infraestrutura, commit próprio.
- [x] TR.10 (R2) `:ed [nome]` renomeia o diretório sob o cursor; na raiz atualiza a entrada do `.req`.
- [x] TR.11 (R3) `:c [nome]` (renomeado para `:cp` na TR3.5) copia o diretório sob o cursor com tudo dentro (padrão `<nome>-copy`); na raiz lista a cópia no `.req`.
- [x] TR.12 (R4, TA.1) `:rm` em request: confirmação `[y/N]` e remoção, na lista e na tela de detalhes; vale também para request inválida.
- [x] TR.13 (R4) `:rm` em diretório: aviso em vermelho com o caminho e a contagem do conteúdo, confirmação `[y/N]`, remoção recursiva só dentro do projeto; na raiz tira a entrada do `.req`.
- TR.14 (R1) **Adiada: confirmar com o usuário antes de implementar.** Ao executar, os dados da request ficam acima e a resposta abaixo. Desenho preferido para o rodapé: compacto (nome da request e teclas), com Enter executando de novo.
- [x] TR.15 Verificação da revisão: fluxo integrado pelo laço principal, demonstração em terminal real (pty) e revisão final do README e do `DEVELOPMENT.md`.

### Fase 5 — Ambientes e variáveis
Pré-requisito: TR2.1 a TR2.4 (Revisão 2, no fim do plano), que definem onde ficam os ambientes de cada projeto. As tarefas abaixo já estão ajustadas a isso.
- [x] T5.1 Leitura de `~/.req/env/<env>/secrets.json` via jq; JSON inválido apenas indica o erro. (Substituída pela TR2.4: o carregador passa a ler `chave=valor` do projeto.)
- [x] T5.2 Resolução de uma chave, em ordem de precedência: variável `<ENV>_<CHAVE>`, arquivo do ambiente (`projects/<id>/env/<ambiente>`), variáveis do projeto (`projects/<id>/vars`).
- [x] T5.3 Substituição de `${chave}` em um texto (função pura), com erro amigável que lista as chaves ausentes e orienta o usuário (variável esperada e arquivo do ambiente do projeto).
- [x] T5.4 Aplicar a substituição a url, headers, query, `parameters` e `raw_data` (incluindo as strings dentro do JSON nativo) antes de executar.
- [x] T5.5 Projeto e ambiente ativos (`REQ_ENV`, padrão `default`) exibidos no cabeçalho do menu.
- [x] T5.6 `:env <nome>` troca o ambiente na sessão e valida ambiente inexistente (arquivo em `projects/<id>/env/`); sem argumento lista os ambientes do projeto; entra na ajuda `:h`.
- ~~T5.7~~ Descartada (ver "Sem distinção de secrets, sem mascaramento"): o isolamento físico das variáveis por projeto dispensa o mascaramento. Em seu lugar, o código e os textos deixam de falar em "secrets" (`req_vars_load`, `REQ_VARS`).
- [x] T5.8 Verificação da fase (execução real com o mock server: `vars`, arquivo do ambiente e variável de processo, nessa precedência; chave faltante com erro amigável) e documentação dos ambientes e das variáveis de projeto no README.

### Fase 6 — Logs e verbose
- [x] T6.1 Configuração do projeto (`projects/<id>/config`) sobre a global (`~/.req/config`, criada na TR2.5), reaproveitando os helpers `chave=valor` e a tabela de chaves: precedência (a do projeto vence). Decidido com o usuário: por padrão assume-se que se trabalha e configura um projeto local, então `:config chave=valor` grava no projeto e `:config -g chave=valor` na global (sem projeto aberto, o padrão avisa e sugere `-g`). A única chave de log, por ora, é `log=yes|no` (padrão `no`); formato e nome do arquivo ficam fora.
- T6.2 Log da requisição enviada, com timestamp, em arquivo.
- T6.3 Log da resposta recebida, no mesmo arquivo.
- T6.4 Verbose: dados enviados (`parameters` ou `raw_data`) com `>>` no terminal.
- T6.5 Verbose: resposta (incluindo headers) com `<<` no terminal.
- T6.6 `:log` e `:v` alternam logs e verbose na sessão; entram na ajuda `:h`.
- T6.7 Verificação da fase e documentação.

### Fase 7 — Portabilidade, qualidade e entrega
- T7.1 Validação em container debian com bash 4+ (`make check`), incluindo o editor externo (`vi`), `cp -R`, `rm -rf` e `mktemp -d`.
- T7.2 Validação em containers centos e rhel, com os mesmos pontos.
- [x] T7.3 `shellcheck`: corrigir os avisos (feito: `make lint` limpo em `bin/`, `lib/` e `tests/`).
- T7.4 Documentação de uso.
- T7.5 Documentação do formato de arquivos (`parameters`, `raw_data`), do `.req` (`workspace`), do layout de `~/.req` (projetos, ambientes, variáveis, configuração, cursor) e dos ambientes.
- T7.6 Teste ponta a ponta do fluxo completo.

### Adicionais — pendências e ajustes pós-validação (antes da Fase 8)
Reúne o que ficou em aberto até aqui. As tarefas de navegação dependem das validações com usuários: confirmar a necessidade antes de implementar. O que uma validação confirma sai daqui e vira tarefa de uma seção de revisão (ver "Revisão 1"). Origem de cada ponto em `DEVELOPMENT.md`, seção "Open items to validate with users".
- ~~TA.1~~ Confirmada pela Revisão 1 (R4): virou as TR.12 (`:rm` em request) e TR.13 (`:rm` em diretório).
- TA.2 Mover request ou diretório para outro diretório (por exemplo `:mv`). Renomear diretório foi para a TR.10; renomear request segue pelo campo `name` do menu de edição.
- TA.3 Esc cancela os prompts dos assistentes (`:n`, `:e`, `:d`, `:nd`) e as confirmações novas (`:ed`, `:cp`, `:rm`). Hoje só nome vazio ou Ctrl-D cancelam.
- TA.4 Rever o Enter em duas etapas e a seleção que substitui a cor do método na linha destacada, conforme as validações (podem virar opção). A ordem entre request e resposta ao executar é a TR.14.
- TA.5 Histórico e Tab no modo comando.
- ~~TA.6~~ Decidida pela Revisão 3 (R11): a raiz é o `workspace` e lista requests e diretórios; `:n` na raiz cria a request (TR3.4).
- TA.7 Redimensionamento do terminal: o menu não trata `SIGWINCH`; verificar o redesenho e o apagamento ao redimensionar. Inclui telas mais altas que o terminal (ajuda, detalhes com `raw_data` longo).
- TA.8 Código de saída de `req run` para respostas 4xx e 5xx (hoje 0; só falha em erro de transporte). Decisão pendente.
- TA.9 Teste em pseudo-terminal dentro da suíte (init, navegação, `:n`, `:q` e a chamada do editor externo), hoje só feito à mão; requer `python3` e é pulado sem ele.
- TA.10 `REQ_ESC_TIMEOUT` (50 ms) em conexões lentas, como SSH: validar e documentar o ajuste.
- TA.11 Validar em terminais reais sem UTF-8 e com `NO_COLOR`; os fallbacks existem, mas só foram testados em teste automatizado.
- TA.12 Descrição com várias linhas na tela de detalhes (hoje as quebras viram espaço).
- TA.13 Decidir se o próprio `TASKS.md` é traduzido para inglês (pergunta em aberto desde a tradução do projeto).
- TA.14 Como escrever um `${chave}` literal (sem substituir) em uma request: hoje não há escape, então um texto como `${x}` sem valor definido é sempre um erro (T5.3). Opções: `$${x}`, uma barra antes, ou deixar sem escape. Decidir antes de a T5.4 ser usada com um `raw_data` que contenha esse trecho.

### Fase 8 — Extras (a detalhar ao final do projeto)
- T8.1 `timeout` por request.
- T8.2 `follow_redirects` por request.
- T8.3 `insecure` por request.
- ~~T8.4~~ Substituída pela TR.4: `raw_data` entra no lugar de `data_string`, com a regra de precedência sobre `parameters`.
- T8.5 Envio de arquivos.
- T8.6 Valores aninhados em `query`.
- ~~T8.7~~ Removida: JSON aninhado vai em `raw_data`; `parameters` fica plano (campos de formulário).

### Revisão 2 — achados da validação de uso (R8 a R10; ao final do plano)
Continuação do arquivo local `reviews` (R1 a R7 estão na Revisão 1). As TR2.1 a TR2.4 vêm antes da Fase 5.

Achados:
- **R8** Ao sair, a navegação recomeça na raiz. Sugestão: salvar a posição do cursor no diretório de configuração (`~/.req`) e retomar dela ao abrir o `req`.
- **R9** Falta um comando para editar configurações globais (apresentação e features futuras), por chave e valor: `:config time_stats=no`, `:config time_stat_total=yes`.
- **R10** Falta um controle central de projetos em `~/.req`: para cada projeto inicializado, um controle com seus próprios ambientes e variáveis; um arquivo ponteiro para o projeto em uso; um arquivo por ambiente, só `chave=valor`. Impacta a Fase 5 e a configuração da T6.1.

Tarefas (R10, antes da Fase 5):
- [x] TR2.1 (R10) Helpers de arquivo `chave=valor`: ler uma chave, listar, gravar e remover, preservando comentários, linhas em branco e ordem; nomes `[A-Za-z_][A-Za-z0-9_]*`, valores de uma linha. Infraestrutura, commit próprio.
- [x] TR2.2 (R10) Diretório central: helpers do layout (`~/.req` ou `REQ_CONFIG_DIR`, `projects/<id>/`, arquivo `project` com `name` e `path`), id do projeto a partir da pasta, e o ponteiro `current` (ler e gravar). Infraestrutura, commit próprio.
- [x] TR2.3 (R10) Registro do projeto: `req init` e a primeira abertura de um `.req` ainda não registrado criam o controle do projeto; abrir um projeto registrado atualiza `current`; se `~/.req` não for gravável, o menu segue funcionando e avisa uma vez.
- [x] TR2.4 (R10) Ambientes por projeto: o carregador de secrets (T5.1) lê `projects/<id>/env/<ambiente>` e `projects/<id>/vars` em `chave=valor`, com o ambiente vencendo as variáveis do projeto; `secrets.json` deixa de ser lido (sem migração; se o arquivo antigo existir, um aviso aponta o novo local).

Tarefas (R9):
- [x] TR2.5 (R9) Configuração global: `~/.req/config` em `chave=valor`, com a tabela única de chaves conhecidas (tipo, padrão, descrição) e leitura validada; chave desconhecida no arquivo é avisada e ignorada. Infraestrutura, commit próprio.
- [x] TR2.6 (R9) `:config`: sem argumento lista as chaves com valor atual e padrão; `:config chave=valor` valida e grava; chave desconhecida ou valor inválido explica e lista as válidas; entra na ajuda `:h`.
- [x] TR2.7 (R9) Chaves de apresentação `time_stats` (perfil de tempos) e `time_stat_total` (linha de total), `yes` ou `no`, padrão `yes`, aplicadas por `req_run_request` e por `req run`.

Tarefas (R8):
- [x] TR2.8 (R8) Gravar o cursor ao sair (`:q`, fim da entrada e sinais) em `projects/<id>/cursor`: diretório atual e item selecionado, relativos ao `workspace`, em `chave=valor`.
- [x] TR2.9 (R8) Retomar o cursor ao abrir: volta ao diretório e ao item (a pilha do Esc é refeita); diretório inexistente leva ao ancestral mais próximo, item inexistente ao primeiro; arquivo ausente ou inválido leva à raiz sem erro; a chave `restore_cursor` (padrão `yes`) desliga a retomada.
- [x] TR2.10 Verificação da Revisão 2: fluxo integrado pelo laço principal (sair e reabrir no mesmo lugar, `:config`, projeto registrado), demonstração em terminal real (pty) e revisão final do README e do `DEVELOPMENT.md`.

### Revisão 3 — achado R11 (executar agora, antes da TR2.4)
Continuação do arquivo local `reviews`.

Achado:
- **R11** Usar o `.req` do projeto só como referência de que o diretório foi inicializado, e carregar os diretórios dinamicamente, sem o mapeamento. Respostas do usuário: a raiz lista todos os itens e seus tipos e os comandos agem conforme o tipo; o `.req` terá a variável `workspace` (caminho relativo válido ou `.`), que deve constar na documentação; `req init` só inicializa o arquivo e sugere `:n`.

Tarefas:
- [x] TR3.1 (R11) Helper `req_project_workspace <.req>`: lê `workspace` pelos helpers `chave=valor` (padrão `.` quando ausente; linhas que não são `chave=valor`, como as entradas antigas, são ignoradas), valida e imprime o caminho físico. Regras: só caminho relativo, que existe e é um diretório dentro do projeto (sem `..` que saia dele, sem caminho absoluto), e nenhum componente do caminho pode ser link simbólico; links hard também são recusados (um diretório não aceita hard link em Linux, então a checagem prática é a de symlink, e um componente que não seja diretório regular é recusado). Erro amigável com o caminho absoluto do `.req` e o motivo. Infraestrutura, commit próprio.
- [x] TR3.2 (R11) `req init` e a inicialização oferecida pelo menu só gravam o `.req` (comentário e `workspace=.`), sem criar `requests/` (sai `REQ_PROJECT_DEFAULT_DIR`), e mostram `Use :n to create a new request.`; um `.req` existente continua sendo recusado. README: seção sobre o `.req` e a variável `workspace`.
- [x] TR3.3 (R11) Raiz dinâmica: a raiz do menu é o `workspace` e lista todos os itens (diretórios e requests, com o tipo) pelo `req_list_dir`; saem `REQ_NAV_ROOTS` e `req_project_dirs`. Um único ponto (`req_nav_root`) decide o diretório da raiz; o título e os caminhos relativos partem do `workspace`.
- [x] TR3.4 (R11, TA.6) Comandos na raiz: `:n` cria a request no `workspace`; `:nd` cria um diretório comum, sem tocar o `.req` (sai `req_project_add_dir`); o aviso "open a directory first" desaparece.
- [x] TR3.5 (R11) Comandos de item sem a lógica do `.req` (entrada listada, "fora do projeto", desinscrever), agindo sobre o item sob o cursor conforme o tipo: `:ed [nome]` renomeia o diretório (abre a pergunta do novo nome; em request avisa que a edição é o `:e`); `:cp [nome]` substitui o `:c` e copia diretório ou request pedindo logo o novo nome (padrão `<nome>-copy`), sem abrir a edição; `:rm` remove diretório ou request. O limite de segurança do `:rm` passa a ser o `workspace` (só dentro dele, nunca symlink: um link é recusado, não há mais "desinscrever"). Ajuda `:h` e documentação atualizadas; `:d` (duplicar e editar) continua como está.
- [x] TR3.6 (R11) Remover o código morto: helpers de entradas do `.req` (TR.9) e seus testes, mais ajustes nos testes que tratavam do mapeamento; `DEVELOPMENT.md` (itens 6 e 7 dos pontos a validar).
- [x] TR3.7 Verificação da Revisão 3: fluxo integrado pelo laço principal, demonstração em terminal real (pty) e revisão final do README e do `DEVELOPMENT.md` (a variável `workspace` documentada).

## Arquivos críticos (a criar)
`bin/req`, `lib/{core,ui,store,http,nav,cmd,wizard,env,home,log}.sh` (`home.sh`: `~/.req`, projetos, configuração e cursor), `tests/*`, `README.md`, `TASKS.md`.

## Verificação
Cada fase termina com seus testes passando e uma demonstração manual: Fase 2 dispara uma request real e mostra tempos; Fase 3 navega com setas/Enter/Esc; Fase 4 cria, edita e duplica requests geradas em disco; Revisão 1 mostra a ajuda `:h`, envia um POST com JSON editado no vim e renomeia, copia e remove diretórios conferindo o `.req`; Revisão 3 inicializa um `.req` com `workspace`, lista a raiz dinamicamente e opera sobre diretórios e requests na raiz; Revisão 2 registra um projeto em `~/.req`, muda uma configuração com `:config` e reabre o `req` no mesmo lugar; Fase 5 troca de ambiente com `:env` e resolve secrets; Fase 6 gera log e verbose com `>>`/`<<`; Fase 7 roda em containers debian/centos.
