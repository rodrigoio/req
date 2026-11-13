# Development notes

Handoff document: everything needed to pick the project up again without the
conversation history. User-facing documentation is in [README.md](README.md); the
roadmap and task status are in [TASKS.md](TASKS.md) (written in Portuguese).

## Status

| Phase | State |
|---|---|
| 0 Foundation, 1 Data model, 2 curl execution, 3 Navigation, 4 Command mode | done |
| 5 Environments and secrets | T5.1 done (loading `secrets.json`); T5.2 to T5.8 pending |
| 6 Logs and verbose, 7 Portability and delivery, 8 Extras | pending |

Next task: **T5.2** (resolve one key: the `<ENV>_<KEY>` variable takes precedence over the file).

Work rules agreed with the user (also in TASKS.md, "Decisões fechadas"):
- One task = one behavior, about 100 to 200 lines including tests, one commit.
  Helpers go in their own commit before the feature that uses them.
- What is already implemented counts as done; do not re-validate it.
- Everything in the repository is in English (code, messages, comments, tests,
  README). The conversation is in Portuguese, and so is TASKS.md.
- The `manifest` file is the user's and is git-ignored; never commit it.
- Nothing is committed by the assistant unless asked; the user commits.

## Architecture

`bin/req` is a thin entrypoint: it resolves its own directory (following symlinks),
sources the modules and dispatches (`req`, `req init`, `req run <file>`). Everything
else is functions in `lib/`, all prefixed `req_`.

| Module | Responsibility |
|---|---|
| `core.sh` | version, dependency checks, `req_err`/`req_die`, `req_trim`, `req_abs_path`, terminal restore and traps |
| `ui.sh` | colors (`req_color`), terminal size, `req_trunc`, `req_rule`, `req_confirm`, `req_prompt` |
| `store.sh` | request format and validation, writing, listing, `.req` project file, `req_project_init`/`req_project_add_dir` |
| `http.sh` | builds the curl command, runs it, prints the response and the timing profile |
| `nav.sh` | the interactive menu: state, screen building, keys, main loop, init prompt |
| `cmd.sh` | command mode (`:n :nd :e :d :q`) on top of `nav.sh` |
| `wizard.sh` | the prompts behind `:n`, `:e`, `:d` and `:nd` |
| `env.sh` | secrets loading (`REQ_SECRETS`, `REQ_CONFIG_DIR`); resolution and substitution come next |

Data flow of a run: `req_nav_run` loops build screen → draw → read key → handle key.
Running a request: `req_run_request` → `req_request_check` (validate) →
`req_build_curl_args` (one jq call) → `req_curl_exec` → print body and profile.

### Request file format

`<slug>.<method>.json` (GET, POST, PUT, PATCH, DELETE); `name` equals the slug and is
the menu label. Required: `name`, `method`, `url`. Optional: `description`, `headers`,
`query`, `data_parameter` (objects of simple values). Unknown or mistyped fields
invalidate the request; invalid files are reported, never rewritten. `data_string` is
reserved (Phase 8). The body is only sent with POST, PUT and PATCH.

## Conventions

- Functions return status codes; results travel in globals named `REQ_*`
  (`REQ_REPLY`, `REQ_LAST_FILE`, `REQ_SCREEN_LINES`, ...) because bash cannot return
  arrays or values without a subshell.
- Messages: `req_err "..."` for errors (always `req: error: ...` on stderr), plain
  `printf` for notices. Error messages about a file carry its **absolute path**.
- Names of requests, directories and environments are slugs (`^[a-z0-9]+(-[a-z0-9]+)*$`).
- Colors are decided **once** when `ui.sh` is loaded (`REQ_COLORS`). A per-call `-t 1`
  check breaks inside `$(...)`, where stdout is a pipe.
- The menu is redrawn in place: it erases the last block by moving the cursor up
  `REQ_SCREEN_DRAWN` rows. Never print inside the menu loop without
  `req_screen_erase` first. Lines that can wrap (the absolute path of an invalid
  request) must go through `req_screen_add_long` so the extra rows are counted.
- Outside a terminal nothing is erased and no colors are used, which is what the
  tests rely on.

## Testing

`make test` (or `tests/run.sh`) runs every `tests/test_*.sh` in its own bash; `make check`
adds `make lint`. Plain bash, no framework (`tests/helpers.sh`: `assert_eq`,
`assert_contains`, `test_summary`). 458 asserts at the time of writing.

- Helpers export `NO_COLOR=1`; tests that need colors set `REQ_COLORS=1` explicitly.
- Interactive flows are driven through `REQ_INPUT_FD`: tests set it to 3 and feed
  answers with `3<<<$'...'` (use `3</dev/null` for end of input; `<<<""` is an empty
  line, not EOF). The menu loop is fed by piping keys (`keys up down enter ...`).
