# req

The interactive request tool for your terminal. A bash + curl utility to register, browse and fire HTTP requests, with persistence in plain JSON files.

> Work in progress. The roadmap lives in [TASKS.md](TASKS.md); architecture, conventions and open questions are in [DEVELOPMENT.md](DEVELOPMENT.md).

## Requirements

Runtime: bash 4+, curl and jq. Nothing else.

Development only (not needed to use `req`): `shellcheck`, used by `make lint` over `bin/`, `lib/` and `tests/`. When it is not installed, `make lint` just warns and only checks the syntax. The tests need `python3` for the local mock server and skip those cases without it.

## Installation

```sh
make install      # symlink at ~/.local/bin/req
make uninstall    # remove the symlink
```

To install elsewhere: `make install PREFIX=/usr/local` (or `BINDIR=...`). If the directory is not in your `PATH`, `make install` warns and shows how to add it.

## Getting started

```sh
cd my-project
req               # no .req here? it offers to initialize the project: [Y/n]
```

Or explicitly:

```sh
req init          # creates .req and a requests/ directory
```

## Usage

```sh
req                               # interactive menu, using the .req of the current directory
req init                          # initialize a project in the current directory
req run path/to/login.post.json   # run one request and show the response and timing profile
req --version
```

The response is shown in the terminal (indented JSON; text and HTML as received) and nothing is written to disk. Optional variables: `REQ_TIMEOUT` (default 60s) and `REQ_CONNECT_TIMEOUT` (default 10s).

### Interactive menu

| Key | Action |
|---|---|
| Up / Down | move the selection (wraps around at the ends) |
| Enter | on a directory, enter it; on a request, open its details; on the details, run it |
| Esc | go back (details → list → parent directory); does nothing at the root |
| Ctrl-C | quit |
| `:` | enter command mode (see below); `:h` lists every key and command |

The menu is redrawn in place without clearing the screen: a request's result stays visible and the menu is redrawn right below it, after the `====` line. The selected row is highlighted in bold bright green. Directories show as `dir  name/` and the other rows show the request's colored method. The details screen also shows `raw_data` (indented JSON or text, up to 15 lines) and flags what will not be sent: `parameters` when `raw_data` takes precedence, and both with GET and DELETE. An invalid request shows its problems on the details screen and is not run.

### Commands

Press `:` to type a command; Enter runs it, Esc (or Backspace on an empty line) cancels.

| Command | Action |
|---|---|
| `:n` | new request in the current directory: asks for the name (a slug), method and url, then optionally for a description, a format preset (json, text, html), headers and query. For POST, PUT and PATCH with a preset, it offers to write the body (`raw_data`) in your editor; declining, or choosing no preset, asks for `parameters` instead |
| `:nd [name]` | new directory (alias `:mkdir`). At the root it is also added to the `.req`; inside a directory it creates a real subdirectory |
| `:ed [name]` | rename the directory under the cursor (asks for the name unless given). The contents move with it and a `.req` entry for it is updated; only the last path component changes |
| `:c [name]` | copy the directory under the cursor with everything inside (default name `<name>-copy`, symbolic links are copied as links). A directory listed in the `.req` has its copy listed too |
| `:rm` | remove the selected request (or the one open on the details screen), after a `[y/N]` confirmation; Enter keeps it. It also works on an invalid request. On a directory it removes the directory and everything inside it, after a red warning with the full path and the number of files and subdirectories and the same `[y/N]` question; a listed directory also leaves the `.req`. Only directories inside the project are ever deleted: for a directory outside it, or a symbolic link, `:rm` only offers to unlist it from the `.req` |
| `:e` | edit the selected request (or the one open on the details screen) through a field menu; changing the name or the method renames the file. Option `8) raw data` opens the body in your editor (`$VISUAL`, `$EDITOR`, `vim`, `vi`, like git); without one it asks for a single line (`-` clears). JSON objects and lists are stored as native JSON; other text is stored as a string, and you are offered to edit it again first unless the request has a non-JSON `Content-Type` |
| `:d` | duplicate the selected request under a new name and open the edit menu on the copy |
| `:h` | help: lists every key and command (alias `:help`); any key goes back. A new command is added to the `REQ_HELP_ROWS` table in `lib/cmd.sh` |
| `:q` | quit, without asking for confirmation |

