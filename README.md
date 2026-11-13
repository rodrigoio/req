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
req init          # creates the .req file (workspace=.) and suggests :n to create a request
```

## Usage

```sh
req                               # interactive menu, using the .req of the current directory
req init                          # initialize a project in the current directory
req run path/to/login.post.json   # run one request and show the response and timing profile
req --version
```

The response is shown in the terminal (indented JSON; text and HTML as received) and nothing is written to disk. Optional variables: `REQ_TIMEOUT` (default 60s) and `REQ_CONNECT_TIMEOUT` (default 10s).

Central state: the first time `req` opens a project (or `req init` creates one) it is registered in `~/.req/projects/<name>/`, where its state will live; `~/.req/current` points to the project in use. If `~/.req` cannot be written, `req` warns once and works without it. `REQ_CONFIG_DIR` changes that directory.

### Interactive menu

| Key | Action |
|---|---|
| Up / Down | move the selection (wraps around at the ends) |
| Enter | on a directory, enter it; on a request, open its details; on the details, run it |
| Esc | go back (details → list → parent directory); does nothing at the root |
| Ctrl-C | quit |
| `:` | enter command mode (see below); `:h` lists every key and command |

The menu is redrawn in place without clearing the screen: a request's result stays visible and the menu is redrawn right below it, after the `====` line. The selected row is highlighted in bold bright green. Directories show as `dir  name/` and the other rows show the request's colored method. The details screen also shows `raw_data` (indented JSON or text, up to 15 lines) and flags what will not be sent: `parameters` when `raw_data` takes precedence, and both with GET and DELETE. An invalid request shows its problems on the details screen and is not run.

### The header

The first line of the list shows the path inside the workspace, the position (`3/5`) and, when the terminal is wide enough, the project (the folder of the `.req`) and the environment in use: `req /api (3/5)  shop @ dev`. The environment is `REQ_ENV`, `default` when it is not set.

### Commands

Press `:` to type a command; Enter runs it, Esc (or Backspace on an empty line) cancels.

| Command | Action |
|---|---|
| `:n` | new request in the current directory (the workspace at the root): asks for the name (a slug), method and url, then optionally for a description, a format preset (json, text, html), headers and query. For POST, PUT and PATCH with a preset, it offers to write the body (`raw_data`) in your editor; declining, or choosing no preset, asks for `parameters` instead |
| `:nd [name]` | new directory (alias `:mkdir`). it creates a real subdirectory of the current directory (the workspace at the root) |
| `:ed [name]` | rename the directory under the cursor (asks for the name unless given). The contents move with it; only the last path component changes. On a request it points to `:e` |
| `:cp [name]` | copy the directory (with everything inside, symbolic links copied as links) or the request under the cursor, or the one open on the details screen. It asks for the new name (default `<name>-copy`) and does not open the edit menu |
| `:rm` | remove the selected request (or the one open on the details screen), after a `[y/N]` confirmation; Enter keeps it. It also works on an invalid request. On a directory it removes the directory and everything inside it, after a red warning with the full path and the number of files and subdirectories and the same `[y/N]` question. Only directories inside the workspace are ever deleted, and never a symbolic link |
| `:env [name]` | without an argument, lists the environments of the project and the one in use; with a name, switches the session to it (see "Environments and variables") |
| `:config [-g] [key=value]` | without an argument, shows the settings: every known key with its effective value, its default and `project` when the project sets it. With `key=value` (for example `:config time_stats=no`) it checks the key and the value and writes them to the project's file; with `-g` (`:config -g time_stats=no`) it writes the global `~/.req/config` instead. An unknown key or a wrong value is explained and nothing is written |
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
lib/cmd.sh     command mode (:n :nd :ed :cp :rm :e :d :env :config :h :q) and its help table
lib/wizard.sh  prompts to create, edit, duplicate, rename, copy and remove requests and directories
lib/log.sh     the project's log of the requests sent (`req.log`)
lib/config.sh  settings (global `~/.req/config` and the project's `config`) and their table of keys
lib/env.sh     environments and variables (loading `vars` and `env/<env>`)
lib/home.sh    the central directory in ~/.req: `key=value` files, projects and the current-project pointer
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

The `.req` file marks a folder as an initialized `req` project. `req init` writes it with a comment and the variable `workspace`:

```
# req project: this folder was initialized with req.
workspace=.
```

`workspace` is the directory `req` works on: a path **relative to the folder of the `.req`**, or `.` (the folder itself, the default). It must be an existing directory inside the project folder; absolute paths, a `..` that leaves the project and symbolic links in the path are refused. Use it to keep the `req` content in a subfolder (`workspace=requests`) of a folder that has other files. `req init` creates no directory.

The menu root is the workspace, and it lists **everything in it**: every directory (shown as `dir`) and every request file (shown with its method), hidden items aside. Commands act on the item under the cursor according to its type. Directories are read straight from the disk each time, so a folder you create by hand shows up on the next redraw; the `.req` is never rewritten. A `.req` from an earlier version with one directory per line still works: those lines are ignored.

Manually edited files that become invalid are never fixed: `req` only reports the error, with the file's absolute path.

## Settings

Settings are `key=value` lines in two files: `~/.req/projects/<id>/config` (or under `REQ_CONFIG_DIR`) for the open project, and `~/.req/config` for every project. The project's file wins, and a key it leaves out falls back to the global file and then to the default. Show them with `:config` and change one for the project with `:config key=value`; `:config -g key=value` changes the global file. An unknown key or a wrong value in a file is reported as a warning (with the file and line) and ignored.

| key | default | what it does |
|-----|---------|--------------|
| `time_stats` | `yes` | show the timing stages (DNS, TCP, TLS, Wait, Download) after a request runs, in the menu and in `req run` |
| `time_stat_total` | `yes` | show the total time line of that profile |
| `restore_cursor` | `yes` | reopen the menu in the directory and on the item where it was left; `no` always opens at the workspace root |

The position is saved per project in `~/.req/projects/<id>/cursor` when you leave (`:q`, end of input, Ctrl-C). If the directory or the item is gone when you come back, `req` falls back to the nearest existing directory or to the first item.

## Verbose

With `REQ_VERBOSE=1` in the environment, `req` also shows the data it sends: right under the `METHOD url` line, every form field of `parameters` (`a=1`) or every line of `raw_data` gets a dim `>>` in front. A request without data shows nothing extra. Values are the real ones, after `${key}` is replaced. The received response is added in a later step (T6.5), and `:v` will switch the mode inside the menu (T6.6).

## Log

With `log=yes` (`:config log=yes` for the project, `:config -g log=yes` for every project; the default is `no`) each request that runs is appended to `~/.req/projects/<id>/req.log`, just before it is sent. A line per request, in plain text, with line breaks inside a value written as `\n`:

```
2026-11-13T22:30:00-0300 REQUEST file=add.post.json env=dev POST https://api.example.com/users | header: X-Token: abc123 | body: {"name":"ana"}
```

The values are the real ones, after `${key}` is replaced (nothing is masked). A request that stops before it is sent (invalid file, missing key) is not logged. If the log cannot be written, `req` warns and sends the request anyway. There is no log without an open project. The response follows on the next line, with the status, the Content-Type, the total time and the whole body (there is no size limit), or, when nothing came back, an `ERROR no response (curl exit code N)` line:

```
2026-11-13T22:30:01-0300 RESPONSE status=201 type=application/json total=0.150s | body: {"id":7}
```

## Environments and variables

Variables live in the central directory (`~/.req`, or `REQ_CONFIG_DIR`), one folder per project, as plain `key=value` files:

```
~/.req/projects/<id>/vars          shared by every environment
~/.req/projects/<id>/env/<env>     one file per environment (dev, prod, ...)
```

```
# ~/.req/projects/shop/env/dev
url=https://api.example.com
token=abc123
```

Keys use letters, digits and underscores, and cannot start with a digit. Blank lines and `#` comments are fine; the value is everything after the first `=`. The environment wins over the project variables. Environment names are slugs. A missing file is fine; an invalid one is reported with its path and line, and nothing is loaded. The old `~/.req/env/<env>/secrets.json` is no longer read (there is no migration): if it exists, `req` warns where the variables go now.

### Placeholders

Write `${key}` in the `url`, in the values of `headers`, `query` and `parameters`, and in `raw_data` (also inside a JSON body) and `req` replaces it before sending. The value comes from, in this order:

1. the process variable `<ENV>_<KEY>`, both in capitals, hyphens of the environment turned into underscores (`${url}` in `dev` is `DEV_URL`);
2. the environment file `env/<env>`;
3. the project `vars`.

The environment is the `REQ_ENV` variable, `default` when it is not set. If a key has no value nothing is sent: the error lists every missing key and says which variable or file would define it. `name` and `description`, and the names of properties, are never replaced. There is no way yet to write a literal `${key}` in a request (see TA.14 in [TASKS.md](TASKS.md)). The url shown when a request runs is the substituted one.

`req run` takes the project files from the project registered for the current folder, if there is one; otherwise only the process variables apply.

Switch the environment of the session with `:env <name>`; `:env` alone lists the project's environments (the files in `env/`) and the one in use. An environment must have a file, except `default`, which needs none. The choice is not remembered: the next start uses `REQ_ENV` or `default`. See the roadmap in [TASKS.md](TASKS.md).