- `tests/mock_server.py` is a local echo server (needs `python3`; those tests skip
  without it). It answers GET, POST, PUT, PATCH and DELETE.
- `REQ_CONFIG_DIR` points the configuration (`~/.req`) at a temp directory.
- A real terminal is not covered by the unit tests. The flows were verified by
  driving `bin/req` through a pty (`python3` + `pty.fork`). When doing that, always
  start the child in a scratch directory: without a `.req` the init prompt appears
  and answering it creates files.

## Gotchas found so far

- **jq 1.6**: `$label` is a reserved word; a syntax error in the input exits with a
  non-2 status (detect `parse error` in the message instead); every call costs
  about 55 ms on the development VM, so batch work into one call. Several modules
  do that by emitting `tag NUL value NUL` records and reading them with
  `read -r -d ''`, which also preserves newlines inside values.
- `read -s` restores echo between reads, so the menu session runs with `stty -echo`
  and the prompts switch it back on (`req_nav_prompt_begin` / `_end`).
- Esc versus arrow keys is told apart by waiting `REQ_ESC_TIMEOUT` (50 ms) for the
  rest of the sequence.
- curl: `--data-urlencode` encodes a space as `%20` or `+` depending on the version;
  the JSON body goes through stdin and the form uses `key=value` so a value starting
  with `@` is never read as a file.
- `make lint` runs `shellcheck` (0.9.0) over `bin/`, `lib/` and `tests/` and is clean.
  It runs without `-x` on purpose: no config file is needed, and each file is analysed
  on its own. For that reason, cross-module globals are not seen as used, so they carry
  `# shellcheck disable=SC2034` with the reason; a new global shared between modules
  needs the same. The jq programs are single-quoted on purpose
  (`SC2016` disabled where they are declared).
- Only tested with bash 5.2, jq 1.6 and a recent curl; CentOS/RHEL/Debian stable
  coverage is Phase 7.

## Open items to validate with users

The navigation was built from the manifest plus assumptions. These are the points
worth observing in usability sessions; each one is cheap to change.

1. **Enter in two steps**: Enter on a request opens the details and a second Enter
   runs it. Is the extra step welcome or annoying?
2. **Selection highlight** replaces the method color on the selected row (bold bright
   green). Is losing the method color on that row a problem?
3. **Up/Down wrap around** at the ends of a list.
4. **Esc** does nothing at the root and there is no key to quit besides `:q` and
   Ctrl-C. Esc does **not** cancel inside the wizard prompts (an empty name or Ctrl-D does).
5. **Command mode**: no tab completion or history; unknown commands only show a
   one-line status message; `:q` never asks for confirmation.
6. **No way to delete or rename a request or directory** from the menu (the manifest
   lists none). `:e` renames a request only by changing its name field. This is the
   most likely gap users will report.
7. **Requests cannot be created at the root**, only inside a directory (the root is
   the list of directories in `.req`). `:n` there explains it and suggests `:nd`.
8. **Directory names are slugs** (no uppercase, dots or underscores), same as requests.
9. **Edit menu** is numbered fields (`1`-`7`, `s`, `q`) and is redrawn after each
   field; long header/query sets are edited one `key: value` line at a time.
10. **Long lists and long names**: scrolling is by window and names are truncated with
    `…`; very long names or paths on narrow terminals deserve a look.
11. **Non-UTF-8 terminals** fall back to ASCII (`>`, `#`, `~`); worth a quick check.

Record findings as new tasks in the "Adicionais" section of TASKS.md rather than
changing behavior ad hoc; items 1, 2, 4, 5, 6, 7 and 11 above already have a task there (TA.1 to TA.6 and TA.11).

## Roadmap after T5.1

Phase 5: T5.2 key resolution, T5.3 pure `${key}` substitution with a friendly error
that lists the missing keys and tells how to fix them, T5.4 apply it to url, headers,
query and parameters, T5.5 active environment (`REQ_ENV`, default `default`) in the
menu header, T5.6 `:env <name>`, T5.7 secret masking helper, T5.8 verification and docs.
Environment variable names are `<ENV>_<KEY>` in upper case (`${url}` in `dev` is
`DEV_URL`); the variable wins over the file.
Then Phase 6 (logs, verbose with `>>` and `<<`), Phase 7 (portability, docs), the
"Adicionais" section of TASKS.md (TA.1 to TA.13: everything still open, mostly
navigation changes to confirm with users) and Phase 8 (per-request options,
`data_string`, nested values).
