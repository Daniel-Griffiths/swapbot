<div align="center">
  <img src="assets/icon.png" width="128" alt="SwapBot" />
</div>

# SwapBot
Switch Claude Code between Claude accounts from the macOS menu bar, or from the command line on macOS and Linux.

All accounts share one `~/.claude` config. Only the login changes, so your settings, MCP servers and history stay put.

## Install

Download it from the [latest release](https://github.com/Daniel-Griffiths/swapbot/releases/latest):

- **macOS 15+:** `SwapBot.dmg`. Turn on **Settings → Launch at Login** to start it automatically.
- **Linux:** `swapbot-linux-x86_64` or `swapbot-linux-arm64`, a single binary. Run `install -m 755 swapbot-linux-* ~/.local/bin/swapbot`.

To build from source you need Rust, and Swift for the app:

```sh
cargo install --path core          # just the swapbot command
./scripts/build-app.sh --install   # the macOS app, installed to ~/Applications
./scripts/build-app.sh --dmg       # a universal DMG
```

## Menu bar app

<img src="assets/screenshot.png" width="410" alt="SwapBot menu" />

- **Switch:** click an account, or press its number. The account you're leaving is saved first, so refreshed tokens aren't lost.
- **Usage:** hover over an account to see its session and weekly usage and when each resets. SwapBot records it with `claude -p /usage` when you switch away, and from the usage Claude Code caches in `~/.claude.json`.
- **Add Account…** opens Terminal running `claude auth login`, then asks what to call the new account.
- **Manage Accounts:** Log In Again, Rename, Remove.
- **Settings:** Auto-Switch, Launch at Login, showing the account name, and Stay Awake with Lid Closed (`pmset -a disablesleep`, which lasts until you turn it off).

A `?` on the icon means the current login isn't saved, and `×` means Claude Code is signed out.

> [!NOTE]
> Before switching, SwapBot offers to quit running Claude Code sessions. A session left running resends its whole conversation without the old account's prompt cache, which is expensive for long conversations. Quit sessions can be picked up again with `claude --resume`. Accounts in the same team share a cache, so switching between them skips this.

## Auto-Switch

When an account hits its session or weekly limit, SwapBot switches to the least-used account in the same fallback group. When the whole group is used up, it moves on to the group you chose as next. If everything is used up, it waits for the first reset. That needs the app running on macOS, or a systemd user timer on Linux.

Turning it on adds a `StopFailure` hook to `~/.claude/settings.json`. The hook ignores temporary 429s and any limit within a minute of a switch, and logs each decision to `~/.claude/account-profiles/auto-switch.log`.

## Command line

On macOS the command is `~/Applications/SwapBot.app/Contents/Helpers/swapbot`. Link it onto your `PATH`.

```sh
swapbot status                       # accounts, plans, login expiry and usage
swapbot save <name>                  # save the current login
swapbot login [<name>]               # claude auth login, then save it
swapbot switch <name>                # --quit-sessions or --ignore-sessions if any are running
swapbot rename <name> <new-name>
swapbot remove <name>
swapbot auto-switch [on|off]         # show groups, or add or remove the hook
swapbot group move work none         # never switch away from "work"
swapbot group next Work Personal     # fall back from Work to Personal
```

`list`, `status` and `auto-switch` take `--json`.

## How it works

A login is the `claudeAiOauth` object in Claude Code's credentials plus `oauthAccount`/`userID` in `~/.claude.json`. The credentials are in the Keychain item `Claude Code-credentials` on macOS, or `~/.claude/.credentials.json` on Linux. Each saved account keeps a copy of both:
- its tokens in `Claude Code-credentials:<name>` on macOS, or `~/.claude/account-profiles/<name>.credentials.json` on Linux
- its metadata in `<name>.meta.json`

Switching replaces only `claudeAiOauth`, so MCP tokens aren't touched, and empty tokens are never saved or restored. The Keychain is read through `/usr/bin/security`, which is already on the items' access list, so there are no prompts.

The core and CLI are Rust (`core/`). The macOS app is Swift (`Sources/SwapBot`) and does everything through the bundled `swapbot`.

## Development

```sh
cargo test --manifest-path core/Cargo.toml
```

`SWAPBOT_PROFILE_DIR`, `SWAPBOT_CLAUDE_JSON`, `SWAPBOT_CLAUDE_SETTINGS` and `SWAPBOT_CREDENTIALS_FILE` point SwapBot at test data. `SWAPBOT_CREDENTIALS=file` uses credential files on macOS, `SWAPBOT_CLAUDE` swaps `claude`, and `SWAPBOT_CLI` swaps the app's `swapbot`. `SwapBot --dump-menu` prints the menu as text. To regenerate the icon:

```sh
.build/debug/SwapBot --render-app-icon /tmp/AppIcon.iconset
iconutil -c icns /tmp/AppIcon.iconset -o Resources/AppIcon.icns
cp /tmp/AppIcon.iconset/icon_256x256@2x.png assets/icon.png
```
