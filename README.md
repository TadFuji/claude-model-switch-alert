# model-switch-alert (Windows port)

Claude Code のモデルが静かに切り替わったことを、サウンドで知らせるプラグインです。

本家 [KaishuShito/claude-model-switch-alert](https://github.com/KaishuShito/claude-model-switch-alert) をフォークし、macOS 専用だった仕組みを Windows（PowerShell）向けに移植したものです。

Fable 5 には、安全分類器がリクエストをフラグすると Opus 4.8 へ自動的に切り替わる仕組みがあります（[Redeploying Fable 5](https://www.anthropic.com/news/redeploying-fable-5)）。切り替えはセッションの途中で静かに起きるため、気づかないまま別のモデルで作業を続けてしまうことがあります。このプラグインは毎ターン終了時に実際の応答モデルを確認し、期待するモデルと違っていればすぐに知らせます。

## アラートの段階設計（鳴り続けない）

| 状況 | 音 | 追加の動作 |
|------|-----|-----------|
| 切り替わった瞬間 | `Windows Critical Stop.wav`（警告音） | 音声読み上げ + Windows通知（バルーン） |
| 切り替わったまま | 短いビープ音（毎ターン） | 画面に警告表示 |
| 元のモデルに復帰 | `tada.wav`（ファンファーレ） | 音声読み上げ + Windows通知（バルーン） |

音はすべて Windows 標準のシステムサウンド（`C:\Windows\Media`）と `Console.Beep` なので、追加セットアップなしで動きます。鳴り続けるアラームは意図的に避け、切り替わったままの間は毎ターン短いビープで知らせ続ける設計にしています。

## 仕組み

Claude Code の hook は標準入力の JSON に現在のモデル ID を含みません。そこで Stop hook がセッションのトランスクリプト（JSONL）を読み、最新のアシスタントメッセージの `.message.model` を取り出します。セッションごとの状態ファイル（`%TEMP%` 以下）で「切り替わった瞬間 / 継続中 / 復帰」を判定します。

サブエージェント（sidechain）の応答は判定から除外しています。Haiku などで動く探索用サブエージェントを誤って「切り替え」と検知することはありません。

## 手動切り替えは通知しない

Fable と Opus を使い分けている場合でも、自分で `/model` を切り替えたときには鳴りません。手動切り替えはトランスクリプトに `Set model to ...` というコマンド出力の痕跡を残すため、これが見つかったときはアラートを出さず、期待モデル（ベースライン）を新しい選択に追従させます。痕跡なしにモデルだけが変わったとき、つまり自動フォールバックのときだけ通知します。

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

## English

Sound alerts for Claude Code when your model silently switches. Fable 5 can fall back to Opus 4.8 when a safety classifier flags a request. A `Stop` hook reads `.message.model` from the session transcript (hook stdin has no model field) and plays staged alerts: a warning sound + voice + Windows balloon notification on switch, a short beep every turn while switched, and a fanfare on recovery. Manual `/model` switches leave a "Set model to" trace in the transcript, so they are skipped silently and the expected baseline follows your choice — only automatic fallbacks alert. All sounds ship with Windows (`C:\Windows\Media`) plus `Console.Beep` — no extra dependencies. Set `CLAUDE_EXPECTED_MODEL` to pin a strict initial baseline.

This is a Windows port, forked from [KaishuShito/claude-model-switch-alert](https://github.com/KaishuShito/claude-model-switch-alert) (originally macOS-only).

## License

MIT
