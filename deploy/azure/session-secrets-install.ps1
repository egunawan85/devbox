# session-secrets-install.ps1 -- install the devbox session-secrets watchdog + its Scheduled
# Task on the Windows box. Run as SYSTEM via `az vm run-command` by os_install_session_secrets.
#
# The watchdog (written verbatim below to C:\ProgramData\devbox\session-secrets.ps1) is the
# Windows analog of the Linux login-time materializer: while user 'eddyg' has >=1 live SSH
# session it materializes each mapped vault project into its app .env; at the last logout it
# wipes them. Windows has no tmpfs, so the .env lands on the encrypted OS disk (spec E8 Windows
# clause), created on first session and deleted on the last -- never persisted while logged out.
#
# Lifecycle is a SYSTEM Scheduled Task with three triggers: every 60s (poll backstop), at boot
# (wipe anything stale from a crash/reboot), and on Security 4624/4634 (logon/logoff -- fast
# materialize/wipe). The operator's secrets.map is pushed to the user profile first (no admin
# needed there) and copied into ProgramData here.
$ErrorActionPreference = 'Stop'
$dir = 'C:\ProgramData\devbox'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
# Lock the dir down (the default %ProgramData% ACL grants BUILTIN\Users read+create). Without
# this a non-admin could read the manifest/state or replace the SYSTEM watchdog script. SYSTEM
# + Administrators full, eddyg read, inheritance off so children inherit. Idempotent with the
# identical lock in vault-service.ps1 (whichever runs first wins; this one runs at `configure`).
icacls $dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' 'eddyg:(OI)(CI)R' | Out-Null

# 1) the watchdog, verbatim (single-quoted here-string: nothing below is expanded now -- it is
#    written as-is and only evaluated when the task runs it).
$watchdog = @'
$ErrorActionPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false } catch {}  # decode bao's UTF-8 JSON faithfully
$user  = 'eddyg'
$dir   = 'C:\ProgramData\devbox'
$map   = Join-Path $dir 'secrets.map'
$envf  = Join-Path $dir 'vault.env'
$state = Join-Path $dir 'materialized.json'
$bao   = 'C:\Program Files\OpenBao\bao.exe'
$log   = Join-Path $dir 'session-secrets.log'
function Log($m) { try { "$([DateTime]::UtcNow.ToString('o')) $m" | Add-Content -Path $log -Encoding ascii } catch {} }
if (-not (Test-Path $map)) { exit 0 }

# count eddyg's live SSH sessions (each per-connection sshd.exe runs as the logged-in user;
# the main sshd service runs as SYSTEM and is not counted). Only count processes whose image
# is the real OpenSSH binary under System32\OpenSSH (a non-admin cannot plant a binary there),
# so a same-context process merely *named* sshd.exe cannot spoof the count up or down.
$sessions = 0
foreach ($p in (Get-CimInstance Win32_Process -Filter "Name='sshd.exe'")) {
  if (-not $p.ExecutablePath -or -not $p.ExecutablePath.ToLower().EndsWith('\system32\openssh\sshd.exe')) { continue }
  $o = Invoke-CimMethod -InputObject $p -MethodName GetOwner
  if ($o -and $o.User -eq $user) { $sessions++ }
}

# parse the manifest ("<proj> <dest>" lines)
$maps = @()
foreach ($line in (Get-Content $map)) {
  $t = $line.Trim(); if (-not $t -or $t[0] -eq '#') { continue }
  $parts = $t -split '\s+', 2
  if ($parts.Count -eq 2) { $maps += [pscustomobject]@{ proj=$parts[0]; dest=$parts[1] } }
}

# what we wrote last time -- drives an exact wipe and the "don't clobber a real file" guard.
$prev = @()
if (Test-Path $state) { try { $prev = @(Get-Content $state -Raw | ConvertFrom-Json) } catch {} }

if ($sessions -lt 1) {
  foreach ($e in $prev) { foreach ($d in @($e.dest)) { try { if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Force } } catch {} } }
  if (Test-Path $state) { Remove-Item $state -Force; Log 'wiped (sessions=0)' }
  exit 0
}

# materialize (>=1 session) -- require the vault to be unsealed.
if (-not (Test-Path $envf)) { Log 'no vault.env yet; skip'; exit 0 }
Get-Content $envf | ForEach-Object { if ($_ -match '^([^=]+)=(.*)$') { Set-Item "env:$($matches[1])" $matches[2] } }
try { if ((Invoke-RestMethod "$($env:BAO_ADDR)/v1/sys/seal-status").sealed) { Log 'vault sealed; skip'; exit 0 } }
catch { Log 'vault down; skip'; exit 0 }

