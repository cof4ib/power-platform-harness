<#
.SYNOPSIS
    Scaffolds a Power Platform / Dynamics 365 CE repository from the harness templates.

.DESCRIPTION
    Copies every file under templates/ into -TargetPath, replacing the template tokens with the
    values supplied as parameters, and creates the source, test and ADR folders the standards
    expect.

    The script never overwrites an existing file unless -Force is supplied: it collects every
    collision first and aborts without touching the working tree. Use -DryRun to print the
    resulting tree without writing anything.

.EXAMPLE
    ./scripts/scaffold.ps1 -ProjectName Northwind -PublisherName 'Northwind Consulting'
        -PublisherPrefix nwc -SolutionName NorthwindCore -RootNamespace Northwind
        -ProjectDescription 'Customer Service implementation for Northwind.' -DryRun

.EXAMPLE
    ./scripts/scaffold.ps1 -ProjectName Northwind -PublisherName 'Northwind Consulting'
        -PublisherPrefix nwc -SolutionName NorthwindCore -RootNamespace Northwind
        -ProjectDescription 'Customer Service implementation for Northwind.' -TargetPath C:\repos\northwind
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectName,

    [Parameter(Mandatory = $true)]
    [string]$PublisherName,

    [Parameter(Mandatory = $true)]
    [string]$PublisherPrefix,

    [Parameter(Mandatory = $true)]
    [string]$SolutionName,

    [Parameter(Mandatory = $true)]
    [string]$RootNamespace,

    [Parameter(Mandatory = $true)]
    [string]$ProjectDescription,

    [string]$TargetPath = (Get-Location).Path,

    [switch]$DryRun,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# Failures are reported as a single line on stderr with a non-zero exit code: the caller is
# usually an agent, and a PowerShell exception dump buries the actual problem.
function Stop-WithError {
    param([string]$Message)

    [Console]::Error.WriteLine("ERROR: $Message")
    exit 1
}

# Folders the standards expect to exist. Git does not track empty folders, so each one gets a
# .gitkeep.
$keepDirectories = @(
    'src/Plugins'
    'src/CustomAPIs'
    'src/WebResources'
    "src/Solutions/$SolutionName"
    'tests/Plugins'
    'tests/CustomAPIs'
    'docs/adr'
)

function Assert-Value {
    param(
        [string]$Name,
        [string]$Value,
        [string]$Pattern,
        [string]$Requirement
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        Stop-WithError "$Name is required. $Requirement"
    }

    # -cnotmatch, not -notmatch: PowerShell matches case-insensitively by default, which would
    # let an uppercase publisher prefix through.
    if ($Pattern -and $Value -cnotmatch $Pattern) {
        Stop-WithError "$Name '$Value' is invalid. $Requirement"
    }
}

# Validate every value before touching the working tree: a rejected prefix after a partial copy
# would leave a half-scaffolded repository behind.
Assert-Value -Name 'ProjectName' -Value $ProjectName -Pattern '^[A-Za-z][A-Za-z0-9]*$' `
    -Requirement 'It lands in .NET namespaces and JavaScript form API objects, so it must start with a letter and contain letters and digits only.'

Assert-Value -Name 'PublisherName' -Value $PublisherName `
    -Requirement 'Use the Dataverse publisher display name.'

Assert-Value -Name 'PublisherPrefix' -Value $PublisherPrefix -Pattern '^[a-z][a-z0-9]{1,7}$' `
    -Requirement 'A Dataverse customization prefix is 2 to 8 lowercase alphanumeric characters and starts with a letter.'

if ($PublisherPrefix -eq 'mscrm') {
    Stop-WithError "PublisherPrefix 'mscrm' is reserved by Dataverse. Choose another prefix."
}

Assert-Value -Name 'SolutionName' -Value $SolutionName -Pattern '^[A-Za-z_][A-Za-z0-9_]*$' `
    -Requirement 'This is the solution unique name, not its display name: no spaces or punctuation.'

Assert-Value -Name 'RootNamespace' -Value $RootNamespace -Pattern '^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$' `
    -Requirement 'It must be a valid .NET namespace, optionally dotted.'

Assert-Value -Name 'ProjectDescription' -Value $ProjectDescription `
    -Requirement 'One or two sentences describing what the project delivers. It becomes the Description section of CLAUDE.md.'

$templatesRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'templates'
if (-not (Test-Path -LiteralPath $templatesRoot)) {
    Stop-WithError "Templates folder not found at $templatesRoot. The plugin installation looks incomplete."
}
$templatesRoot = (Resolve-Path -LiteralPath $templatesRoot).Path

