# model-switch-alert.ps1
# Stop hook: detect AUTOMATIC model fallback (e.g. Fable 5 -> Opus 4.8) and alert (Windows port).
# Manual switches via /model are recognized from their transcript trace ("Set model to ...")
# and skipped silently - the expected baseline follows the user's choice.
# Staged alerts: switch moment = alert sound + voice + balloon notification /
#                while switched = short beep every turn / recovery = fanfare.
# Forked from https://github.com/KaishuShito/claude-model-switch-alert (Windows port by TadFuji).
# See: https://www.anthropic.com/news/redeploying-fable-5

$ErrorActionPreference = "Stop"
[Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$ErrorLog = Join-Path $env:TEMP "claude-model-alert-error.log"

function Write-HookErrorLog {
    param($Message)
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [model-switch-alert] $Message" |
        Add-Content -Path $ErrorLog -Encoding UTF8 -ErrorAction SilentlyContinue
}

# Hook stdin has no model field; read the latest assistant message's model from the transcript.
# Excludes sidechain (subagent) messages: subagents may legitimately run on other models
# (e.g. Haiku-powered explorers) and must not trigger a false alarm.
function Get-LatestModel {
    param([string]$TranscriptPath)
    $model = $null
    Get-Content -LiteralPath $TranscriptPath -Tail 200 -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object {
        if ([string]::IsNullOrWhiteSpace($_)) { return }
        try { $obj = $_ | ConvertFrom-Json } catch { return }
        if ($obj.type -eq 'assistant' -and -not $obj.isSidechain) {
            $m = $obj.message.model
            if ($m -and -not $m.StartsWith('<')) { $model = $m }
        }
    }
    return $model
}

# Detect a manual model switch: a user-side trace like "Set model to ..." (the
# /model command output) appearing after the last assistant message that used a
# model different from the current one. Automatic fallbacks leave no such trace.
function Test-ManualSwitch {
    param([string]$TranscriptPath, [string]$NewModel)
    $events = @()
    Get-Content -LiteralPath $TranscriptPath -Tail 2000 -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object {
        if ([string]::IsNullOrWhiteSpace($_)) { return }
        try { $obj = $_ | ConvertFrom-Json } catch { return }
        if ($obj.type -eq 'assistant' -and -not $obj.isSidechain) {
            $events += if ($obj.message.model -eq $NewModel) { 'same' } else { 'diff' }
        } elseif ($obj.type -eq 'user') {
            $content = $obj.message.content
            if ($null -eq $content) { $content = '' }
            if ($content -isnot [string]) {
                try { $content = $content | ConvertTo-Json -Compress -Depth 10 } catch { $content = '' }
            }
            if ($content.Contains('Set model to') -or $content.Contains('<command-name>/model') -or $content.Contains('<command-name>/fast')) {
                $events += 'M'
            }
        }
    }
    $lastDiff = -1
    for ($j = 0; $j -lt $events.Count; $j++) {
        if ($events[$j] -eq 'diff') { $lastDiff = $j }
    }
    for ($j = $lastDiff + 1; $j -lt $events.Count; $j++) {
        if ($events[$j] -eq 'M') { return $true }
    }
    return $false
}

function Invoke-PlaySound {
    param([string]$Path)
    try {
        if (Test-Path -LiteralPath $Path) {
            (New-Object System.Media.SoundPlayer $Path).PlaySync()
        }
    } catch {}
}

function Invoke-Speak {
    param([string]$JapaneseText, [string]$EnglishText)
    try {
        Add-Type -AssemblyName System.Speech -ErrorAction Stop
        $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
        $jaVoice = $synth.GetInstalledVoices() |
            Where-Object { $_.VoiceInfo.Culture.TwoLetterISOLanguageName -eq 'ja' } |
            Select-Object -First 1
        if ($jaVoice) {
            $synth.SelectVoice($jaVoice.VoiceInfo.Name)
            $synth.Speak($JapaneseText)
        } else {
            $synth.Speak($EnglishText)
        }
        $synth.Dispose()
    } catch {}
}

# Windows balloon notification - same pattern as the user's existing stop-notify.ps1 hook.
function Show-Notification {
    param([string]$Text, [string]$Title, [ValidateSet('Warning', 'Info')][string]$Kind = 'Warning')
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $sysIcon = if ($Kind -eq 'Warning') { [System.Drawing.SystemIcons]::Warning } else { [System.Drawing.SystemIcons]::Information }
        $balloon = New-Object System.Windows.Forms.NotifyIcon
        $balloon.Icon = $sysIcon
        $balloon.BalloonTipIcon = $Kind
        $balloon.BalloonTipTitle = $Title
        $balloon.BalloonTipText = $Text
        $balloon.Visible = $true
        $balloon.ShowBalloonTip(5000)
        Start-Sleep -Milliseconds 500
        $balloon.Dispose()
    } catch {}
}

