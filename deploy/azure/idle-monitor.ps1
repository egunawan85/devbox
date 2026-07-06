# idle-monitor.ps1 -- install the win-test appliance's self-deallocation watcher (spec L3/L4).
#
# TEMPLATE rendered by the devbox CLI (os_install_idle_monitor substitutes __IDLE_MINUTES__),
# then run on the box via `az vm run-command` (as SYSTEM). Appliance profiles only -- the CLI
# gates the install on IDLE_MINUTES being set in the profile conf, because a box that turns
# itself off is right for a test appliance and wrong for a workspace.
#
# What it installs: C:\ProgramData\devbox\idle-monitor.ps1 (the watcher below) plus a
# scheduled task (SYSTEM, every 5 min) that runs it. The watcher deallocates the VM when no
# test run is ACTIVE and the box has been IDLE past the threshold:
#   active = the win-test run lock (C:\ci\.win-test\run.lock) is held by a LIVE handle --
#            probed by an exclusive open, so a lock file leaked by a hard-killed run does
#            not pin the box forever (it is cleaned up and logged instead);
#   idle   = the newer of the run heartbeat (C:\ci\.win-test\last-activity) and the OS boot
#            time is older than IDLE_MINUTES -- boot time so a freshly started box gets a
#            full grace window before its first heartbeat.
# Deallocation is a control-plane ARM call (billing stops, spec L5) made with the VM's
# system-assigned managed identity via IMDS -- no credential is stored on the box, and the
# subscription/RG/name are self-discovered. The CLI grants that identity a single-action
# custom role (deallocate only) scoped to this one VM.
#
# Markers mirror toolchain.ps1: C:\devbox-idlemon-ready written only on success (cleared up
# front so the CLI's post-run check reflects THIS run), C:\devbox-idlemon-rev written by the
# CLI with the rendered script's hash for convergence. Logs: C:\devbox-idle-monitor-install.log
# (this installer) and C:\devbox-idle-monitor.log (the watcher).
$ErrorActionPreference = 'Stop'
Start-Transcript -Path 'C:\devbox-idle-monitor-install.log' -Append | Out-Null
try {
  Remove-Item -Path 'C:\devbox-idlemon-ready','C:\devbox-idlemon-rev' -Force -ErrorAction SilentlyContinue

  $dir = 'C:\ProgramData\devbox'
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $watcher = Join-Path $dir 'idle-monitor.ps1'

  # --- the watcher, verbatim (single-quoted here-string: nothing below interpolates) ---
  $body = @'
# idle-monitor.ps1 (watcher) -- deallocate this VM when no win-test run is active and the
# box has idled past -IdleMinutes. Installed + scheduled by deploy/azure/idle-monitor.ps1;
# see that file (in the devbox repo) for the design. Runs as SYSTEM every 5 minutes.
param([int]$IdleMinutes = 20)
$ErrorActionPreference = 'Stop'
$log = 'C:\devbox-idle-monitor.log'
function Log([string]$m) { Add-Content -Path $log -Value ("{0} {1}" -f (Get-Date -Format o), $m) }
# Cap the log: one rotation keeps the last ~1MB of history without unbounded growth.
if ((Test-Path $log) -and ((Get-Item $log).Length -gt 1MB)) { Move-Item -Force $log "$log.1" }

try {
  $lock = 'C:\ci\.win-test\run.lock'
  $hb   = 'C:\ci\.win-test\last-activity'

  # 1. Active run? The runner holds the lock file open with Share=None, so an exclusive
  #    open FAILS while a run (or queued run) is live. If the open succeeds the file is a
  #    leak from a hard-killed run: remove it so it neither pins the box (L4) nor blocks
  #    the next run's CreateNew.
  if (Test-Path $lock) {
    try {
      $h = [System.IO.File]::Open($lock, 'Open', 'ReadWrite', 'None')
      $h.Close()
      Remove-Item -Path $lock -Force
      Log "stale run.lock removed (file present, no live holder)"
    } catch [System.IO.IOException] {
      Log "run active (lock held) -- staying up"
      exit 0
    }
  }

  # 2. Idle? Measure from the heartbeat or the boot time, whichever is newer -- a box that
  #    just started gets IdleMinutes of grace even before any run touches the heartbeat.
  $since = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
  if ((Test-Path $hb) -and ((Get-Item $hb).LastWriteTime -gt $since)) { $since = (Get-Item $hb).LastWriteTime }
  $idleMin = ((Get-Date) - $since).TotalMinutes
  if ($idleMin -lt $IdleMinutes) {
    Log ("idle {0:n1} min < {1} -- staying up" -f $idleMin, $IdleMinutes)
    exit 0
  }

  # 3. Deallocate self: IMDS supplies identity token + this VM's own coordinates; ARM does
  #    the deallocate (a real deallocate, so billing stops -- not an OS shutdown).
  Log ("idle {0:n1} min >= {1} -- deallocating" -f $idleMin, $IdleMinutes)
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $md  = Invoke-RestMethod -Headers @{Metadata='true'} -Uri 'http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01'
  $tok = (Invoke-RestMethod -Headers @{Metadata='true'} -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fmanagement.azure.com%2F').access_token
  $uri = "https://management.azure.com/subscriptions/$($md.subscriptionId)/resourceGroups/$($md.resourceGroupName)/providers/Microsoft.Compute/virtualMachines/$($md.name)/deallocate?api-version=2024-07-01"
  Invoke-RestMethod -Method Post -Headers @{Authorization = "Bearer $tok"} -Uri $uri -ContentType 'application/json' | Out-Null
  Log "deallocate requested via ARM"
} catch {
  # Never crash the task: a failed check just waits for the next 5-min tick.
  Log ("ERROR: {0}" -f $_)
  exit 0
}
'@
  Set-Content -Path $watcher -Value $body -Encoding ascii
  Write-Output "watcher written: $watcher"

  # --- schedule it: SYSTEM, every 5 minutes, survives reboots (schtasks is idempotent
  #     with /F and far less finicky than Register-ScheduledTask repetition objects) ---
  $tr = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $watcher -IdleMinutes __IDLE_MINUTES__"
  & schtasks.exe /Create /F /TN 'devbox-idle-monitor' /SC MINUTE /MO 5 /RU SYSTEM /RL HIGHEST /TR $tr
  if ($LASTEXITCODE -ne 0) { throw "schtasks create failed: exit $LASTEXITCODE" }
  Write-Output "scheduled task devbox-idle-monitor registered (every 5 min, IdleMinutes=__IDLE_MINUTES__)"

  Set-Content -Path 'C:\devbox-idlemon-ready' -Value (Get-Date -Format o) -Encoding ascii
  Write-Output 'devbox idle-monitor install complete'
} catch {
  Write-Error "devbox idle-monitor install FAILED: $_"
  throw
} finally {
  Stop-Transcript | Out-Null
}
