# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
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
