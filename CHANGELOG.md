# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-09-22

### Added
- Menu bar app showing subscription rate-limit windows for Claude (Claude Code), OpenAI (Codex CLI) and Gemini (Gemini CLI).
- ccusage-style cost estimates from local CLI logs, priced with the LiteLLM table (bundled snapshot plus automatic refresh).
- Optional real spend from vendor billing APIs: Anthropic Admin API, OpenAI Costs API, xAI Management API (spend + prepaid balance).
- `indicators-cli` companion for the terminal.
- Launch at login, configurable refresh interval, per-provider toggles.
