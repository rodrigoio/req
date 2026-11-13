# Development notes

Handoff document: everything needed to pick the project up again without the
conversation history. User-facing documentation is in [README.md](README.md); the
roadmap and task status are in [TASKS.md](TASKS.md) (written in Portuguese).

## Status

| Phase | State |
|---|---|
| 0 Foundation, 1 Data model, 2 curl execution, 3 Navigation, 4 Command mode | done |
| Review 1, usability findings (TR.1 to TR.15) | pending; runs before Phase 5 resumes |
| 5 Environments and secrets | T5.1 done (loading `secrets.json`); T5.2 to T5.8 pending |
| 6 Logs and verbose, 7 Portability and delivery, 8 Extras | pending |

Next task: **TR.13** (`:rm` on a directory; TR.1 to TR.12 are done). Phase 5 resumes at T5.2 after TR.15. See
"Review 1 findings" below.

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
`query`, `parameters` (objects of simple values), `raw_data` (object, list or string). Unknown or mistyped fields
invalidate the request; invalid files are reported, never rewritten. The body is only
sent with POST, PUT and PATCH. A non-empty `raw_data` is the body and wins over
`parameters`, which are always an url-encoded form (TR.4). An object or list is sent as
compact JSON, with `Content-Type: application/json` only when the request has no
`Content-Type` header; a string is sent as it is with no automatic header (curl's
default one is removed with `-H "Content-Type:"`). The old names `data_parameter` and
`data_string` are validation errors that point to `parameters` and `raw_data`; files are
not migrated.

The details screen shows `raw_data` under "Raw data" (indented JSON, or the text as it is),
capped at `REQ_RAW_MAX_LINES` (15) lines with a "... (N more lines)" marker. `parameters`
is flagged "not sent" when `raw_data` takes precedence, and both are flagged with GET and DELETE.

External editor (`lib/core.sh`, TR.6): `req_editor` prints `$VISUAL`, `$EDITOR`, `vim` or `vi`
(first that exists; the variables may carry arguments, run through `sh -c`).
`req_edit_text <text> [suffix]` edits the text in `<tmpdir>/raw_data<suffix>` and fills
`REQ_EDIT_TEXT` (trailing line breaks removed). Status 0 edited, 1 the editor failed
(original text kept), 2 no editor (the caller falls back to a one-line prompt). The
caller hands the terminal over first (`req_nav_prompt_begin`); the helper does not.

Raw data editing (`req_ask_raw_data` in `lib/wizard.sh`, TR.7 and TR.8): the edit menu's `8)` opens
the text in the editor (`.json` suffix). An empty text removes the field; an object or list
is stored as native JSON; other text is stored as a string after a "1) edit again 2) keep as
text 3) discard" question, which is skipped when the request has a `Content-Type` without
`json` (the user is clearly writing text or html). `:n` reuses it: after a json, text or html
preset on POST, PUT or PATCH it asks "Write the body in your editor?" (default yes) and only
asks for `parameters` when declined; the JSON question applies to the json preset only.
Without an editor, a one-line prompt (`-` clears) is used. An editor that fails leaves the
field untouched. The wizard tests replace the editor with small `sh` scripts (`fake_editor`)
or override `req_editor`.

`.req` entry helpers (`lib/store.sh`, TR.9), for the directory commands: `req_project_has_entry`,
`req_project_append_entry`, `req_project_replace_entry` and `req_project_remove_entry` (both
through `req_project_rewrite`). An entry is matched by the directory it stands for
(relative or absolute, with or without a trailing slash, paths normalized), so callers pass
directories and never edit lines. Comments, blank lines and the order of the other lines are
kept; a missing entry is an error and leaves the file untouched. The file is rewritten in
place (`cat` into it), so its mode and symlinks survive.

Directory rename (`req_wizard_rename_dir`, `:ed`, TR.10): renames the last path component with
`mv`, then rewrites the `.req` entry when the directory is listed (relative when it is under the
`.req`, absolute otherwise; the original spelling, such as a trailing slash, is not kept). If the
`.req` cannot be rewritten the `mv` is undone. A `.req` entry that lists a descendant of the
renamed directory is not updated and becomes a missing entry (reported by `req_project_dirs`);
that case is rare and not handled.

Directory copy (`req_wizard_copy_dir`, `:c`, TR.11): `cp -RP` next to the original, default name
`<name>-copy` (asked again while taken); a directory listed in the `.req` gets its copy appended
there, and the copy is removed if the `.req` cannot be written.

