<#
.SYNOPSIS
    Keeps src/Solutions/<SolutionName> in sync with the connected Dataverse environment.

.DESCRIPTION
    Default mode: export the unmanaged solution and unpack it over src/Solutions/<SolutionName>,
    leaving the working tree ready to commit alongside the rest of the change.

    -Check mode: export and unpack into a temporary folder, then compare it against what is
    committed. A difference means the environment holds declarative work nobody has committed.
    Run this BEFORE starting declarative work; if it fails, stop and report it instead of
    absorbing someone else's change into your own.

.EXAMPLE
    ./scripts/sync-solution.ps1 -SolutionName NorthwindCore -Check

.EXAMPLE
    ./scripts/sync-solution.ps1 -SolutionName NorthwindCore
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SolutionName,

    [switch]$Check
)

$ErrorActionPreference = 'Stop'

function Invoke-Pac {
    param([string[]]$Arguments)

    & pac @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "pac $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
}

function Get-FolderFingerprint {
    param([string]$Path)

    Get-ChildItem -Path $Path -Recurse -File |
        ForEach-Object {
            $relative = $_.FullName.Substring($Path.Length).TrimStart('\', '/')
            "$relative`t$((Get-FileHash -Path $_.FullName -Algorithm SHA256).Hash)"
        } |
        Sort-Object
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$targetPath = Join-Path $repoRoot "src/Solutions/$SolutionName"
$stagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) "pac-sync-$([guid]::NewGuid())"
$zipPath = Join-Path $stagingRoot "$SolutionName.zip"

New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null

try {
    Write-Host 'Target environment:' -ForegroundColor Cyan
    Invoke-Pac @('org', 'who')

    Write-Host "Exporting $SolutionName (unmanaged)..." -ForegroundColor Cyan
    Invoke-Pac @('solution', 'export', '--name', $SolutionName, '--path', $zipPath, '--overwrite')

    $unpackPath = if ($Check) { Join-Path $stagingRoot 'unpacked' } else { $targetPath }

    Write-Host "Unpacking into $unpackPath..." -ForegroundColor Cyan
    Invoke-Pac @('solution', 'unpack', '--zipfile', $zipPath, '--folder', $unpackPath,
                 '--packagetype', 'Unmanaged', '--allowDelete', '--allowWrite', '--clobber')

    if (-not $Check) {
        Write-Host "Unpacked into $targetPath. Review 'git status' and commit the diff with your change." -ForegroundColor Green
        return
    }

    if (-not (Test-Path $targetPath)) {
        throw "No committed solution found at $targetPath. Run without -Check to create the first snapshot."
    }

    $differences = Compare-Object `
        -ReferenceObject  (Get-FolderFingerprint -Path $targetPath) `
        -DifferenceObject (Get-FolderFingerprint -Path $unpackPath)

    if ($differences) {
        Write-Host 'The environment does not match the committed solution:' -ForegroundColor Red
        $differences |
            ForEach-Object {
                $marker = if ($_.SideIndicator -eq '<=') { 'only in repo    ' } else { 'only in environment' }
                "  $marker  $($_.InputObject.Split("`t")[0])"
            } |
            Write-Host
        throw 'Uncommitted declarative changes exist in the environment. Stop and report them before starting your own work.'
    }

    Write-Host 'Environment matches the committed solution.' -ForegroundColor Green
}
finally {
    Remove-Item -Path $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
}
