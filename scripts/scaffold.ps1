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

    Also creates Dataverse.sln and the WebResources build project (an SDK-style .esproj with
    Vitest + ESLint tooling) under src/WebResources/, unless -SkipLayout or
    -SkipWebResourcesProject is supplied.

    Three ways to handle a folder that is not empty:
      - default:      abort and list the collisions, writing nothing.
      - -SkipExisting: write what is missing, leave every existing file untouched. This is the
                       mode for an existing project, where CLAUDE.md already says something the
                       team relies on.
      - -Force:        overwrite. Only after the caller has looked at what is being replaced.

    Run scripts/discover.ps1 first to find out which of the three applies, and to read the
    publisher, prefix, solution and namespace a project already uses.

.EXAMPLE
    ./scripts/scaffold.ps1 -ProjectName Northwind -PublisherName 'Northwind Consulting'
        -PublisherPrefix nwc -SolutionName NorthwindCore -RootNamespace Northwind
        -ProjectDescription 'Customer Service implementation for Northwind.' -DryRun

.EXAMPLE
    ./scripts/scaffold.ps1 -ProjectName Northwind -PublisherName 'Northwind Consulting'
        -PublisherPrefix nwc -SolutionName NorthwindCore -RootNamespace Northwind
        -ProjectDescription 'Customer Service implementation for Northwind.' -TargetPath C:\repos\northwind

.EXAMPLE
    # Adopt the harness into an existing repository: add the missing docs, touch nothing else.
    ./scripts/scaffold.ps1 -ProjectName Acme -PublisherName 'Acme Consulting' -PublisherPrefix acme
        -SolutionName AcmeCore -RootNamespace Acme.Crm -ProjectDescription 'Customer Service for Acme.'
        -TargetPath C:\repos\acme -SkipExisting -SkipLayout -Json
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

    [switch]$Force,

    # Existing projects: write the files the repository is missing and leave the rest alone,
    # instead of aborting on the first collision. An existing CLAUDE.md is the usual reason.
    [switch]$SkipExisting,

    # Do not create the src/, tests/ and docs/adr/ folders. An existing project already has a
    # layout; adding a second one next to it leaves two conventions in one repository.
    [switch]$SkipLayout,

    # Do not create Dataverse.sln or the WebResources build project (.esproj + package.json +
    # Vitest/ESLint config). Use for an existing project: it introduces a test runner, and the
    # harness must never impose one a project has not already chosen. -SkipLayout implies this.
    [switch]$SkipWebResourcesProject,

    # Emit a JSON summary instead of the human-readable report, for callers that parse the result.
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

# Failures are reported as a single line on stderr with a non-zero exit code: the caller is
# usually an agent, and a PowerShell exception dump buries the actual problem.
function Stop-WithError {
    param([string]$Message)

    [Console]::Error.WriteLine("ERROR: $Message")
    exit 1
}

