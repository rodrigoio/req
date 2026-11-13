# req

The interactive request tool for your terminal. A bash + curl utility to register, browse and fire HTTP requests, with persistence in plain JSON files.

> Work in progress. The roadmap lives in [TASKS.md](TASKS.md).

## Requirements

Runtime: bash 4+, curl and jq. Nothing else.

Development only (not needed to use `req`): `shellcheck`, used by `make lint`. When it is not installed, `make lint` just warns and only checks the syntax. The tests need `python3` for the local mock server and skip those cases without it.

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

The menu is redrawn in place without clearing the screen: a request's result stays visible and the menu is redrawn right below it, after the `====` line. Directories show as `dir  name/` and requests with a colored method. An invalid request shows its problems on the details screen and is not run.

## Development

```sh
make test    # run the tests
make lint    # shellcheck (if installed) + syntax check
make check   # lint + tests
```

## Layout

```
bin/req        thin entrypoint (resolves its directory and calls main)
lib/core.sh    dependencies, errors and terminal restoration
lib/ui.sh      ANSI colors, terminal helpers and per-method formatting
lib/store.sh   request persistence and the .req project file
lib/http.sh    curl command building, execution, display and timing profile
lib/nav.sh     interactive menu: list, details and keys
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
  "data_parameter": {"user": "ann"}
}
```

- Required: `name`, `method` and `url`. Optional: `description`, `headers`, `query` and `data_parameter`.
- `headers`, `query` and `data_parameter` are objects with simple values (string, number or boolean).
- `query` is appended to the url, url-encoded.
- Body (sent only with POST, PUT and PATCH): `data_parameter` is sent as JSON when the `Content-Type` header contains `json`, and as an url-encoded form otherwise.
- Unknown fields or fields with a wrong type invalidate the request.

Subdirectories of the project are real directories.

The `.req` file at the project root lists the directories that make it up, one per line, relative to the `.req` itself. Blank lines and lines starting with `#` are ignored:

```
# project
api
auth
```

Manually edited files that become invalid are never fixed: `req` only reports the error.
