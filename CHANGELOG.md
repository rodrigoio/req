# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.6.1] - 2026-11-23

### Added

- Show the logo of the project, `{❯} Req` (cyan braces, green arrow, bold `Req`), on the first row of every screen of
  the menu, above the warning bars. It is plain text without colors, and `{>} Req` where the terminal is not UTF-8.
  The list and the `:env` menu give it a row, so they show one item less.
- Warn, in the bar at the top, when a project opens and still has files of the previous layout of the variables (its
  `vars` file and the files `env/<name>`): the warning names each one, says it is no longer read and where its
  lines go. Those files are never read, moved or changed.

### Changed

- Open the variables of the environment in use with `:vars` (or `:var`), its own `env/<name>/vars`, instead of the
  file that every environment shared. A new environment starts with a `vars` file whose comment lines show the
  format, the lines `:vars` used to add.
- **BREAKING:** Load only the variables of the environment in use, and no longer the project's `vars` file that
  every environment shared: nothing is shared between environments now, and a value that several of them need
  is written in each one. To migrate, copy the lines of `~/.req/projects/<id>/vars` into the `vars` of each
  environment that uses them.
- **BREAKING:** Keep the variables of each environment in a folder of its own, `env/<name>/vars`, instead of the
  file `env/<name>`. An old file is no longer read, listed as an environment or switched to. To migrate, rename
  the file, make the folder `env/<name>/` in `~/.req/projects/<id>/` and move the file into it as `vars`.

## [0.6.0] - 2026-11-23

### Added

- Go back with `q` as well as with Esc: on the list (up one directory), on the details of a request and on the
  `:env` menu. At the root of the list `q` quits `req`, saving the position as `:q` does; Esc still does nothing
  there, so it never closes the program by accident.
- Open the help with the key `h`, on the list and on the details, as `:h` does; any key closes it.

### Changed

- Clear the screen when the menu starts, so you can see at once that `req` is running. Only the menu does it:
  `req run`, `req init`, `req log`, `--version` and `--help` print as before.
- Remove the line of hints about the keys at the bottom of the list, the details and the `:env` menu, and the
  "Press any key" line of the help and the settings: press `h` for the help, which now lists every key (Ctrl-C and
  "any key" included), in a column that no longer squeezes their descriptions. The command you type shows under the
  screen without hiding a row of the list.
- Say what a command did (created, saved, renamed, copied, removed, the environment you switched to, the log and the
  verbose mode) in the orange bar at the top, once, like the warnings, instead of in a dim line under the menu. A
  message longer than the terminal is cut at its width.

## [0.5.2] - 2026-11-23

### Fixed

- Type headers as `key=value` in `:n` and `:e`, the same as query and parameters, instead of `key: value`. A
  header typed with `=` was refused and lost, as if it had been ignored. Now every key/value prompt takes one
  format, and a header line written as `key: value` is refused with `expected key=value`.

## [0.5.1] - 2026-11-18

### Fixed

- Make the `env/` folder and the `default` environment file of a project when `req` opens it, instead of
  leaving them for you to create by hand. A project you already had gets them the next time it is opened.
- Offer to create the environment when `:env <name>` names one that does not exist (`Create environment
  "<name>"? [Y/n]`), instead of telling you to create its file yourself. The new file is empty and private,
  and the message says where it is.
- Load the whole set of variables of an environment when you switch to it with `:env`, and report a broken
  file right then (with its path and line) instead of only when a request runs. The status line says how
  many variables were loaded.
- Choose the environment from a menu: `:env` with no name lists the environments of the project, with the
  one in use marked (up and down, Enter to switch, Esc to leave), instead of printing a line of text. Its
  last row, `+ new environment`, asks for a name and creates the environment, switching to it.
- Edit the variables of the project from inside `req` with `:vars` (or `:var`), instead of looking for the
  file in `~/.req` and creating it by hand. It opens `vars` in `$VISUAL`, `$EDITOR`, `vim` or `nano`, in that
  order, making the file first with commented examples of the format (comments are never variables). When the
  editor closes it loads the variables again and reports a bad line with its path and line. With no editor it
  makes the file anyway and says where it is and how to fill it.

