# Contributing

Thanks for helping make Indicators better.

## Development setup

```bash
git clone https://github.com/jonymusky/indicators.git
cd indicators
make app      # build/Indicators.app
make run      # build and launch
make cli      # print the local-log cost report in the terminal
```

Only the Xcode Command Line Tools are required to build the app. Running the unit
tests (`swift test`) needs a full Xcode install because XCTest does not ship with
the Command Line Tools; CI runs them on every pull request.

## Project layout

| Path | Purpose |
| --- | --- |
| `Sources/IndicatorsCore` | Platform-independent logic: models, pricing, log parsers, API fetchers |
| `Sources/Indicators` | SwiftUI menu bar app |
| `Sources/IndicatorsCLI` | `indicators-cli`, a terminal view of the same numbers (handy for debugging) |
| `Tests/IndicatorsCoreTests` | Unit tests with inline fixtures |
| `scripts/` | App bundling, icon generation, pricing table refresh |

## Adding a provider

1. Add a case to `Provider` in `Models.swift`.
2. If the vendor's CLI writes local logs, implement `LocalLogParser` (see `Parsers/`).
3. If the vendor exposes rate limits or spend, implement a fetcher (see `Fetchers/`).
4. Wire both into `ProviderService.snapshot(for:)`.
5. Add fixtures and tests, and a row to the README's provider table.

## Pull requests

- Keep changes focused and add tests for parsing or pricing logic.
- Run `swift build` and, if you have Xcode, `swift test` before pushing.
- Describe what you verified against real logs when touching parsers.

## Reporting bugs

Open an issue with your macOS version, the CLI versions involved (`claude --version`,
`codex --version`, `gemini --version`) and, when possible, a redacted log line that
reproduces the problem. Never paste tokens or API keys.
