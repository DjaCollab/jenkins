# Watches the DBA team's release share for new IBIS Database builds and hands them
# to Jenkins.
#
# Why it pushes instead of Jenkins pulling: the Jenkins controller is an EC2 instance
# in AWS and the share lives on 10.140.5.67, on-premise. Every TCP port from AWS into
# that segment is blocked. The one direction that works is on-prem -> Jenkins:8090,
# so the file travels that way.
#
# Run this from Task Scheduler on a machine that can reach BOTH the share and Jenkins.
# Set it to "Run whether user is logged on or not" so the share stays reachable.

[CmdletBinding()]
param(
    [string] $ShareRoot   = '\\SRV-CAMTL-NAS01\Departments\Solutions\IBIS\IBIS Versions\IBIS Database',
    [string] $JenkinsUrl  = 'http://10.110.2.116:8090',
    [string] $JobName     = 'PGUP-receive',
    [string] $StateFile   = (Join-Path $PSScriptRoot 'seen-releases.json'),
    [string] $CredFile    = (Join-Path $PSScriptRoot 'jenkins-api.cred'),

    # First run only: record what is already there without uploading any of it.
    # Without this the first execution would fire ~20 builds for historical releases.
    [switch] $Seed
)

$ErrorActionPreference = 'Stop'

function Write-Log([string] $Message) {
    Write-Host ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
}

# --- discover release folders -------------------------------------------------
# Folder names carry the version, including hotfix markers: "DB 6.1.0.06",
# "DB 6.0.0.107 HF1.4". The folder NAME is the identity, not the extracted
# version number - two hotfixes of one build would otherwise collide.

if (-not (Test-Path -LiteralPath $ShareRoot)) {
    throw "Cannot reach $ShareRoot. Check that this machine can resolve SRV-CAMTL-NAS01 and has rights on the share."
}

$folders = Get-ChildItem -LiteralPath $ShareRoot -Directory |
           Where-Object { $_.Name -match '^DB\s' } |
           Sort-Object LastWriteTime

$seen = @()
if (Test-Path -LiteralPath $StateFile) {
    $seen = @(Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json)
}

if ($Seed) {
    $folders.Name | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8
    Write-Log ("Seeded with {0} existing release folder(s). Nothing uploaded." -f $folders.Count)
    return
}

if (-not (Test-Path -LiteralPath $StateFile)) {
    throw "No state file at $StateFile. Run once with -Seed first, or every existing release would be uploaded."
}

$new = $folders | Where-Object { $seen -notcontains $_.Name }
if (-not $new) {
    Write-Log 'No new release.'
    return
}

# --- Jenkins credentials ------------------------------------------------------
# Create once, on this machine, as the account the scheduled task runs under:
#   Get-Credential | Export-Clixml .\jenkins-api.cred
# Username = your Jenkins user, password = a Jenkins API token (not your password).
# Export-Clixml encrypts with DPAPI: only that account, on that machine, can read it.

if (-not (Test-Path -LiteralPath $CredFile)) {
    throw "No credential file at $CredFile. Create it with: Get-Credential | Export-Clixml '$CredFile'"
}
$cred     = Import-Clixml -LiteralPath $CredFile
$apiUser  = $cred.UserName
$apiToken = $cred.GetNetworkCredential().Password

# Jenkins rejects POSTs without a CSRF crumb.
$crumbJson = curl.exe -s -u "${apiUser}:${apiToken}" "$JenkinsUrl/crumbIssuer/api/json"
if ($LASTEXITCODE -ne 0 -or -not $crumbJson) {
    throw "Cannot reach Jenkins at $JenkinsUrl. Check connectivity and the API token."
}
$crumb = $crumbJson | ConvertFrom-Json

# --- upload each new release --------------------------------------------------

foreach ($folder in $new) {
    Write-Log ("New release folder: {0}" -f $folder.Name)

    $exe = Get-ChildItem -LiteralPath $folder.FullName -Filter *.exe -File |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1

    if (-not $exe) {
        # Not fatal, and deliberately not recorded as seen: the DBA team may still
        # be copying files in. The next run will pick it up.
        Write-Log ("  no .exe yet - leaving it for the next run")
        continue
    }

    # The pipeline derives the build number from the file name, so it has to be there.
    if ($exe.Name -notmatch '(\d+\.\d+\.\d+\.\d+)') {
        Write-Log ("  SKIPPED: '{0}' has no x.x.x.x version in its name" -f $exe.Name)
        continue
    }
    $version = $Matches[1]

    Write-Log ("  {0} ({1:N1} MB) -> version {2}" -f $exe.Name, ($exe.Length / 1MB), $version)

    # The original file name travels with the upload and is what the pipeline matches
    # on. It is the only thing that distinguishes "6.0.0.107" from "6.0.0.107 HF1.4";
    # the version number alone would make the two collide.
    $response = curl.exe -s -w '%{http_code}' -o - `
        -u "${apiUser}:${apiToken}" `
        -H ("{0}: {1}" -f $crumb.crumbRequestField, $crumb.crumb) `
        -F ("INSTALLER=@{0}" -f $exe.FullName) `
        -F ("INSTALLER_FILE=" + $exe.Name) `
        -F ("INSTALLER_VERSION=$version") `
        -F ("RELEASE_FOLDER=" + $folder.Name) `
        "$JenkinsUrl/job/$JobName/buildWithParameters"

    $code = $response[-3..-1] -join ''

    if ($code -eq '201' -or $code -eq '200') {
        Write-Log ("  queued in Jenkins (HTTP {0})" -f $code)
        $seen += $folder.Name
        # Written after each success, so a failure halfway through does not lose
        # the releases already handled.
        $seen | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8
    } else {
        Write-Log ("  UPLOAD FAILED (HTTP {0}) - will retry next run" -f $code)
    }
}
