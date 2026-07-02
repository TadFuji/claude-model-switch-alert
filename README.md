# model-switch-alert (Windows port)

[![CI](https://github.com/TadFuji/claude-model-switch-alert/actions/workflows/ci.yml/badge.svg)](https://github.com/TadFuji/claude-model-switch-alert/actions/workflows/ci.yml)
[![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)](https://github.com/TadFuji/claude-model-switch-alert)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Claude Code のモデルが静かに切り替わったことを、サウンドで知らせるプラグインです。

本家 [KaishuShito/claude-model-switch-alert](https://github.com/KaishuShito/claude-model-switch-alert) をフォークし、macOS 専用だった仕組みを Windows（PowerShell）向けに移植したものです。

Fable 5 には、安全分類器がリクエストをフラグすると Opus 4.8 へ自動的に切り替わる仕組みがあります（[Redeploying Fable 5](https://www.anthropic.com/news/redeploying-fable-5)）。切り替えはセッションの途中で静かに起きるため、気づかないまま別のモデルで作業を続けてしまうことがあります。このプラグインは毎ターン終了時に実際の応答モデルを確認し、期待するモデルと違っていればすぐに知らせます。

## 特徴

- 自動切り替わりの瞬間・切り替わったまま・元に戻った瞬間で、それぞれ違う音と Windows 通知（バルーン）を出す
- 自分で `/model` 切り替えたモデルがそのまま使われている間は鳴らない（誤検知を避ける）。ただし `/model` で選んだのに別モデルで応答され続ける「安全機構による横取り」は検知して知らせる
- 並列セッションでアラームが鳴り響かないよう、マシン全体で共有するクールダウンを内蔵
- Windows 標準機能のみで動作。追加インストール一切不要
- [Pester](https://pester.dev/) によるテストと GitHub Actions の CI で継続的に検証

## アラートの段階設計（鳴り続けない）

| 状況 | 音 | 追加の動作 |
|------|-----|-----------|
| 切り替わった瞬間 | `Windows Critical Stop.wav`（警告音） | 音声読み上げ + Windows通知（バルーン） |
| 切り替わったまま | 短いビープ音（毎ターン） | 画面に警告表示 |
| 元のモデルに復帰 | `tada.wav`（ファンファーレ） | 音声読み上げ + Windows通知（バルーン） |

音はすべて Windows 標準のシステムサウンド（`C:\Windows\Media`）と `Console.Beep` なので、追加セットアップなしで動きます。鳴り続けるアラームは意図的に避け、切り替わったままの間は毎ターン短いビープで知らせ続ける設計にしています。

## 仕組み

Claude Code の hook は標準入力の JSON に現在のモデル ID を含みません。そこで Stop hook がセッションのトランスクリプト（JSONL）を読み、最新のアシスタントメッセージの `.message.model`（＝実際に応答したモデル）を取り出します。これを「期待するモデル」と毎ターン照合し、状態ファイル（`%TEMP%` 以下）で「切り替わった瞬間 / 継続中 / 復帰」を判定します。

「期待するモデル」は次の優先順で決まります。(1) 直近に `/model` で要求したモデル（コマンド出力の `Set model to ...` 痕跡から読み取る。表示名と色コードにも対応） (2) 過去ターンから引き継いだベースライン (3) 環境変数 `CLAUDE_EXPECTED_MODEL` (4) セッションで最初に観測したモデル。

サブエージェント（sidechain）の応答は判定から除外しています。Haiku などで動く探索用サブエージェントを誤って「切り替え」と検知することはありません。

## 手動切り替えと「横取り」の違い

Fable と Opus を使い分けている場合でも、自分で `/model` を切り替え、**その要求どおりのモデルで応答されている間は鳴りません**。要求したモデルと実際の応答モデルが一致していれば「意図どおり」とみなすためです。

一方、`/model` で Fable 5 を選んだのに安全機構が Opus 4.8 に差し替え、応答がずっと Opus のまま——という「横取り」は通知します。応答モデルが変わらないので旧来の「モデル名の変化」だけを見る方式では気づけませんでしたが、本プラグインは「要求 vs 実応答」を照合するため、この取りこぼしを検知します。もちろん痕跡なしの自動フォールバックも従来どおり通知します。

## 並列セッションでも鳴り響かない

多数のセッションを並列で走らせている場合、そのうち複数が同時に切り替わると、素朴な実装ではアラートが連発します。これを避けるため、音と通知にはマシン全体で共有するクールダウン（デフォルト 30 秒）を設けています。最初の 1 件だけが音を鳴らし、残りは画面表示のみになります。

```powershell
$env:CLAUDE_MODEL_ALERT_COOLDOWN = "60"   # 秒。0 で無効化
```

## 動作要件

- Windows（PowerShell 5.1 以降、追加インストール不要）

## インストール

### 1. マーケットプレイスを追加

```
/plugin marketplace add TadFuji/claude-model-switch-alert
```

### 2. プラグインをインストール

```
/plugin install model-switch-alert@tadfuji-market
```

### 3. Claude Code を再起動

## 設定

期待するモデル（ベースライン）は、デフォルトでは**セッション開始時のモデル**になり、以降は手動の `/model` 切り替えに追従します。モデル設定に関わらずそのまま使えます。

セッション開始時点の期待モデルを明示したい場合は、環境変数で指定できます（`setx` で永続化するか、Claude Code を起動するプロセスの環境変数として設定してください）。

```powershell
setx CLAUDE_EXPECTED_MODEL "claude-fable-5"
```

この値で始まるモデル ID が初期ベースラインになります（手動切り替え時はこの場合も追従します）。

## アンインストール

```
/plugin uninstall model-switch-alert@tadfuji-market
```

## 開発・テスト

このリポジトリには [Pester](https://pester.dev/)（PowerShell 標準のテストフレームワーク）によるテスト（`scripts/model-switch-alert.tests.ps1`）と、GitHub Actions による CI（Lint: PSScriptAnalyzer / Test: Pester）が用意されています。

```powershell
# Pester が無ければ導入
Install-Module Pester -Force -Scope CurrentUser

# テスト実行
Invoke-Pester -Path .\scripts\model-switch-alert.tests.ps1
```

貢献方法は [CONTRIBUTING.md](CONTRIBUTING.md) を、変更履歴は [CHANGELOG.md](CHANGELOG.md) を参照してください。

## English

Sound alerts for Claude Code when your model silently switches. Fable 5 can fall back to Opus 4.8 when a safety classifier flags a request. A `Stop` hook reads `.message.model` from the session transcript (hook stdin has no model field) and plays staged alerts: a warning sound + voice + Windows balloon notification on switch, a short beep every turn while switched, and a fanfare on recovery. Manual `/model` switches leave a "Set model to" trace in the transcript, so they are skipped silently and the expected baseline follows your choice — only automatic fallbacks alert. All sounds ship with Windows (`C:\Windows\Media`) plus `Console.Beep` — no extra dependencies. Set `CLAUDE_EXPECTED_MODEL` to pin a strict initial baseline.

This is a Windows port, forked from [KaishuShito/claude-model-switch-alert](https://github.com/KaishuShito/claude-model-switch-alert) (originally macOS-only). Covered by a Pester test suite and GitHub Actions CI (lint + tests) - see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. See [LICENSE](LICENSE). [CHANGELOG.md](CHANGELOG.md) has the full version history.
