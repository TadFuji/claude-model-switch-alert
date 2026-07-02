@{
    # Applies to scripts/*.ps1 via CI (see .github/workflows/ci.yml).
    Severity = @('Error', 'Warning', 'Information')

    ExcludeRules = @(
        # Sound/notification/voice helpers are deliberately fire-and-forget: a hook must
        # never block or crash Claude Code because the machine has no speakers, no Japanese
        # voice installed, or a flaky NotifyIcon. Empty catch blocks are the intended design,
        # not an oversight - see Invoke-PlaySound / Invoke-Speak / Show-Notification.
        'PSAvoidUsingEmptyCatchBlock'
    )
}
