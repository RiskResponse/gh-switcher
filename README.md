# GH Switch

A macOS menu bar app, CLI, and Claude Code MCP server for switching between GitHub accounts.

It is a thin layer over the `gh` CLI's multi-account support: accounts live in gh's keyring, and switching runs
`gh auth switch`. Because git uses `gh auth git-credential` as its credential helper, the switch also changes
which account `git push`/`pull` authenticate as. Optionally it sets the global `git config user.name`/`user.email`
to match, so commits are attributed correctly.

## Install

Requires macOS 15+, Xcode (or the Swift 6 toolchain), and `gh` logged in to each account (`gh auth login`).

```sh
make install   # builds, copies to ~/Applications, links ~/.local/bin/gh-switch, registers with Claude Code
```

## Use

- **Menu bar**: click the icon to open the flyout, then click an account (or press ⌘1–⌘9) to switch.
  **Manage Accounts…** opens a window where you can set labels (e.g. "Work") and a git name or email per account,
  remove an account (logs it out of gh), toggle git identity updates, launch at login, and install the Claude integration.
- **CLI**:
  ```sh
  gh-switch                 # list accounts (* = active)
  gh-switch switch acme    # login, label, or unique substring
  gh-switch current --json
  gh-switch remove octo     # gh auth logout; exact login, label, or host/login only
  ```
- **Claude**: once registered (`gh-switch install-claude`), ask Claude to "switch to my work GitHub account".
  Tools: `list_github_accounts`, `get_active_github_account`, `switch_github_account`.

Switching is global: it affects every terminal and Claude session. The app picks up switches made from the CLI or
Claude by watching gh's config directory.

## Config

`~/.config/gh-switch/config.json` stores labels, git identity overrides, and cached names and avatars from the
GitHub API. If no git email is set, the account's `ID+login@users.noreply.github.com` address is used.

## Develop

```sh
make test   # swift-testing unit tests for parsing, matching, identity defaults, MCP protocol
make run    # run the menu bar app unbundled
```