function Invoke-Main {
    # All user-facing Japanese/emoji text lives in messages.json, not in this file.
    # Windows PowerShell 5.1 parses .ps1 source using the system codepage (Shift-JIS on
    # Japanese Windows) when there is no BOM, which corrupts multi-byte characters embedded
    # directly in the script. messages.json is read explicitly as UTF-8 at runtime instead.
    $messagesPath = Join-Path $PSScriptRoot "messages.json"
    $Messages = Get-Content -LiteralPath $messagesPath -Encoding UTF8 -Raw | ConvertFrom-Json

    $inputJson = [Console]::In.ReadToEnd()
    $payload = $inputJson | ConvertFrom-Json

    $transcript = $payload.transcript_path
    $session = if ($payload.session_id) { $payload.session_id } else { "unknown" }

    if (-not $transcript -or -not (Test-Path -LiteralPath $transcript -PathType Leaf)) { return }

    # Built-in Windows system sounds - ship with every Windows install, no extra setup needed.
    $SOUND_SWITCH = "C:\Windows\Media\Windows Critical Stop.wav"
    $SOUND_RECOVER = "C:\Windows\Media\tada.wav"
    $BEEP_FREQ = 880
    $BEEP_MS = 150

    $model = Get-LatestModel -TranscriptPath $transcript
    if (-not $model) { return }

    # Per-session state: line 1 = baseline (the model the user chose), line 2 = last seen model.
    # The baseline starts as CLAUDE_EXPECTED_MODEL (if set) or the session's first observed model,
    # and follows manual /model switches. Alerts fire only when the model leaves the baseline
    # without a manual-switch trace.
    $stateFile = Join-Path $env:TEMP "claude-model-alert-$session.txt"
    $baseline = $null
    $last = $null
    if (Test-Path -LiteralPath $stateFile) {
        $lines = @(Get-Content -LiteralPath $stateFile -Encoding UTF8 -ErrorAction SilentlyContinue)
        if ($lines.Count -ge 1) { $baseline = $lines[0] }
        if ($lines.Count -ge 2) { $last = $lines[1] }
    }
    if (-not $baseline) { $baseline = if ($env:CLAUDE_EXPECTED_MODEL) { $env:CLAUDE_EXPECTED_MODEL } else { $model } }
    if (-not $last) { $last = $baseline }

    function Save-CurrentState {
        Set-Content -LiteralPath $stateFile -Value @($baseline, $model) -Encoding UTF8
    }

    # Machine-wide sound cooldown: with many parallel sessions, individual per-session alerts
    # would stack into an alarm storm. Only the first alert within the window makes noise.
    # Set CLAUDE_MODEL_ALERT_COOLDOWN=0 to disable.
    $gateFile = Join-Path $env:TEMP "claude-model-alert-sound-gate.txt"
    $cooldown = if ($env:CLAUDE_MODEL_ALERT_COOLDOWN) { [int]$env:CLAUDE_MODEL_ALERT_COOLDOWN } else { 30 }

    function Test-SoundOk {
        if ($cooldown -le 0) { return $true }
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $lastSound = 0L
        if (Test-Path -LiteralPath $gateFile) {
            $raw = Get-Content -LiteralPath $gateFile -Encoding UTF8 -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($raw -match '^\d+$') { $lastSound = [int64]$raw }
        }
        if (($now - $lastSound) -lt $cooldown) { return $false }
        Set-Content -LiteralPath $gateFile -Value $now -Encoding UTF8
        return $true
    }

    if ($model.StartsWith($baseline)) {
        if (-not $last.StartsWith($baseline)) {
            # Was switched away, now back at baseline: recovery.
            if (Test-SoundOk) {
                Invoke-PlaySound -Path $SOUND_RECOVER
                Invoke-Speak -JapaneseText $Messages.voiceRecoveredJa -EnglishText $Messages.voiceRecoveredEn
                Show-Notification -Text ($Messages.notifyRecoveredTemplate -f $baseline) -Title $Messages.notifyTitle -Kind 'Info'
            }
            Save-CurrentState
            Write-Output (@{ systemMessage = ($Messages.systemMessageRecoveredTemplate -f $baseline) } | ConvertTo-Json -Compress)
            return
        }
        Save-CurrentState
        return
    }

    if ($model -ne $last) {
        if (Test-ManualSwitch -TranscriptPath $transcript -NewModel $model) {
            # The user switched models on purpose; follow silently.
            $baseline = $model
            Save-CurrentState
            return
        }
        # Automatic switch: strong alert + sound + voice + balloon notification.
        if (Test-SoundOk) {
            Invoke-PlaySound -Path $SOUND_SWITCH
            Invoke-Speak -JapaneseText $Messages.voiceSwitchedJa -EnglishText $Messages.voiceSwitchedEn
            Show-Notification -Text ($Messages.notifySwitchedTemplate -f $baseline, $model) -Title $Messages.notifyTitle -Kind 'Warning'
        }
        Save-CurrentState
        Write-Output (@{ systemMessage = ($Messages.systemMessageSwitchedTemplate -f $baseline, $model) } | ConvertTo-Json -Compress)
        return
    }

    # Still switched: gentle beep every turn until noticed.
    if (Test-SoundOk) {
        [Console]::Beep($BEEP_FREQ, $BEEP_MS)
    }
    Save-CurrentState
    Write-Output (@{ systemMessage = ($Messages.systemMessageStillSwitchedTemplate -f $model, $baseline) } | ConvertTo-Json -Compress)
}

try {
    Invoke-Main
} catch {
    Write-HookErrorLog $_
}
exit 0
