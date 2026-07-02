# model-switch-alert.ps1
# Stop hook: alert when the model actually answering differs from the model the user expects.
# "Expected" = the model most recently requested via /model, else CLAUDE_EXPECTED_MODEL, else the
# session's first observed model. This catches BOTH a mid-session automatic fallback (Fable 5 ->
# Opus 4.8) AND a /model request that a safeguard silently overrides (you ask for Fable 5 but every
# reply is still Opus 4.8). A manual switch that is actually honored stays silent.
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
    foreach ($line in (Get-Content -LiteralPath $TranscriptPath -Tail 200 -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $obj = $line | ConvertFrom-Json } catch { continue }
        if ($obj.type -eq 'assistant' -and -not $obj.isSidechain) {
            $m = $obj.message.model
            if ($m -and -not $m.StartsWith('<')) { $model = $m }
        }
    }
    return $model
}

# The model the user most recently requested via /model, read from the command's confirmation
# trace ("Set model to <name> ..."). This is the user's INTENT and survives a safeguard override:
# when /model asks for Fable 5 but every reply is still Opus 4.8, the request trace is the only
# evidence of what the user actually wanted.
# Only the /model output arrives as a plain string; tool results and other structured content are
# arrays, which we skip - otherwise this script's own comments (which contain the words
# "Set model to") would be misread as a request when the file is read into the transcript.
function Get-RequestedModel {
    param([string]$TranscriptPath)
    $requested = $null
    $esc = [char]27
    foreach ($line in (Get-Content -LiteralPath $TranscriptPath -Tail 2000 -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $obj = $line | ConvertFrom-Json } catch { continue }
        if ($obj.type -ne 'user') { continue }
        $content = $obj.message.content
        if ($content -isnot [string]) { continue }
        $clean = $content -replace "$esc\[[0-9;]*m", ''  # strip ANSI colour codes around the name
        if ($clean -match 'Set model to (.+?)(?: and saved|<|$)') {
            $requested = $matches[1].Trim()
        }
    }
    return $requested
}

# True when the emitted model id is the one the user expects. The expected value may be a model id
# / prefix (claude-fable-5, from CLAUDE_EXPECTED_MODEL or a persisted baseline) or a display name
# ("Fable 5", from a /model trace). Both normalise to a token that is a substring of the emitted
# id ("fable5" is inside "claudefable5"), so a single containment check covers every source.
function Test-ModelMatch {
    param([string]$EmittedModel, [string]$Expected)
    if ([string]::IsNullOrWhiteSpace($EmittedModel) -or [string]::IsNullOrWhiteSpace($Expected)) { return $false }
    $e = ($EmittedModel -replace '[^0-9A-Za-z]', '').ToLowerInvariant()
    $x = ($Expected     -replace '[^0-9A-Za-z]', '').ToLowerInvariant()
    if (-not $e -or -not $x) { return $false }
    return $e.Contains($x)
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

    $requested = Get-RequestedModel -TranscriptPath $transcript

    # Per-session state: line 1 = expected model (the user's intent), line 2 = last emitted model.
    $stateFile = Join-Path $env:TEMP "claude-model-alert-$session.txt"
    $storedBaseline = $null
    $last = $null
    if (Test-Path -LiteralPath $stateFile) {
        $lines = @(Get-Content -LiteralPath $stateFile -Encoding UTF8 -ErrorAction SilentlyContinue)
        if ($lines.Count -ge 1) { $storedBaseline = $lines[0] }
        if ($lines.Count -ge 2) { $last = $lines[1] }
    }

    # The expected model, in priority order: an explicit /model request (strongest signal, and it
    # survives a safeguard override) > the baseline persisted from earlier turns > the
    # CLAUDE_EXPECTED_MODEL override > the first model actually observed this session.
    $expected =
        if ($requested)                     { $requested }
        elseif ($storedBaseline)            { $storedBaseline }
        elseif ($env:CLAUDE_EXPECTED_MODEL) { $env:CLAUDE_EXPECTED_MODEL }
        else                                { $model }

    # On the first turn, treat "last" as the expected model so a first-turn mismatch reads as a
    # fresh switch (strong alert) rather than an ongoing one (beep).
    if (-not $last) { $last = $expected }

    function Save-CurrentState {
        Set-Content -LiteralPath $stateFile -Value @($expected, $model) -Encoding UTF8
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

    $matchesNow  = Test-ModelMatch -EmittedModel $model -Expected $expected
    $matchedLast = Test-ModelMatch -EmittedModel $last  -Expected $expected
    # The user just picked a new model (via /model) that differs from the persisted baseline.
    $baselineChanged = $storedBaseline -and ($expected -ne $storedBaseline)

    if ($matchesNow) {
        if ((-not $matchedLast) -and (-not $baselineChanged)) {
            # Was away from the expected model, now back: recovery. (Suppressed when the baseline
            # just changed, so switching TO a model that is honored never fanfares.)
            if (Test-SoundOk) {
                Invoke-PlaySound -Path $SOUND_RECOVER
                Invoke-Speak -JapaneseText $Messages.voiceRecoveredJa -EnglishText $Messages.voiceRecoveredEn
                Show-Notification -Text ($Messages.notifyRecoveredTemplate -f $expected) -Title $Messages.notifyTitle -Kind 'Info'
            }
            Save-CurrentState
            Write-Output (@{ systemMessage = ($Messages.systemMessageRecoveredTemplate -f $expected) } | ConvertTo-Json -Compress)
            return
        }
        # Expected model is being served (or the user just switched to one that is honored): silent.
        Save-CurrentState
        return
    }

    # Mismatch: the model answering is not the one the user expects.
    if (($model -ne $last) -or $baselineChanged) {
        # A fresh switch away from the expected model - either an automatic fallback or a /model
        # request that a safeguard overrode. Strong alert + sound + voice + balloon notification.
        if (Test-SoundOk) {
            Invoke-PlaySound -Path $SOUND_SWITCH
            Invoke-Speak -JapaneseText $Messages.voiceSwitchedJa -EnglishText $Messages.voiceSwitchedEn
            Show-Notification -Text ($Messages.notifySwitchedTemplate -f $expected, $model) -Title $Messages.notifyTitle -Kind 'Warning'
        }
        Save-CurrentState
        Write-Output (@{ systemMessage = ($Messages.systemMessageSwitchedTemplate -f $expected, $model) } | ConvertTo-Json -Compress)
        return
    }

    # Still on the wrong model: gentle beep every turn until noticed.
    if (Test-SoundOk) {
        try { [Console]::Beep($BEEP_FREQ, $BEEP_MS) } catch {}
    }
    Save-CurrentState
    Write-Output (@{ systemMessage = ($Messages.systemMessageStillSwitchedTemplate -f $model, $expected) } | ConvertTo-Json -Compress)
}

try {
    Invoke-Main
} catch {
    Write-HookErrorLog $_
}
exit 0
