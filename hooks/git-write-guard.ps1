# git-write-guard.ps1 — PreToolUse hook for Bash.
# Emits an "ask" permission decision when a Bash command runs a git WRITE/network
# operation, even when wrapped in git global options (-C <path>, -c key=val,
# --git-dir=, --work-tree=), an absolute path (/usr/bin/git), or env prefixes
# (GIT_DIR=.git git ...). Read-only git (status/log/diff/...) is left silent so it
# flows through the normal "allow Bash" rule. Non-git commands are ignored.
#
# Returns nothing + exit 0 when no gate is needed (defers to normal permission flow).

$ErrorActionPreference = 'Stop'

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
    $data = $raw | ConvertFrom-Json
    $cmd = [string]$data.tool_input.command
} catch { exit 0 }

if ([string]::IsNullOrWhiteSpace($cmd)) { exit 0 }

# git subcommands that write the repo/working-tree/history or hit the network.
$writeSubs = @(
    'push','pull','fetch','clone','merge','commit','rebase','reset','revert',
    'checkout','switch','restore','add','rm','mv','apply','am','cherry-pick',
    'clean','stash'
)

# git global options that consume a following separate argument.
$optWithArg = @('-C','-c','--git-dir','--work-tree','--namespace','--exec-path','--config-env','--super-prefix')

function Get-GitSubcommand([string]$segment) {
    $s = $segment.Trim()
    if ($s -eq '') { return $null }
    # strip leading env-var assignments: FOO=bar BAZ=qux git ...
    while ($s -match '^[A-Za-z_][A-Za-z0-9_]*=[^\s]*\s+(.*)$') { $s = $Matches[1].Trim() }
    $tokens = @($s -split '\s+' | Where-Object { $_ -ne '' })
    if ($tokens.Count -eq 0) { return $null }
    $exe  = $tokens[0].Trim('"').Trim("'")
    $leaf = ($exe -split '[\\/]')[-1]
    if ($leaf -ne 'git' -and $leaf -ne 'git.exe') { return $null }
    $i = 1
    while ($i -lt $tokens.Count) {
        $t = $tokens[$i]
        if ($optWithArg -contains $t) { $i += 2; continue }   # option + its value
        if ($t -like '--*=*')         { $i += 1; continue }   # --opt=value
        if ($t.StartsWith('-'))       { $i += 1; continue }   # other global flags
        return $t.ToLowerInvariant()                          # first non-option = subcommand
    }
    return $null
}

# split a compound command on shell operators ( && || ; | newline )
$segments = [regex]::Split($cmd, '&&|\|\||[;|\n]')
foreach ($seg in $segments) {
    $sub = Get-GitSubcommand $seg
    if ($sub -and ($writeSubs -contains $sub)) {
        $payload = [ordered]@{
            hookSpecificOutput = [ordered]@{
                hookEventName            = 'PreToolUse'
                permissionDecision       = 'ask'
                permissionDecisionReason = "git '$sub' is a write/network operation - requires your approval"
            }
        }
        $payload | ConvertTo-Json -Compress -Depth 5
        exit 0
    }
}

exit 0