Request removal (`req_wizard_remove_request`, `:rm`, TR.12): shows the full path, asks `[y/N]` (default no,
end of input means no) and removes the file. It works for invalid requests, from the list and from the
details screen; afterwards the list is shown with the selection kept near the removed row. On a
directory `:rm` says to select a request until TR.13.

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
`assert_contains`, `test_summary`). 663 asserts at the time of writing.

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
9. **Edit menu** is numbered fields (`1`-`8`, `s`, `q`) and is redrawn after each
   field; long header/query sets are edited one `key: value` line at a time.
10. **Long lists and long names**: scrolling is by window and names are truncated with
    `…`; very long names or paths on narrow terminals deserve a look.
11. **Non-UTF-8 terminals** fall back to ASCII (`>`, `#`, `~`); worth a quick check.

Record findings as new tasks in TASKS.md rather than changing behavior ad hoc. What a
session confirms becomes a task in a review section (see "Review 1 findings" below);
what is still unconfirmed stays in "Adicionais" (TA.2 to TA.13). Items 1, 2, 4, 5, 7
and 11 above have a task there (TA.3 to TA.6 and TA.11), and so does the moving part
of item 6 (TA.2).

## Review 1 findings (2026-11-13)

First usability session. The notes are in the local `reviews` file (git-ignored, like
`manifest`); TASKS.md, section "Revisão 1", keeps the summary and the tasks.

| Finding | Outcome |
|---|---|
| R1 the result is shown above the request data | TR.14, postponed by the user: confirm before implementing. Preferred design: request data above, response below, compact footer |
| R2 no way to rename a directory | TR.9 (`.req` helpers), TR.10 `:ed [name]` |
| R3 no way to duplicate a directory with its contents | TR.11 `:c [name]` |
| R4 no way to remove a directory, even recursively | TR.12 `:rm` on a request, TR.13 `:rm` on a directory (red warning, `[y/N]`) |
| R5 no help listing every option | TR.2 `:h` |
| R6 POST with JSON typed by the user, through vim | TR.3 to TR.8: `parameters`, `raw_data`, external editor |
| R7 dependency error with `sudo` and `install` commands | TR.1 |

Decisions taken with the user (also in TASKS.md, "Decisões fechadas"):
- `data_parameter` is renamed `parameters`: form fields (key and value), always sent
  url-encoded.
- `raw_data` is the raw body, edited in the user's editor like git does (`$VISUAL`,
  `$EDITOR`, `vim`, `vi`; a one-line prompt when there is none). It is stored as native
  JSON (object or array) when the text is JSON and as a string otherwise. A non-empty
  `raw_data` wins over `parameters`. JSON without a `Content-Type` header is sent as
  `application/json`; free text gets no automatic header.
- Files using the old field names are not migrated; validation names the new field.
- `:rm` removes the request or the whole directory under the cursor, only inside the
  project, always after a `[y/N]` confirmation.

Open item 6 above is answered by these tasks and item 5 partly (`:h`); the others are
still open.

## Roadmap

Review 1 first, in this order: TR.1 dependency error, TR.2 `:h`, TR.3 rename to
`parameters`, TR.4 `raw_data` format and sending, TR.5 `raw_data` on the details
screen, TR.6 external editor helper, TR.7 `8) raw data` in the edit menu, TR.8 raw
body in `:n`, TR.9 `.req` entry helpers, TR.10 `:ed`, TR.11 `:c`, TR.12 `:rm` on a
request, TR.13 `:rm` on a directory, TR.14 (postponed), TR.15 verification.

Phase 5: T5.2 key resolution, T5.3 pure `${key}` substitution with a friendly error
that lists the missing keys and tells how to fix them, T5.4 apply it to url, headers,
query, `parameters` and `raw_data`, T5.5 active environment (`REQ_ENV`, default
`default`) in the menu header, T5.6 `:env <name>`, T5.7 secret masking helper, T5.8
verification and docs.
Environment variable names are `<ENV>_<KEY>` in upper case (`${url}` in `dev` is
`DEV_URL`); the variable wins over the file.
Then Phase 6 (logs, verbose with `>>` and `<<`), Phase 7 (portability, docs), the
"Adicionais" section of TASKS.md (TA.2 to TA.13: everything still unconfirmed, mostly
navigation changes) and Phase 8 (per-request options, file upload, nested query
values).
