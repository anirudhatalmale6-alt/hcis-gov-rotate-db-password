<#
  Change the postgres database password on this machine, safely.

  Why: that password was written inside scripts that are published in public
  repositories. It has been taken out of them, but a repository keeps its
  history, so the old value can still be read by anyone who looks back. Taking
  a secret out of the current files does not un-publish it. The only real fix
  is to change it.

  I told the client this would need the PostgREST configuration updating too,
  and that getting that wrong would take HCIS offline. On the office server
  that turned out to be WRONG: PostgREST there connects as a limited role
  called authenticator, not as postgres, so changing the postgres password does
  not affect it at all.

  I cannot read this machine, so this script does not assume either way. It
  looks at what PostgREST on THIS box actually connects as, and only touches
  the configuration if it genuinely uses the postgres account.

  Nothing is changed until every check has passed.
#>

param(
    [string]$NewPassword = '',
    [string]$Db          = 'hcis_db',
    [string]$DbUser      = 'postgres',
    [string]$Root        = 'C:\HCIS',
    [string]$PgBin       = '',
    [switch]$WhatIf                      # look and report, change nothing
)

$ErrorActionPreference = 'Stop'
function Say($m, $c = 'Gray') { Write-Host "  $m" -ForegroundColor $c }
function Rule { Write-Host '  ------------------------------------------------------------' }

. (Join-Path $PSScriptRoot 'db-access.ps1')

if (-not $PgBin) {
    $PgBin = @('C:\PostgreSQL\16\bin', 'C:\PostgreSQL\17\bin',
               'C:\Program Files\PostgreSQL\16\bin', 'C:\Program Files\PostgreSQL\17\bin') |
             Where-Object { Test-Path (Join-Path $_ 'psql.exe') } | Select-Object -First 1
}
if (-not $PgBin) { Say 'psql.exe was not found on this machine.' 'Red'; exit 1 }
$psql = Join-Path $PgBin 'psql.exe'

Write-Host ''
Say '============================================================'
Say ' Change the database password'
Say '============================================================'
Write-Host ''

# ---- 1. the CURRENT password, so we can still get in -----------------------
if (-not (Set-DbPassword)) { exit 1 }
$current = $env:PGPASSWORD

& $psql -q -U $DbUser -d $Db -tAc 'SELECT 1' *> $null
if ($LASTEXITCODE -ne 0) {
    Say 'The current password does not work, so nothing can be changed.' 'Red'
    Say 'Run SET-DB-PASSWORD.bat first and make sure it says it succeeded.' 'Yellow'
    exit 1
}
Say 'Current password works.' 'Green'

# ---- 2. what does PostgREST actually connect as? ---------------------------
Write-Host ''
Say 'Checking what PostgREST on this machine connects as...'

$conf = @((Join-Path $Root 'postgrest\postgrest.conf'),
          (Join-Path $Root 'postgrest\hcis.conf'),
          (Join-Path $Root 'postgrest.conf')) |
        Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $conf) {
    $dir = Join-Path $Root 'postgrest'
    if (Test-Path $dir) {
        $conf = Get-ChildItem $dir -Filter *.conf -File -EA SilentlyContinue |
                Select-Object -First 1 -ExpandProperty FullName
    }
}
if (-not $conf) {
    Say 'Could not find the PostgREST configuration file.' 'Red'
    Say 'Stopping - I will not change the password without knowing whether' 'Red'
    Say 'PostgREST depends on it.' 'Red'
    exit 1
}

$uriLine = Get-Content -LiteralPath $conf |
           Where-Object { $_ -match '^\s*db-uri\s*=' -and $_ -notmatch '^\s*#' } |
           Select-Object -First 1
if (-not $uriLine) { Say "No db-uri line in $conf - stopping." 'Red'; exit 1 }

# postgres://ROLE:password@host:port/db   - the role is what matters here.
$role = [regex]::Match($uriLine, '://([^:@/]+)[:@]').Groups[1].Value
if (-not $role) { Say "Could not read the role out of db-uri in $conf - stopping." 'Red'; exit 1 }

$postgrestAffected = ($role -eq $DbUser)
Say ("PostgREST connects as: {0}" -f $role)
if ($postgrestAffected) {
    Say 'That IS the account being changed, so its configuration must be' 'Yellow'
    Say 'updated and PostgREST restarted, or sign-in stops working.' 'Yellow'
} else {
    Say 'That is a different account, so this change does not affect it.' 'Green'
    Say 'No configuration change and no restart needed.' 'Green'
}

if ($WhatIf) {
    Write-Host ''
    Rule
    Say 'Looked only - nothing has been changed.' 'Cyan'
    Say ("PostgREST uses '{0}'. Changing '{1}' {2} affect it." -f
         $role, $DbUser, $(if ($postgrestAffected) { 'WOULD' } else { 'would NOT' }))
    Rule
    Write-Host ''
    if ($Host.Name -eq 'ConsoleHost') { Read-Host 'Press Enter to close' | Out-Null }
    exit 0
}

# ---- 3. the new password ---------------------------------------------------
Write-Host ''
if (-not $NewPassword) {
    Say 'Choose a new database password. At least 12 characters.' 'Yellow'
    Say 'Nothing will appear as you type.' 'Yellow'
    $a = Read-Host '  New password' -AsSecureString
    $b = Read-Host '  Type it again' -AsSecureString
    $pa = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($a)
    $pb = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($b)
    try {
        $s1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto($pa)
        $s2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto($pb)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pa)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pb)
    }
    if ($s1 -cne $s2) { Say 'Those two do not match. Nothing was changed.' 'Red'; exit 1 }
    $NewPassword = $s1
}
if ($NewPassword.Length -lt 12) {
    Say 'Too short - use at least 12 characters. Nothing was changed.' 'Red'; exit 1
}
if ($NewPassword -eq $current) {
    Say 'That is the password it already has. Nothing was changed.' 'Red'; exit 1
}
# A single quote would break the ALTER ROLE statement below. Rather than risk
# mangling it, refuse and ask for a different one.
if ($NewPassword -match "'") {
    Say "Please avoid the ' character. Nothing was changed." 'Red'; exit 1
}