$written = @()
foreach ($m in $maps) {
  $isOurs = [bool]($prev | Where-Object { $_.dest -eq $m.dest })
  if ((Test-Path -LiteralPath $m.dest) -and -not $isOurs) { Log ("skip " + $m.dest + ": exists, not ours"); continue }
  try {
    $j = (& $bao kv get -mount=secret -format=json $m.proj 2>$null | Out-String | ConvertFrom-Json)
    if (-not $j.data.data) { Log ("skip " + $m.proj + ": empty/not loaded"); continue }
    $kv = @($j.data.data.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" })
    $pdir = Split-Path $m.dest -Parent
    if ($pdir -and -not (Test-Path -LiteralPath $pdir)) { New-Item -ItemType Directory -Force -Path $pdir | Out-Null }
    # Write to a temp, lock it, then atomically rename into place: the app never sees a partial
    # file, and the secret never exists at $dest with a permissive (inherited) ACL. UTF-8 no-BOM
    # (not -Encoding ascii, which silently mangles any non-ASCII secret value to '?').
    $tmp = "$($m.dest).devboxtmp"
    [IO.File]::WriteAllLines($tmp, $kv, (New-Object Text.UTF8Encoding $false))
    icacls $tmp /inheritance:r /grant:r "*S-1-5-18:F" "*S-1-5-32-544:F" ("$user" + ":R") 2>&1 | Out-Null
    Move-Item -LiteralPath $tmp -Destination $m.dest -Force
    $written += [pscustomobject]@{ proj=$m.proj; dest=$m.dest }
    # Record what we wrote BEFORE materializing the next one, so a crash never leaves an
    # untracked (and therefore never-wiped) secret file lingering after logout.
    $written | ConvertTo-Json -Compress | Set-Content -LiteralPath $state -Encoding ascii
  } catch { Log ("error " + $m.proj + ": " + $_) }
}
# Drop any file we previously wrote that is no longer mapped. Robust against a malformed/legacy
# state entry whose dest is an array: iterate each dest and compare by set membership, so we
# never Remove-Item an array (that once deleted currently-mapped files) nor a still-mapped dest.
$currDests = @($maps | ForEach-Object { [string]$_.dest })
foreach ($e in $prev) {
  foreach ($d in @($e.dest)) {
    if ($d -and ($currDests -notcontains $d)) { try { Remove-Item -LiteralPath $d -Force } catch {} }
  }
}
$written | ConvertTo-Json -Compress | Set-Content -LiteralPath $state -Encoding ascii
Log ("materialized " + $written.Count + "/" + $maps.Count + " (sessions=" + $sessions + ")")
'@
Set-Content -Path (Join-Path $dir 'session-secrets.ps1') -Value $watchdog -Encoding ascii

# 2) copy the operator manifest (pushed to the user profile by os_install_session_secrets).
$src = 'C:\Users\eddyg\.devbox\secrets.map'
if (Test-Path $src) { Copy-Item $src (Join-Path $dir 'secrets.map') -Force }
elseif (-not (Test-Path (Join-Path $dir 'secrets.map'))) {
  Write-Output '__SSJSON__{"error":"no secrets.map found (push to C:\\Users\\eddyg\\.devbox first)"}__ENDSSJSON__'; exit 1
}

# 3) register the SYSTEM Scheduled Task (poll 60s + boot + logon/logoff). StartBoundary is
#    "a minute ago" so the 60s repetition begins immediately, not only after the next reboot.
$start = (Get-Date).AddMinutes(-1).ToString('yyyy-MM-ddTHH:mm:ss')
$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers>
    <TimeTrigger><Enabled>true</Enabled><StartBoundary>$start</StartBoundary><Repetition><Interval>PT1M</Interval><StopAtDurationEnd>false</StopAtDurationEnd></Repetition></TimeTrigger>
    <BootTrigger><Enabled>true</Enabled><Repetition><Interval>PT1M</Interval><StopAtDurationEnd>false</StopAtDurationEnd></Repetition></BootTrigger>
    <EventTrigger><Enabled>true</Enabled><Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="Security"&gt;&lt;Select Path="Security"&gt;*[System[(EventID=4624 or EventID=4634)]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription></EventTrigger>
  </Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><StartWhenAvailable>true</StartWhenAvailable><ExecutionTimeLimit>PT2M</ExecutionTimeLimit><AllowHardTerminate>true</AllowHardTerminate><Enabled>true</Enabled><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries></Settings>
  <Actions Context="Author"><Exec><Command>powershell.exe</Command><Arguments>-NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\devbox\session-secrets.ps1"</Arguments></Exec></Actions>
</Task>
"@
Unregister-ScheduledTask -TaskName 'devbox-secrets' -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName 'devbox-secrets' -Xml $xml -Force | Out-Null
Start-ScheduledTask -TaskName 'devbox-secrets'
Write-Output '__SSJSON__{"ok":true}__ENDSSJSON__'
