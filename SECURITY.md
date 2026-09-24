# Security & privacy

Indicators runs entirely on your Mac. There is no backend and no telemetry.

## What it reads

| Data | Where | Why |
| --- | --- | --- |
| Claude Code transcripts | `~/.claude/projects/**/*.jsonl` | Token counts per response → cost estimate |
| Claude Code OAuth token | macOS Keychain item `Claude Code-credentials` (or `~/.claude/.credentials.json`) | One `GET https://api.anthropic.com/api/oauth/usage` call per refresh |
| Codex CLI rollouts | `~/.codex/sessions/**/*.jsonl` | Token counts and last-seen rate limits |
| Codex CLI session | `~/.codex/auth.json` | One `GET https://chatgpt.com/backend-api/wham/usage` call per refresh |
| Gemini CLI chats | `~/.gemini/tmp/*/chats/*.json` | Token counts |
| Gemini CLI OAuth | `~/.gemini/oauth_creds.json` | One `POST cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota` call per refresh |
| Cursor session | `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` (read-only) | `GET https://cursor.com/api/usage-summary` and `/api/usage` per refresh |
| OpenCode messages | `~/.local/share/opencode/storage/message/**.json` | Token counts, attributed to each vendor |
| Update check | `GET api.github.com/repos/jonymusky/indicators/releases/latest` once a day (no identifiers sent; can be turned off in Settings) | Suggest new versions |
| Your billing API keys | Keychain service `com.jonymusky.indicators` | Only sent to the vendor that issued them |

All log access is read-only. Tokens read from other tools are used in memory for a single
request and never written anywhere by this app.

## Network endpoints

`api.anthropic.com`, `chatgpt.com`, `cloudcode-pa.googleapis.com`, `oauth2.googleapis.com`,
`api.openai.com`, `management-api.x.ai`, `cursor.com`, `api.github.com` (update check), and `raw.githubusercontent.com` (pricing table).

## Reporting a vulnerability

Please open a private security advisory on GitHub or email the maintainer instead of
filing a public issue. Include steps to reproduce; do not include real tokens.