# ---- 4. change it ----------------------------------------------------------
Write-Host ''
Say 'Changing the password...'
$esc = $NewPassword.Replace("'", "''")
& $psql -q -U $DbUser -d $Db -v ON_ERROR_STOP=1 -c "ALTER ROLE $DbUser WITH PASSWORD '$esc'"
if ($LASTEXITCODE -ne 0) { Say 'The change was refused. Nothing was changed.' 'Red'; exit 1 }
Say 'Database accepted the new password.' 'Green'

# ---- 5. prove the new one works BEFORE saving it anywhere -------------------
$env:PGPASSWORD = $NewPassword
& $psql -q -U $DbUser -d $Db -tAc 'SELECT 1' *> $null
if ($LASTEXITCODE -ne 0) {
    Say 'The new password was set but will not connect. Tell me before' 'Red'
    Say 'closing this window - the old one no longer works either.' 'Red'
    exit 1
}
Say 'Connected with the new password.' 'Green'

# ---- 6. SAVE IT, before anything else that could fail ----------------------
#
# This used to come after the PostgREST work. That was the wrong way round and
# a test caught it: the password had already been changed, the restart step
# then failed, and the script stopped BEFORE writing the new password down -
# leaving a database nobody could reach and no record of the new password.
#
# From here on the change is irreversible, so the very next thing to do is
# preserve the means of getting back in. Everything after this point is
# recoverable; this is not.
Write-Host ''
$file = Get-DbPasswordPath
$saved = $false
try {
    $dir = Split-Path -Parent $file
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Set-Content -LiteralPath $file -Value $NewPassword -NoNewline -Encoding ASCII
    $saved = $true
    Say ("Saved for the other scripts: {0}" -f $file) 'Green'
} catch {
    Say ('COULD NOT SAVE IT: ' + $_.Exception.Message) 'Red'
    Say 'The password IS already changed. Write it down NOW, before you' 'Red'
    Say 'close this window, or nothing will be able to reach the database.' 'Red'
}
try { & icacls $file /inheritance:r /grant:r "$env:USERNAME:(R,W)" "Administrators:(F)" *> $null } catch {}

# ---- 7. PostgREST, only if it genuinely uses this account ------------------
# Each step in its own try: the password is already changed and saved, so a
# failure here is something to report and fix, not a reason to abandon the
# script half way and leave the operator with no idea what state things are in.
if ($postgrestAffected) {
    Write-Host ''
    Say 'Updating the PostgREST configuration...'
    try {
        Copy-Item $conf "$conf.before_rotate" -Force
        $updated = (Get-Content -Raw -LiteralPath $conf) -replace
                   ('(://' + [regex]::Escape($DbUser) + ':)[^@]*(@)'), ('${1}' + $NewPassword + '${2}')
        Set-Content -LiteralPath $conf -Value $updated -NoNewline
        Say ("Updated. Previous file kept as {0}.before_rotate" -f (Split-Path -Leaf $conf)) 'Green'
    } catch {
        Say ('Could not update the PostgREST configuration: ' + $_.Exception.Message) 'Red'
        Say 'Sign-in will stop working until it is updated by hand.' 'Red'
    }

    Say 'Restarting PostgREST...'
    try {
        schtasks /End /TN 'PostgREST-HCIS' *> $null
        Start-Sleep -Seconds 2
        schtasks /Run /TN 'PostgREST-HCIS' *> $null
        Start-Sleep -Seconds 5
    } catch {
        Say 'Could not restart PostgREST automatically.' 'Yellow'
        Say 'Run STEP-2-reload-api.bat to do it.' 'Yellow'
    }
}

# ---- 8. is HCIS still working? --------------------------------------------
Write-Host ''
Say 'Checking HCIS still works...'
$apiOk = $false
try {
    $r = Invoke-WebRequest -Uri 'http://localhost:3000/rpc/hcis_login?select=access_token' `
            -Method Post -ContentType 'application/json' `
            -Body '{"p_identifier":"zz.rotate.probe","p_password":"x"}' `
            -UseBasicParsing -TimeoutSec 20
    if ([int]$r.StatusCode -eq 200) { $apiOk = $true }
} catch {
    $resp = $_.Exception.Response
    if ($resp -and [int]$resp.StatusCode -eq 200) { $apiOk = $true }
}

Write-Host ''
Rule
if ($apiOk) {
    Say 'DONE. Password changed, and HCIS is still answering.' 'Green'
} else {
    Say 'Password changed, but the API is NOT answering.' 'Red'
    if ($postgrestAffected) {
        Say 'Its configuration was updated and it was restarted - give it a' 'Yellow'
        Say 'moment and run STEP-2-reload-api.bat. If it still will not come' 'Yellow'
        Say 'back, the previous configuration is saved next to it as' 'Yellow'
        Say '.before_rotate. Send me a photo of this window.' 'Yellow'
    } else {
        Say 'This change did not touch PostgREST, so it was probably already' 'Yellow'
        Say 'stopped. Run STEP-2-reload-api.bat.' 'Yellow'
    }
}
Rule
Write-Host ''
if ($Host.Name -eq 'ConsoleHost') { Read-Host 'Press Enter to close' | Out-Null }
exit $(if ($apiOk) { 0 } else { 1 })