In the prompts, Enter accepts the default shown in brackets and an empty name cancels. In the key/value prompts, `key: value` (headers) or `key=value` (query and parameters) sets an entry, `-key` removes it and an empty line finishes. Directory and request names are slugs: lowercase letters, digits and hyphens.

## Development

```sh
make test    # run the tests
make lint    # shellcheck (if installed) + syntax check
make check   # lint + tests
```

## Layout

```
bin/req        thin entrypoint (resolves its directory and calls main)
lib/core.sh    dependencies, errors, external editor and terminal restoration
lib/ui.sh      ANSI colors, terminal helpers and per-method formatting
lib/store.sh   request persistence and the .req project file
lib/http.sh    curl command building, execution, display and timing profile
lib/nav.sh     interactive menu: list, details and keys
lib/cmd.sh     command mode (:n :nd :ed :c :rm :e :d :h :q) and its help table
lib/wizard.sh  prompts to create, edit, duplicate, rename, copy and remove requests and directories
lib/env.sh     environments and secrets (loading `secrets.json`)
lib/home.sh    the central directory in ~/.req: `key=value` files (projects, configuration, cursor)
tests/         plain bash tests (no dependencies; see Requirements)
Makefile       test, lint, install and uninstall
```

All the code is organized in functions inside `lib/`.

## File format

Each request is a file `<slug>.<method>.json` (methods: GET, POST, PUT, PATCH, DELETE). The slug uses only lowercase letters, digits and hyphens (e.g. `list-users`). The `name` in the JSON is identical to the file's slug and is the label shown in the menu.

```json
{
  "name": "login",
  "method": "POST",
  "url": "https://api.example.com/login",
  "description": "Signs the user in",
  "headers": {"Content-Type": "application/json"},
  "query": {},
  "parameters": {"user": "ann"}
}
```

- Required: `name`, `method` and `url`. Optional: `description`, `headers`, `query`, `parameters` and `raw_data`.
- `headers`, `query` and `parameters` are objects with simple values (string, number or boolean).
- `query` is appended to the url, url-encoded.
- `raw_data` is the raw body: an object or list (JSON) or a string (any other text).
- Body (sent only with POST, PUT and PATCH; GET and DELETE never send one):
  - `parameters` are form fields, always sent url-encoded.
  - A non-empty `raw_data` is sent as it is and wins over `parameters`. An object or list is sent as compact JSON, with `Content-Type: application/json` unless the request already sets a `Content-Type`; free text gets no automatic `Content-Type`. An empty string means no raw body.
  - Files with the old names `data_parameter` and `data_string` are not migrated; the validation points to the new names.
- Unknown fields or fields with a wrong type invalidate the request.

Subdirectories of the project are real directories.

The `.req` file at the project root lists the directories that make it up, one per line, relative to the `.req` itself. Blank lines and lines starting with `#` are ignored:

```
# project
api
auth
```

Manually edited files that become invalid are never fixed: `req` only reports the error, with the file's absolute path.

## Environments and secrets (in progress)

Secrets are kept per environment in `~/.req/env/<env>/secrets.json` (override the directory with `REQ_CONFIG_DIR`), a flat object of simple values. Keys use letters, digits and underscores, and cannot start with a digit:

```json
{"token": "abc123", "base_url": "https://api.example.com", "port": 8080}
```

Environment names are slugs (e.g. `dev`, `prod`). A missing file is fine; an invalid one is reported and nothing is loaded.

Not wired in yet: using `${key}` placeholders in requests, `<ENV>_<KEY>` environment variables taking precedence over the file (`${url}` in `dev` would be `DEV_URL`), and switching with `:env <name>`. See the roadmap in [TASKS.md](TASKS.md).
