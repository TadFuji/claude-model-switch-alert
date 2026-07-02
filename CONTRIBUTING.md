# Contributing

This is a small, personal project. Contributions are welcome, but please keep changes minimal and in scope.

## Testing changes locally

Run the test suite with [Pester](https://pester.dev/) 5+:

```powershell
Install-Module Pester -Force -SkipPublisherCheck  # if not already installed
Invoke-Pester -Path .\scripts\model-switch-alert.tests.ps1
```

To smoke-test the script by hand, pipe a fake JSON payload into it (matching what Claude Code's `Stop` hook sends on stdin):

```powershell
'{"transcript_path":"C:\path\to\fake-transcript.jsonl","session_id":"test"}' | powershell.exe -NoProfile -File .\scripts\model-switch-alert.ps1
```

CI runs [PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer) lint checks plus the Pester suite on `windows-latest` for every PR.

## Coding conventions

**Keep `.ps1` / `.psd1` files pure ASCII.** Without a BOM, Windows PowerShell 5.1 parses script files using the system codepage (Shift-JIS on Japanese Windows). Any literal Japanese text or emoji embedded directly in a `.ps1` file gets corrupted and can break parsing.

Any user-facing Japanese or emoji text belongs in `scripts/messages.json` instead, which is read at runtime with `Get-Content -Encoding UTF8`. Do not add new literal Japanese/emoji strings to `.ps1` files — add a key to `messages.json` and reference it from the script.

## Installing the plugin locally for end-to-end testing

Inside Claude Code:

```
/plugin marketplace add TadFuji/claude-model-switch-alert
/plugin install model-switch-alert@tadfuji-market
```

Then restart Claude Code so the `Stop` hook in `hooks/hooks.json` is picked up.

## Pull requests

This is a small utility, not a framework. Please:

- Keep diffs minimal and focused on the change described.
- Match the existing style in `scripts/model-switch-alert.ps1` rather than introducing new patterns.
- Avoid adding new dependencies or abstractions (no new modules, no config layers) unless the change genuinely requires it.

## Credit

This project is a fork/Windows port of [KaishuShito/claude-model-switch-alert](https://github.com/KaishuShito/claude-model-switch-alert). Thanks to the original author for the idea and implementation this builds on.
