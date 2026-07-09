<#
    Pester 5 tests for model-switch-alert.ps1.

    The script under test reads real stdin via [Console]::In.ReadToEnd(), so it
    must be exercised as a genuine child process (powershell.exe -File ...) with
    real stdin redirection - dot-sourcing it would not exercise that code path.

    CLAUDE_MODEL_ALERT_COOLDOWN is forced to a huge value and the *shared*
    sound-gate file ($env:TEMP\claude-model-alert-sound-gate.txt) is pre-seeded
    with "now" for the whole run. Test-SoundOk in the script gates on elapsed
    time since that file's timestamp, and on a machine where the gate file does
    not yet exist it would otherwise return $true on the very first alert (its
    "never played before" fallback is Unix epoch 0, which always looks stale).
    Seeding it here guarantees Test-SoundOk returns $false for every call in
    this run, so the script never reaches PlaySync/Speak/Beep/NotifyIcon.
    Assertions only ever look at the systemMessage JSON and the per-session
    state file, never at whether a sound played.
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot 'model-switch-alert.ps1'

    # The child process writes UTF-8 to stdout ([Console]::OutputEncoding = UTF8
    # inside the script). Unless the parent's console encoding matches, PowerShell
    # captures those bytes with the system codepage and produces mojibake that
    # breaks ConvertFrom-Json on the captured output.
    $script:OriginalOutputEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

    $script:OriginalCooldown = $env:CLAUDE_MODEL_ALERT_COOLDOWN
    $env:CLAUDE_MODEL_ALERT_COOLDOWN = "999999"

    # The script under test falls back to CLAUDE_EXPECTED_MODEL when a session has no baseline
    # yet. On a machine where that variable is set globally (as on the author's), the first-run
    # test would inherit it and see a mismatch instead of a silent baseline - isolate it.
    $script:OriginalExpectedModel = $env:CLAUDE_EXPECTED_MODEL
    Remove-Item Env:\CLAUDE_EXPECTED_MODEL -ErrorAction SilentlyContinue

    $script:GateFile = Join-Path $env:TEMP 'claude-model-alert-sound-gate.txt'
    $script:GateFileExisted = Test-Path -LiteralPath $script:GateFile
    if ($script:GateFileExisted) {
        $script:OriginalGateContent = Get-Content -LiteralPath $script:GateFile -Raw
    }
    Set-Content -LiteralPath $script:GateFile -Value ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) -Encoding UTF8

    $script:SessionIds = [System.Collections.Generic.List[string]]::new()

    function script:New-TestSessionId {
        $id = "pester-$([guid]::NewGuid().ToString('N'))"
        $script:SessionIds.Add($id)
        return $id
    }

    function script:Get-SessionStateFile {
        param([string]$SessionId)
        Join-Path $env:TEMP "claude-model-alert-$SessionId.txt"
    }

    # Pre-seeds a session's state file in the same two-line (baseline, last)
    # format the script itself writes via Save-CurrentState, so tests can set
    # up "already switched" preconditions without chaining prior script calls.
    function script:Set-SessionState {
        param([string]$SessionId, [string]$Baseline, [string]$Last)
        Set-Content -LiteralPath (Get-SessionStateFile $SessionId) -Value @($Baseline, $Last) -Encoding UTF8
    }

    function script:New-AssistantLine {
        param([string]$Model, [switch]$Sidechain)
        @{ type = 'assistant'; isSidechain = [bool]$Sidechain; message = @{ model = $Model } } | ConvertTo-Json -Compress
    }

    function script:New-UserLine {
        param([string]$Content)
        @{ type = 'user'; message = @{ content = $Content } } | ConvertTo-Json -Compress
    }

    # A tool_result user turn: content is an array, not a string. The script must ignore any
    # "Set model to" text here (e.g. this script's own source read into the transcript) so it is
    # never mistaken for a real /model request.
    function script:New-ToolResultUserLine {
        param([string]$Text)
        @{ type = 'user'; message = @{ content = @(@{ tool_use_id = 'toolu_x'; type = 'tool_result'; content = $Text }) } } | ConvertTo-Json -Compress -Depth 10
    }

    function script:New-TranscriptFile {
        param([string[]]$Lines)
        $path = Join-Path $TestDrive "transcript-$([guid]::NewGuid().ToString('N')).jsonl"
        Set-Content -LiteralPath $path -Value $Lines -Encoding UTF8
        return $path
    }

    # Runs the real script as a child process. Pass -RawStdin to send exact
    # (possibly empty/malformed) text; otherwise a valid payload is built from
    # -TranscriptPath/-SessionId.
    function script:Invoke-ModelSwitchAlert {
        param([string]$TranscriptPath, [string]$SessionId, [string]$RawStdin)
        $stdin = if ($PSBoundParameters.ContainsKey('RawStdin')) {
            $RawStdin
        } else {
            @{ transcript_path = $TranscriptPath; session_id = $SessionId } | ConvertTo-Json -Compress
        }
        $stdout = $stdin | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:ScriptPath
        [pscustomobject]@{
            Stdout   = ($stdout -join "`n")
            ExitCode = $LASTEXITCODE
        }
    }
}

