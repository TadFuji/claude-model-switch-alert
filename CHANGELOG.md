# Changelog

All notable changes to this project are documented in this file. Format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project follows
[Semantic Versioning](https://semver.org/).

## [1.5.0] - 2026-07-02

### Changed
- Detection is now intent-based: the hook compares the model actually answering against the model the
  user *expects*, rather than only watching for a change in the emitted model. "Expected" is, in
  priority order, the model most recently requested via `/model` (read from its "Set model to ..."
  trace, ANSI codes and display names handled), then the persisted per-session baseline, then
  `CLAUDE_EXPECTED_MODEL`, then the first model observed.
- This fixes the case where a `/model` request is silently overridden by a safeguard: asking for
  Fable 5 and getting Opus 4.8 on every reply now alerts, instead of staying silent because the
  emitted model never changed. A `/model` switch that is actually honored still stays silent.
- The `Set model to ...` trace is only read from plain-string user turns, never from tool-result
  content, so the script's own source (which mentions those words) can't be misread as a request.

### Removed
- `Test-ManualSwitch`: subsumed by intent-based detection. Whether a switch was manual is now decided
  by whether the requested model matches the served one, not by the mere presence of a `/model` trace.

## [1.4.0] - 2026-07-02

Windows port. Forked from [KaishuShito/claude-model-switch-alert](https://github.com/KaishuShito/claude-model-switch-alert)
at v1.3.0.

### Added
- Full rewrite of the Stop hook as PowerShell 5.1 (`scripts/model-switch-alert.ps1`), replacing the
  macOS-only bash script. Uses only built-in .NET APIs (`System.Media.SoundPlayer`,
  `System.Speech.Synthesis`, `System.Windows.Forms.NotifyIcon`) - no external dependencies, no `jq`.
- Pester test suite covering every alert branch (`scripts/model-switch-alert.tests.ps1`).
- GitHub Actions CI (`.github/workflows/ci.yml`): PSScriptAnalyzer lint + Pester tests on every push/PR.
- `CONTRIBUTING.md` and a bug report issue template.

### Changed
- Japanese/emoji message strings moved out of the script into `scripts/messages.json`, read explicitly
  as UTF-8 at runtime. Windows PowerShell 5.1 parses `.ps1` source using the system codepage
  (Shift-JIS on Japanese Windows) when there is no BOM, which corrupts multi-byte characters embedded
  directly in the script - externalizing the strings avoids this entirely.
- Marketplace/plugin metadata rebranded for this fork (`tadfuji-market`), crediting original author
  Kaishu Shito.

### Removed
- AGI Cockpit integration (a promotional link to the original author's separate commercial product) -
  out of scope for a personal fork.

---

Entries below this line are inherited from the upstream project's history.

## [1.3.0] - 2026-07-02 (upstream)

### Added
- Manual `/model` switch detection: automatic-fallback alerts only fire when there is no matching
  "Set model to ..." trace in the transcript, so deliberate model switches are followed silently.

## [1.2.0] - 2026-07-02 (upstream)

### Added
- Parallel-session safety: a machine-wide sound cooldown (`CLAUDE_MODEL_ALERT_COOLDOWN`) to avoid
  alarm storms when many sessions switch at once.
- Japanese README.

### Changed
- AGI Cockpit links carry UTM attribution parameters.

## [1.1.0] - 2026-07-02 (upstream)

### Added
- AGI Cockpit integration: alerts shown as an in-app frontmost display when available, falling back
  to macOS Notification Center.

## [1.0.0] - 2026-07-02 (upstream)

### Added
- Initial release: staged sound alerts (Submarine / Morse / Hero) for silent Claude Code model
  fallback on macOS.
