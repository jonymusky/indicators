# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Skills window (puzzle icon in the popover header): lists globally installed agent skills from skills.sh and your own local ones, shows which agents expose each one, checks GitHub for updates the same way `npx skills update` does, and updates, removes or adds skills through the `skills` CLI. The icon gets a dot when updates are available.
- `indicators-cli skills [--json] [--refresh]` prints the same list from the terminal.

## [0.2.2] - 2026-11-07

### Added
- Grok card shows the Grok Bot usage pool (% used and reset) from the Grok Bot app login. Its session is decrypted with the "Grok Bot Safe Storage" Keychain item.
- Cursor plan usage is split into Auto and named models when the plan has an included limit.

### Fixed
- Cursor usage works again with Cursor 3.x, which encrypts its session token at rest (`cursor-safe-storage:v1`). The key is read from the "Cursor Safe Storage" Keychain item through `/usr/bin/security`, so the "Always Allow" answer survives app updates.
- Cursor falls back to the locally stored account id when the session token is not a JWT, and shows the membership type as the plan when the API does not report one.

## [0.2.1] - 2026-09-23

### Added
- Daily update check against GitHub releases, with an in-popover banner (download, or the `brew upgrade` command when installed via Homebrew) and "skip this version". Can be disabled in Settings.

## [0.2.0] - 2026-09-23

### Added
- Cursor provider: plan usage and on-demand spend for the billing cycle from the local Cursor login.
- OpenCode sessions as an additional local cost source, attributed per vendor.
- Notifications when a window crosses 50/80/90/95% and when it resets (opt-in, each event once).
- 30-day spend sparkline per provider.
- Homebrew cask (`homebrew/indicators.rb`, `scripts/update-cask.sh`).
- Demo video (`docs/demo.mp4`, `make video`).
- `indicators-mcp`: local MCP server with `get_usage`, `recommend_model`, routing-rule management, `estimate_cost`, `list_models`.
- README badges, live GitHub stats on the landing, one-time star nudge after a week.
- Menu bar options: full names or initials, session/weekly/peak window, reset countdown.
- Landing site (GitHub Pages) with install script, SEO metadata and `llms.txt`.

### Fixed
- Claude credentials are read through the `security` CLI, avoiding a Keychain prompt on every rebuild.
- Live windows are kept from the last good answer when a refresh fails; 429s back off for 15 minutes.

## [0.1.0] - 2026-09-22

### Added
- Menu bar app showing subscription rate-limit windows for Claude (Claude Code), OpenAI (Codex CLI) and Gemini (Gemini CLI).
- ccusage-style cost estimates from local CLI logs, priced with the LiteLLM table (bundled snapshot plus automatic refresh).
- Optional real spend from vendor billing APIs: Anthropic Admin API, OpenAI Costs API, xAI Management API (spend + prepaid balance).
- `indicators-cli` companion for the terminal.
- Launch at login, configurable refresh interval, per-provider toggles.