AfterAll {
    [Console]::OutputEncoding = $script:OriginalOutputEncoding

    if ($null -ne $script:OriginalCooldown) {
        $env:CLAUDE_MODEL_ALERT_COOLDOWN = $script:OriginalCooldown
    } else {
        Remove-Item Env:\CLAUDE_MODEL_ALERT_COOLDOWN -ErrorAction SilentlyContinue
    }

    if ($null -ne $script:OriginalExpectedModel) {
        $env:CLAUDE_EXPECTED_MODEL = $script:OriginalExpectedModel
    }

    if ($script:GateFileExisted) {
        Set-Content -LiteralPath $script:GateFile -Value $script:OriginalGateContent -Encoding UTF8
    } else {
        Remove-Item -LiteralPath $script:GateFile -ErrorAction SilentlyContinue
    }

    foreach ($id in $script:SessionIds) {
        Remove-Item -LiteralPath (Get-SessionStateFile $id) -ErrorAction SilentlyContinue
    }
}

Describe 'model-switch-alert.ps1' {

    Context 'first run for a session' {
        It 'establishes the baseline silently and writes baseline = last = current model' {
            $session = New-TestSessionId
            $transcript = New-TranscriptFile -Lines @( (New-AssistantLine -Model 'claude-model-a') )

            $result = Invoke-ModelSwitchAlert -TranscriptPath $transcript -SessionId $session

            $result.ExitCode | Should -Be 0
            $result.Stdout | Should -BeNullOrEmpty

            $stateFile = Get-SessionStateFile -SessionId $session
            Test-Path -LiteralPath $stateFile | Should -BeTrue
            $lines = @(Get-Content -LiteralPath $stateFile)
            $lines[0] | Should -Be 'claude-model-a'
            $lines[1] | Should -Be 'claude-model-a'
        }
    }

    Context 'automatic model switch (no manual /model trace)' {
        It 'prints a switched systemMessage, keeps baseline, and updates last to the new model' {
            $session = New-TestSessionId
            Set-SessionState -SessionId $session -Baseline 'claude-model-a' -Last 'claude-model-a'
            $transcript = New-TranscriptFile -Lines @(
                (New-AssistantLine -Model 'claude-model-a'),
                (New-AssistantLine -Model 'claude-model-b')
            )

            $result = Invoke-ModelSwitchAlert -TranscriptPath $transcript -SessionId $session

            $result.ExitCode | Should -Be 0
            $result.Stdout | Should -Not -BeNullOrEmpty
            $json = $result.Stdout | ConvertFrom-Json
            $json.systemMessage | Should -Match ([regex]::Escape('claude-model-a'))
            $json.systemMessage | Should -Match ([regex]::Escape('claude-model-b'))

            $lines = @(Get-Content -LiteralPath (Get-SessionStateFile $session))
            $lines[0] | Should -Be 'claude-model-a'
            $lines[1] | Should -Be 'claude-model-b'
        }
    }

    Context 'ongoing switched state' {
        It 'prints a still-switched systemMessage on every call while the fallback model persists' {
            $session = New-TestSessionId
            Set-SessionState -SessionId $session -Baseline 'claude-model-a' -Last 'claude-model-b'
            $transcript = New-TranscriptFile -Lines @( (New-AssistantLine -Model 'claude-model-b') )

            foreach ($attempt in 1..2) {
                $result = Invoke-ModelSwitchAlert -TranscriptPath $transcript -SessionId $session
                $result.ExitCode | Should -Be 0
                $result.Stdout | Should -Not -BeNullOrEmpty
                $json = $result.Stdout | ConvertFrom-Json
                $json.systemMessage | Should -Match ([regex]::Escape('claude-model-b'))
                $json.systemMessage | Should -Match ([regex]::Escape('claude-model-a'))
            }

            $lines = @(Get-Content -LiteralPath (Get-SessionStateFile $session))
            $lines[0] | Should -Be 'claude-model-a'
            $lines[1] | Should -Be 'claude-model-b'
        }
    }

    Context 'recovery to baseline' {
        It 'prints a recovered systemMessage and resets last to the baseline model' {
            $session = New-TestSessionId
            Set-SessionState -SessionId $session -Baseline 'claude-model-a' -Last 'claude-model-b'
            $transcript = New-TranscriptFile -Lines @( (New-AssistantLine -Model 'claude-model-a') )

            $result = Invoke-ModelSwitchAlert -TranscriptPath $transcript -SessionId $session

            $result.ExitCode | Should -Be 0
            $result.Stdout | Should -Not -BeNullOrEmpty
            $json = $result.Stdout | ConvertFrom-Json
            $json.systemMessage | Should -Match ([regex]::Escape('claude-model-a'))

            $lines = @(Get-Content -LiteralPath (Get-SessionStateFile $session))
            $lines[0] | Should -Be 'claude-model-a'
            $lines[1] | Should -Be 'claude-model-a'
        }
    }

    Context 'manual switch via /model' {
        It 'stays silent and reassigns baseline to the new model when the transcript shows a manual switch trace' {
            $session = New-TestSessionId
            Set-SessionState -SessionId $session -Baseline 'claude-model-a' -Last 'claude-model-a'
            $transcript = New-TranscriptFile -Lines @(
                (New-AssistantLine -Model 'claude-model-a'),
                (New-UserLine -Content 'Set model to claude-model-b'),
                (New-AssistantLine -Model 'claude-model-b')
            )

            $result = Invoke-ModelSwitchAlert -TranscriptPath $transcript -SessionId $session

            $result.ExitCode | Should -Be 0
            $result.Stdout | Should -BeNullOrEmpty

            $lines = @(Get-Content -LiteralPath (Get-SessionStateFile $session))
            $lines[0] | Should -Be 'claude-model-b'
            $lines[1] | Should -Be 'claude-model-b'
        }
    }

    Context 'manual /model request overridden by a safeguard (requested != served)' {
        It 'alerts instead of staying silent, and records the requested model as the expected baseline' {
            $session = New-TestSessionId
            # Session started on model-a; the user then asks for model-b but every reply is still model-a.
            Set-SessionState -SessionId $session -Baseline 'claude-model-a' -Last 'claude-model-a'
            $transcript = New-TranscriptFile -Lines @(
                (New-AssistantLine -Model 'claude-model-a'),
                (New-UserLine -Content 'Set model to claude-model-b and saved as your default for new sessions'),
                (New-AssistantLine -Model 'claude-model-a')
            )

            $result = Invoke-ModelSwitchAlert -TranscriptPath $transcript -SessionId $session

            $result.ExitCode | Should -Be 0
            $result.Stdout | Should -Not -BeNullOrEmpty
            $json = $result.Stdout | ConvertFrom-Json
            $json.systemMessage | Should -Match ([regex]::Escape('claude-model-b'))  # the model the user wanted
            $json.systemMessage | Should -Match ([regex]::Escape('claude-model-a'))  # the model actually serving

            $lines = @(Get-Content -LiteralPath (Get-SessionStateFile $session))
            $lines[0] | Should -Be 'claude-model-b'
            $lines[1] | Should -Be 'claude-model-a'
        }
    }

    Context 'manual /model request that is honored (display name + ANSI codes)' {
        It 'stays silent when the served model matches the requested display name' {
            $session = New-TestSessionId
            Set-SessionState -SessionId $session -Baseline 'claude-opus-4-8' -Last 'claude-opus-4-8'
            $esc = [char]27
            $transcript = New-TranscriptFile -Lines @(
                (New-AssistantLine -Model 'claude-opus-4-8'),
                (New-UserLine -Content "<local-command-stdout>Set model to $esc[1mFable 5$esc[22m and saved as your default for new sessions</local-command-stdout>"),
                (New-AssistantLine -Model 'claude-fable-5')
            )

            $result = Invoke-ModelSwitchAlert -TranscriptPath $transcript -SessionId $session

            $result.ExitCode | Should -Be 0
            $result.Stdout | Should -BeNullOrEmpty

            $lines = @(Get-Content -LiteralPath (Get-SessionStateFile $session))
            $lines[0] | Should -Be 'Fable 5'
            $lines[1] | Should -Be 'claude-fable-5'
        }
    }

    Context 'false-positive guard' {
        It 'ignores "Set model to" text that appears inside a tool result, not a real /model trace' {
            $session = New-TestSessionId
            Set-SessionState -SessionId $session -Baseline 'claude-model-a' -Last 'claude-model-a'
            $transcript = New-TranscriptFile -Lines @(
                (New-AssistantLine -Model 'claude-model-a'),
                (New-ToolResultUserLine -Text '# Manual switches via /model ... ("Set model to claude-model-b")'),
                (New-AssistantLine -Model 'claude-model-a')
            )

            $result = Invoke-ModelSwitchAlert -TranscriptPath $transcript -SessionId $session

            $result.ExitCode | Should -Be 0
            $result.Stdout | Should -BeNullOrEmpty

            $lines = @(Get-Content -LiteralPath (Get-SessionStateFile $session))
            $lines[0] | Should -Be 'claude-model-a'
            $lines[1] | Should -Be 'claude-model-a'
        }
    }

    Context 'resilience' {
        It 'exits 0 and produces no output when transcript_path does not exist' {
            $payload = @{ transcript_path = 'C:\nonexistent\path.jsonl'; session_id = 'x' } | ConvertTo-Json -Compress

            $result = Invoke-ModelSwitchAlert -RawStdin $payload

            $result.ExitCode | Should -Be 0
            $result.Stdout | Should -BeNullOrEmpty
        }

        It 'exits 0 without throwing when stdin is empty' {
            $result = Invoke-ModelSwitchAlert -RawStdin ''

            $result.ExitCode | Should -Be 0
            $result.Stdout | Should -BeNullOrEmpty
        }

        It 'exits 0 without throwing when stdin is malformed JSON' {
            $result = Invoke-ModelSwitchAlert -RawStdin '{not valid json'

            $result.ExitCode | Should -Be 0
            $result.Stdout | Should -BeNullOrEmpty
        }
    }
}