if (-not (Test-Path -LiteralPath $TargetPath)) {
    if ($DryRun) {
        Stop-WithError "TargetPath '$TargetPath' does not exist. Create it first, or run against an existing folder."
    }
    New-Item -ItemType Directory -Path $TargetPath -Force | Out-Null
}
$TargetPath = (Resolve-Path -LiteralPath $TargetPath).Path

$tokens = [ordered]@{
    '{{project_name}}'        = $ProjectName
    '{{publisher_name}}'      = $PublisherName
    '{{publisher_prefix}}'    = $PublisherPrefix
    '{{solution_name}}'       = $SolutionName
    '{{root_namespace}}'      = $RootNamespace
    '{{project_description}}' = $ProjectDescription
}

$plannedFiles = Get-ChildItem -LiteralPath $templatesRoot -Recurse -File -Force |
    ForEach-Object {
        $relative = $_.FullName.Substring($templatesRoot.Length).TrimStart('\', '/')
        [pscustomobject]@{
            Source      = $_.FullName
            Relative    = $relative -replace '\\', '/'
            Destination = Join-Path $TargetPath $relative
        }
    }

if (-not $plannedFiles) {
    Stop-WithError "No template files found under $templatesRoot."
}

$plannedKeeps = $keepDirectories | ForEach-Object {
    [pscustomobject]@{
        Relative    = "$_/.gitkeep"
        Destination = Join-Path $TargetPath (Join-Path $_ '.gitkeep')
    }
}

$allPlanned = @($plannedFiles) + @($plannedKeeps)

$collisions = $allPlanned |
    Where-Object { Test-Path -LiteralPath $_.Destination } |
    ForEach-Object { $_.Relative }

if ($collisions -and -not $Force) {
    Write-Host 'These files already exist in the target folder:' -ForegroundColor Red
    $collisions | ForEach-Object { Write-Host "  $_" }
    Stop-WithError 'Nothing was written. Move or delete the files above, or re-run with -Force to overwrite them.'
}

Write-Host "Target folder: $TargetPath" -ForegroundColor Cyan
if ($collisions) {
    Write-Host "Overwriting $(@($collisions).Count) existing file(s) because -Force was supplied." -ForegroundColor Yellow
}

if ($DryRun) {
    Write-Host 'Dry run. These files would be created:' -ForegroundColor Cyan
    $allPlanned | Sort-Object Relative | ForEach-Object { Write-Host "  $($_.Relative)" }
    Write-Host 'Nothing was written.' -ForegroundColor Cyan
    return
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

foreach ($file in $plannedFiles) {
    $destinationDirectory = Split-Path -Parent $file.Destination
    if (-not (Test-Path -LiteralPath $destinationDirectory)) {
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    }

    $content = [System.IO.File]::ReadAllText($file.Source)
    foreach ($token in $tokens.Keys) {
        $content = $content.Replace($token, $tokens[$token])
    }

    [System.IO.File]::WriteAllText($file.Destination, $content, $utf8NoBom)
}

foreach ($keep in $plannedKeeps) {
    $destinationDirectory = Split-Path -Parent $keep.Destination
    if (-not (Test-Path -LiteralPath $destinationDirectory)) {
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($keep.Destination, '', $utf8NoBom)
}

# The scaffold is only done when no token survived the substitution.
$unresolved = foreach ($file in $plannedFiles) {
    $found = Select-String -LiteralPath $file.Destination -Pattern '\{\{[a-z_]+\}\}' -AllMatches
    foreach ($line in $found) {
        "$($file.Relative):$($line.LineNumber): $(($line.Matches.Value | Select-Object -Unique) -join ', ')"
    }
}

if ($unresolved) {
    Write-Host 'Unresolved tokens remain in the generated files:' -ForegroundColor Red
    $unresolved | ForEach-Object { Write-Host "  $_" }
    Stop-WithError 'The scaffold is incomplete. Report these tokens instead of hand-editing the output.'
}

Write-Host 'Created:' -ForegroundColor Green
$allPlanned | Sort-Object Relative | ForEach-Object { Write-Host "  $($_.Relative)" }

Write-Host ''
Write-Host "Project:   $ProjectName" -ForegroundColor Cyan
Write-Host "Publisher: $PublisherName ($PublisherPrefix)" -ForegroundColor Cyan
Write-Host "Solution:  $SolutionName" -ForegroundColor Cyan
Write-Host "Namespace: $RootNamespace" -ForegroundColor Cyan
