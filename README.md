# GH Switch

A macOS menu bar app, CLI, and MCP server for switching between GitHub accounts, usable from the menu bar, the
terminal, Claude Code, and the Claude desktop app (chat and Cowork).

It is a thin layer over the `gh` CLI's multi-account support: accounts live in gh's keyring, and switching runs
`gh auth switch`. Because git uses `gh auth git-credential` as its credential helper, the switch also changes
which account `git push`/`pull` authenticate as. Optionally it sets the global `git config user.name`/`user.email`
to match, so commits are attributed correctly.

## Setup

### 1. Prerequisites

- macOS 15 or later
- Xcode or the Swift 6 toolchain (`swift --version`)
- [GitHub CLI](https://cli.github.com): `brew install gh`
- Optional: [Claude Code](https://claude.com/claude-code) and/or the [Claude desktop app](https://claude.ai/download)

### 2. Log in to each GitHub account with gh

```sh
gh auth login --web --git-protocol https   # repeat once per account
gh auth setup-git                          # make git use gh for HTTPS credentials
gh auth status                             # should list every account
```

`gh auth setup-git` is what lets a switch change which account git pushes as. Check it with
`git config --global --get-all credential.https://github.com.helper` (it should mention `gh auth git-credential`).

### 3. Build and install

```sh
git clone https://github.com/RiskResponse/gh-switcher.git && cd gh-switcher
make install
```

`make install`:

1. builds `build/GH Switch.app` (the menu bar app with the `gh-switch` CLI bundled inside),
2. copies it to `~/Applications` and launches it,
3. symlinks the CLI to `~/.local/bin/gh-switch` (make sure `~/.local/bin` is on your `PATH`),
4. registers the MCP server with Claude Code (`gh-switch install-claude`) if the `claude` CLI is installed,
5. registers it with the Claude desktop app (`gh-switch install-desktop`) if that app is installed.

Steps 4 and 5 are skipped with a message if the corresponding app is missing; run `make claude` or `make desktop`
later, or use the buttons in **Manage Accounts…**.

### 4. Finish connecting Claude

- **Claude Code**: new sessions pick up the server automatically. Check with `claude mcp get gh-switch`.
- **Claude desktop app / Cowork**: quit Claude completely (⌘Q) and reopen it. gh-switch then appears under
  Settings → Connectors. Recommended permissions: allow the two read-only tools (list, get active) always, and
  leave **Switch github account** on "Needs approval".

`install-desktop` edits `~/Library/Application Support/Claude/claude_desktop_config.json`, leaving your other
servers alone and saving the previous version as `claude_desktop_config.json.gh-switch.bak`.

### 5. Verify

```sh
gh-switch            # lists accounts, * marks the active one
gh-switch current    # active account and global git identity
```

Then click the menu bar icon, and in Claude ask "which GitHub account am I using?".

## Use

- **Menu bar**: click the icon to open the flyout, then click an account (or press ⌘1–⌘9) to switch.
  **Manage Accounts…** opens a window where you can set labels (e.g. "Work") and a git name or email per account,
  remove an account (logs it out of gh), toggle git identity updates, launch at login, and install the Claude
  integrations. If you don't see the icon, check System Settings → Menu Bar, or your menu bar manager.
- **CLI**:
  ```sh
  gh-switch                 # list accounts (* = active)
  gh-switch switch acme    # login, label, or unique substring
  gh-switch current --json
  gh-switch remove octo     # gh auth logout; exact login, label, or host/login only
  gh-switch help
  ```
- **Claude**: ask "switch to my work GitHub account" or "list my GitHub accounts".
  Tools: `list_github_accounts`, `get_active_github_account` (read-only), `switch_github_account`.
  Removing accounts is deliberately not exposed to Claude.

Switching is global: it affects every terminal and Claude session on the Mac. The app picks up switches made from
the CLI or Claude by watching gh's config directory. Cowork runs commands in its own sandbox, so a switch changes
your Mac's gh and git, not gh/git inside a Cowork sandbox.

Removing an account runs `gh auth logout`, which deletes the token from this Mac's keyring but does not revoke it
on GitHub. Add it back with `gh auth login`.

## Config

`~/.config/gh-switch/config.json` stores labels, git identity overrides, and cached names and avatars from the
GitHub API. If no git email is set, the account's `ID+login@users.noreply.github.com` address is used.

## Uninstall

```sh
pkill -x GHSwitch
rm -rf ~/Applications/GH\ Switch.app ~/.local/bin/gh-switch ~/.config/gh-switch
claude mcp remove --scope user gh-switch
```

Then delete the `gh-switch` entry under `mcpServers` in
`~/Library/Application Support/Claude/claude_desktop_config.json` and restart Claude. Your gh logins are untouched.

## Troubleshooting

- **"Could not find `gh`"**: GUI apps get a minimal `PATH`; gh-switch also looks in `/opt/homebrew/bin`,
  `/usr/local/bin`, and `~/.local/bin`. Install gh in one of those.
- **git still pushes as the old account**: run `gh auth setup-git` (see step 2).
- **Claude doesn't show the tools**: re-run `make claude` / `make desktop`, then start a new Claude Code session or
  restart the Claude app.

## Develop

```sh
make test   # swift-testing unit tests for parsing, matching, identity defaults, MCP protocol, Claude config
make run    # run the menu bar app unbundled
make app    # build the app bundle into build/
```