if ($Force -and $SkipExisting) {
    Stop-WithError '-Force and -SkipExisting ask for opposite things. Choose one: overwrite the existing files, or keep them.'
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

# The WebResources build project's own source folders. Empty until the first web resource is
# added, so each one needs a .gitkeep like $keepDirectories above.
$webResourcesProjectFolder = "src/WebResources/$PublisherPrefix.WebResources"
$webResourcesKeepDirectories = @(
    "$webResourcesProjectFolder/${PublisherPrefix}_/src/js"
    "$webResourcesProjectFolder/${PublisherPrefix}_/src/html"
    "$webResourcesProjectFolder/${PublisherPrefix}_/src/css"
    "$webResourcesProjectFolder/${PublisherPrefix}_/src/icons"
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
        $templateRelative = ($_.FullName.Substring($templatesRoot.Length).TrimStart('\', '/')) -replace '\\', '/'

        # A template's own folder or file name can carry a token too (the WebResources project is
        # named after the publisher prefix), so resolve it the same way file content is resolved.
        $destinationRelative = $templateRelative
        foreach ($token in $tokens.Keys) {
            $destinationRelative = $destinationRelative.Replace($token, $tokens[$token])
        }

        [pscustomobject]@{
            Source      = $_.FullName
            Relative    = $destinationRelative
            Destination = Join-Path $TargetPath $destinationRelative
        }
    }

if (-not $plannedFiles) {
    Stop-WithError "No template files found under $templatesRoot."
}

# The WebResources build project (Dataverse.sln plus everything under src/WebResources/) is
# planned separately: -SkipLayout suppresses it because it assumes the standard src/WebResources
# path, and -SkipWebResourcesProject suppresses it on its own, for an existing project that has
# not chosen this tooling.
$webResourcesProjectPattern = '^(Dataverse\.sln|src/WebResources/)'
$webResourcesProjectFiles = @($plannedFiles | Where-Object { $_.Relative -match $webResourcesProjectPattern })
$plannedFiles = @($plannedFiles | Where-Object { $_.Relative -notmatch $webResourcesProjectPattern })

if (-not $SkipLayout -and -not $SkipWebResourcesProject) {
    $plannedFiles = @($plannedFiles) + @($webResourcesProjectFiles)
}

$plannedKeeps = @()
if (-not $SkipLayout) {
    $plannedKeeps = $keepDirectories | ForEach-Object {
        [pscustomobject]@{
            Relative    = "$_/.gitkeep"
            Destination = Join-Path $TargetPath (Join-Path $_ '.gitkeep')
        }
    }

    if (-not $SkipWebResourcesProject) {
        $plannedKeeps = @($plannedKeeps) + @($webResourcesKeepDirectories | ForEach-Object {
            [pscustomobject]@{
                Relative    = "$_/.gitkeep"
                Destination = Join-Path $TargetPath (Join-Path $_ '.gitkeep')
            }
        })
    }
}

$allPlanned = @($plannedFiles) + @($plannedKeeps)

$collisions = @($allPlanned |
    Where-Object { Test-Path -LiteralPath $_.Destination } |
    ForEach-Object { $_.Relative })

if ($collisions.Count -gt 0 -and -not $Force -and -not $SkipExisting) {
    Write-Host 'These files already exist in the target folder:' -ForegroundColor Red
    $collisions | ForEach-Object { Write-Host "  $_" }
    Stop-WithError 'Nothing was written. Re-run with -SkipExisting to add only what is missing, or with -Force to overwrite the files above.'
}

# -SkipExisting narrows the plan instead of aborting: what the repository already has is its own,
# and an existing CLAUDE.md usually carries instructions this scaffold must not silently replace.
$skipped = @()
if ($SkipExisting -and $collisions.Count -gt 0) {
    $skipped = $collisions
    $plannedFiles = @($plannedFiles | Where-Object { -not (Test-Path -LiteralPath $_.Destination) })
    $plannedKeeps = @($plannedKeeps | Where-Object { -not (Test-Path -LiteralPath $_.Destination) })
}

$written = @($plannedFiles) + @($plannedKeeps)

function Write-Report {
    param(
        [string]$Outcome,
        [string[]]$Created = @(),
        [string[]]$Skipped = @(),
        [string[]]$Overwritten = @(),
        [string[]]$Planned = @()
    )

    if ($Json) {
        $payload = [ordered]@{
            outcome     = $Outcome
            targetPath  = $TargetPath
            values      = [ordered]@{
                projectName        = $ProjectName
                publisherName      = $PublisherName
                publisherPrefix    = $PublisherPrefix
                solutionName       = $SolutionName
                rootNamespace      = $RootNamespace
                projectDescription = $ProjectDescription
            }
            mode        = [ordered]@{
                dryRun                  = [bool]$DryRun
                force                   = [bool]$Force
                skipExisting            = [bool]$SkipExisting
                skipLayout              = [bool]$SkipLayout
                skipWebResourcesProject = [bool]$SkipWebResourcesProject
            }
            planned     = @($Planned | Sort-Object)
            created     = @($Created | Sort-Object)
            skipped     = @($Skipped | Sort-Object)
            overwritten = @($Overwritten | Sort-Object)
        }
        $payload | ConvertTo-Json -Depth 6
        return
    }

    Write-Host "Target folder: $TargetPath" -ForegroundColor Cyan

    if ($Outcome -eq 'dry-run') {
        Write-Host 'Dry run. These files would be written:' -ForegroundColor Cyan
        $Planned | Sort-Object | ForEach-Object { Write-Host "  $_" }
        if ($Skipped.Count -gt 0) {
            Write-Host 'Left untouched because they already exist:' -ForegroundColor Yellow
            $Skipped | Sort-Object | ForEach-Object { Write-Host "  $_" }
        }
        Write-Host 'Nothing was written.' -ForegroundColor Cyan
        return
    }

    if ($Overwritten.Count -gt 0) {
        Write-Host "Overwrote $($Overwritten.Count) existing file(s) because -Force was supplied." -ForegroundColor Yellow
    }

    if ($Created.Count -gt 0) {
        Write-Host 'Created:' -ForegroundColor Green
        $Created | Sort-Object | ForEach-Object { Write-Host "  $_" }
    }
    else {
        Write-Host 'Nothing to create: every file the harness installs is already present.' -ForegroundColor Yellow
    }

    if ($Skipped.Count -gt 0) {
        Write-Host 'Left untouched because they already exist:' -ForegroundColor Yellow
        $Skipped | Sort-Object | ForEach-Object { Write-Host "  $_" }
        Write-Host 'Compare each one against the template before assuming the harness is current.' -ForegroundColor Yellow
    }
}

if ($DryRun) {
    Write-Report -Outcome 'dry-run' `
        -Planned @($written | ForEach-Object { $_.Relative }) `
        -Skipped $skipped `
        -Overwritten @(if ($Force) { $collisions } else { @() })
    return
}

if ($written.Count -eq 0) {
    Write-Report -Outcome 'nothing-to-do' -Skipped $skipped
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

Write-Report -Outcome 'written' `
    -Created @($written | ForEach-Object { $_.Relative }) `
    -Skipped $skipped `
    -Overwritten @(if ($Force) { $collisions } else { @() })

if (-not $Json) {
    Write-Host ''
    Write-Host "Project:   $ProjectName" -ForegroundColor Cyan
    Write-Host "Publisher: $PublisherName ($PublisherPrefix)" -ForegroundColor Cyan
    Write-Host "Solution:  $SolutionName" -ForegroundColor Cyan
    Write-Host "Namespace: $RootNamespace" -ForegroundColor Cyan
}