## [0.5.0] - 2026-11-18

### Added

- Follow the log of the project from another terminal with `req log` (`tail -n 200 -F` on its `req.log`),
  without looking for the file. If the log does not exist yet it waits for it. While the log is at its
  `log_request_limit` lines, `tail` prints the whole log again after each new line (see the README).
- Clear the screen with Ctrl-L: the results of the requests already made go away and the menu is drawn
  again at the top, with the same selection.
- Show the last response in full screen with `v` (on the list or on the details): JSON indented by `jq`,
  anything else as it came, in `$PAGER` or else `less`. Only the response of this session is kept, in
  memory; nothing is written to disk.

### Changed

- Download a smaller `release/req.sh`, about 30% lighter (139 KB down to 99 KB): the comments of the
  sources are left out of the single file. It runs exactly as before.

## [0.4.0] - 2026-11-16

### Added

- Warn with a persistent bar at the top of the screen, at every screen, when `req` runs as root, since the
  files you create or edit could end up owned by root and upset the owner and permissions of your project.
- Warn, in a bar at the top of the details and when the request runs in the menu, about a `url` that is not
  a usable address (whitespace, a scheme other than http or https, no host). The request is still sent.

### Changed

- Link `make install` to the built `release/req.sh` (it runs `make build` first) instead of to the sources,
  so the installed `req` is the same single file as the download. Run `make install` again to update it.
  `make uninstall` removes the link, including one made by an older `make install`.
- Show an incorrect command (an unknown command, nothing selected, a wrong usage, an invalid setting or
  environment) as an orange warning bar at the top of the screen, once, instead of a dim line under the
  menu. Confirmations stay under the menu.
- Show the warnings raised while the menu is open (a bad line in a settings file, a log that cannot be
  written) in that bar too, instead of printing them in the terminal. `req run` still prints them to stderr.
- Show the failure of a request run from the menu (a variable with no value, a file that cannot be read, a
  failure of curl) as a one-line warning at the top, instead of error text above the menu.
- Pin the first problem of an invalid request at the top of its details screen and list at most 10 of its
  problems, so a file with many problems no longer fills the terminal.

## [0.3.0] - 2026-11-16

### Added

- Install `req` with a single download: `release/req.sh` is the whole tool in one executable file, which
  `curl` can fetch straight into your `PATH` (see the README). `make build` generates it.

## [0.2.0] - 2026-11-16

### Added

- Run the lint and the tests automatically on every pull request with GitHub Actions, so contributors
  see a broken change before it is merged. `req` itself behaves as in 0.1.0.

## [0.1.0] - 2026-11-16

### Added

- Register, browse and fire HTTP requests from an interactive terminal menu, with requests kept as plain
  JSON files in your project folder.
- Run a single request without the menu with `req run <file>`, which shows the response and a timing
  profile (DNS, TCP, TLS, wait, download, total).
- Start a project with `req init`, or accept the offer when `req` opens a folder that has none.
- Create, edit, duplicate, copy, rename and remove requests and directories from the menu (`:n`, `:e`,
  `:d`, `:cp`, `:ed`, `:nd`, `:rm`), with the body opened in your editor.
- Use variables in requests with `${key}` placeholders, resolved from per-project environments and
  switched with `:env`.
- Tune behavior with project and global settings through `:config` (timing display, cursor restore,
  redirect limit, log size).
- Keep an optional log of requests and responses per project (`:log`), and show the data being sent
  with the verbose mode (`:v`).
- Show the installed version with `req --version`.

[unreleased]: https://github.com/rodrigoio/req/compare/v0.6.1...HEAD
[0.6.1]: https://github.com/rodrigoio/req/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/rodrigoio/req/compare/v0.5.2...v0.6.0
[0.5.2]: https://github.com/rodrigoio/req/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/rodrigoio/req/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/rodrigoio/req/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/rodrigoio/req/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/rodrigoio/req/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/rodrigoio/req/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/rodrigoio/req/tree/v0.1.0
