<#
.SYNOPSIS
    Read-only discovery of a repository and, optionally, the connected Dataverse environment.

.DESCRIPTION
    Answers the questions the set-power-platform skill needs before it writes anything:

      - Which tools are available (pwsh, pac, git, dotnet, node, gh)?
      - Is this folder empty, or an existing project the harness has to adapt to?
      - Which publisher, prefix, solution and namespace does the project already use?
      - Which versions and frameworks does it actually use, and where do those differ from the
        versions the shipped standards assert (scripts/standards-baseline.json)?
      - Which environment is the active pac profile pointing at?

    Everything here reads. Nothing is created, modified or deleted, in the repository or in the
    environment. Output is a single JSON document on stdout so the caller does not have to parse
    prose; per-probe failures are recorded as fields inside it rather than aborting the run, so a
    missing pac still yields a usable repository report.

.EXAMPLE
    ./scripts/discover.ps1 -Path C:\repos\northwind

.EXAMPLE
    # Repository only: no network, no pac calls.
    ./scripts/discover.ps1 -SkipEnvironment

.EXAMPLE
    # Read the real publisher and prefix out of a solution that exists in the environment but has
    # never been unpacked into the repository. Exports to a temp folder and deletes it afterwards.
    ./scripts/discover.ps1 -ResolvePublisherFromSolution NorthwindCore
#>
[CmdletBinding()]
param(
    # Repository to inspect. Defaults to the current folder.
    [string]$Path = (Get-Location).Path,

    # Skip every pac call. Use when offline, or when the environment is irrelevant to the question.
    [switch]$SkipEnvironment,

    # Environment to report on, when it is not the active pac profile's.
    [string]$EnvironmentUrl,

    # Export this solution to a temp folder to read its real publisher name and customization
    # prefix. Read-only against Dataverse, but it transfers the whole solution: opt in explicitly.
    [string]$ResolvePublisherFromSolution,

    # Per-command timeout. A hung pac call must not hang the caller.
    [int]$TimeoutSeconds = 90,

    # Upper bound on the file walk, so a repository with a huge build cache still returns.
    [int]$MaxFiles = 20000
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

function Stop-WithError {
    param([string]$Message)

    [Console]::Error.WriteLine("ERROR: $Message")
    exit 1
}

# --------------------------------------------------------------------------------------------
# External commands
# --------------------------------------------------------------------------------------------

$script:resolvedTools = @{}
$script:scratchRoot = Join-Path ([System.IO.Path]::GetTempPath()) "pph-discover-$([guid]::NewGuid())"

function Resolve-Tool {
    param([string]$Name)

    if ($script:resolvedTools.ContainsKey($Name)) { return $script:resolvedTools[$Name] }

    $command = Get-Command -Name $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    $info = [pscustomobject]@{
        Name       = $Name
        Present    = $false
        Source     = $null
        Kind       = $null
        Executable = $null
        Prefix     = @()
    }

    if ($command) {
        $info.Present = $true
        $info.Source = $command.Source
        $info.Kind = [string]$command.CommandType

        if ($command.CommandType -eq 'Application') {
            $extension = [System.IO.Path]::GetExtension($command.Source)
            if ($extension -in @('.cmd', '.bat')) {
                # CreateProcess cannot launch a batch file directly, and redirecting output forces
                # UseShellExecute = false. npm-installed pac lands here.
                $info.Executable = "$env:SystemRoot\System32\cmd.exe"
                $info.Prefix = @('/c', $command.Source)
            }
            else {
                $info.Executable = $command.Source
            }
        }
        # Anything else (a .ps1 shim such as npm.ps1, a function, an alias) is reported as present
        # but is never executed: presence is all this script needs from those.
    }

    $script:resolvedTools[$Name] = $info
    return $info
}

function ConvertTo-ArgumentString {
    param([string[]]$Arguments)

    if (-not $Arguments) { return '' }

    $quoted = foreach ($argument in $Arguments) {
        if ($argument -match '[\s"]') { '"' + ($argument -replace '"', '\"') + '"' } else { $argument }
    }

    return ($quoted -join ' ')
}

function Invoke-Tool {
    param(
        [string]$Name,
        [string[]]$Arguments = @(),
        [int]$Timeout = 0
    )

    if ($Timeout -le 0) { $Timeout = $TimeoutSeconds }

    $result = [pscustomobject]@{
        Command  = "$Name $($Arguments -join ' ')".Trim()
        Ran      = $false
        ExitCode = $null
        Stdout   = ''
        Stderr   = ''
        TimedOut = $false
        Error    = $null
    }

    $tool = Resolve-Tool -Name $Name
    if (-not $tool.Present) {
        $result.Error = "'$Name' was not found on PATH."
        return $result
    }
    if (-not $tool.Executable) {
        $result.Error = "'$Name' resolves to $($tool.Kind) at $($tool.Source), which this script does not execute."
        return $result
    }

    if (-not (Test-Path -LiteralPath $script:scratchRoot)) {
        New-Item -ItemType Directory -Path $script:scratchRoot -Force | Out-Null
    }

    $stamp = [guid]::NewGuid().ToString('n')
    $outFile = Join-Path $script:scratchRoot "$stamp.out"
    $errFile = Join-Path $script:scratchRoot "$stamp.err"

    # Output goes to files rather than pipes: a pipe that fills while nobody reads it deadlocks,
    # and pac is chatty. WaitForExit with a timeout then bounds the whole call.
    try {
        $argumentString = ConvertTo-ArgumentString -Arguments (@($tool.Prefix) + @($Arguments))
        $startArguments = @{
            FilePath               = $tool.Executable
            NoNewWindow            = $true
            PassThru               = $true
            RedirectStandardOutput = $outFile
            RedirectStandardError  = $errFile
        }
        if ($argumentString) { $startArguments['ArgumentList'] = $argumentString }

        $process = Start-Process @startArguments

        # Reading .Handle caches it, which is what makes .ExitCode readable afterwards. Without
        # this, Start-Process -PassThru leaves ExitCode empty and every call looks like a failure.
        $null = $process.Handle

        if (-not $process.WaitForExit($Timeout * 1000)) {
            $result.TimedOut = $true
            $result.Error = "'$($result.Command)' did not finish within $Timeout seconds and was stopped."
            try { $process.Kill() } catch { }
            $process.WaitForExit(5000) | Out-Null
        }
        else {
            # The timed overload can return before the exit state is processed; the parameterless
            # call returns immediately once exited and guarantees ExitCode is populated.
            $process.WaitForExit()
            $result.Ran = $true
            $result.ExitCode = $process.ExitCode
        }
    }
    catch {
        $result.Error = "'$($result.Command)' could not be started: $($_.Exception.Message)"
    }

    foreach ($pair in @(@{ File = $outFile; Property = 'Stdout' }, @{ File = $errFile; Property = 'Stderr' })) {
        if (Test-Path -LiteralPath $pair.File) {
            $text = [System.IO.File]::ReadAllText($pair.File)
            $result.($pair.Property) = $text.TrimEnd("`r", "`n")
            Remove-Item -LiteralPath $pair.File -Force -ErrorAction SilentlyContinue
        }
    }

    return $result
}

function Get-ToolReport {
    param(
        [string]$Name,
        [string[]]$VersionArguments = @('--version'),
        [int]$Timeout = 30
    )

    $tool = Resolve-Tool -Name $Name
    $report = [ordered]@{
        present = $tool.Present
        source  = $tool.Source
        version = $null
        note    = $null
    }

    if (-not $tool.Present) { return $report }

    if (-not $tool.Executable) {
        $report['note'] = "Resolves to $($tool.Kind); version not probed."
        return $report
    }

    $run = Invoke-Tool -Name $Name -Arguments $VersionArguments -Timeout $Timeout
    $output = "$($run.Stdout)`n$($run.Stderr)".Trim()

    # pac prints a banner and then exits 1 on --version, so a version that was printed is worth
    # more than the exit code. Only report a note when nothing recognisable came back.
    $match = [regex]::Match($output, '(\d+\.\d+[\w.+-]*)')
    if ($match.Success) {
        $report['version'] = $match.Value
    }
    elseif ($run.Error) {
        $report['note'] = $run.Error
    }
    elseif ($output) {
        $report['version'] = ($output -split "`n" | Select-Object -First 1).Trim()
    }
    else {
        $report['note'] = "No version output; exited with code $($run.ExitCode)."
    }

    return $report
}

# --------------------------------------------------------------------------------------------
# Repository walk
# --------------------------------------------------------------------------------------------

# Folders that hold build output, caches or dependencies. Descending into them is slow enough to
# look like a hang (a uv or NuGet cache is tens of thousands of files) and tells us nothing.
$prunedFolders = @(
    '.git', '.svn', '.hg', 'node_modules', 'bin', 'obj', '.vs', 'packages', 'out', 'dist',
    'TestResults', '.build-cache', '.nuget', '.idea', 'coverage', '.venv', 'venv', '__pycache__',
    '.next', '.gradle', '.terraform', 'generated', 'Generated'
)

function Get-RepoInventory {
    param([string]$Root, [int]$Limit)

    $files = New-Object System.Collections.Generic.List[string]
    $pruned = New-Object System.Collections.Generic.HashSet[string]
    $directories = New-Object System.Collections.Generic.List[string]
    $truncated = $false

    $pending = New-Object System.Collections.Generic.Stack[string]
    $pending.Push($Root)

    while ($pending.Count -gt 0) {
        $current = $pending.Pop()

        try {
            $entries = [System.IO.Directory]::GetFileSystemEntries($current)
        }
        catch {
            continue
        }

        foreach ($entry in $entries) {
            $name = [System.IO.Path]::GetFileName($entry)
            $isDirectory = $false
            try { $isDirectory = ([System.IO.File]::GetAttributes($entry) -band [System.IO.FileAttributes]::Directory) -ne 0 } catch { continue }

            if ($isDirectory) {
                if ($prunedFolders -contains $name) {
                    $relative = $entry.Substring($Root.Length).TrimStart('\', '/') -replace '\\', '/'
                    $pruned.Add($relative) | Out-Null
                    continue
                }
                $directories.Add(($entry.Substring($Root.Length).TrimStart('\', '/') -replace '\\', '/')) | Out-Null
                $pending.Push($entry)
            }
            else {
                if ($files.Count -ge $Limit) {
                    $truncated = $true
                    continue
                }
                $files.Add(($entry.Substring($Root.Length).TrimStart('\', '/') -replace '\\', '/')) | Out-Null
            }
        }
    }

    return [pscustomobject]@{
        Files       = $files
        Directories = $directories
        Pruned      = @($pruned)
        Truncated   = $truncated
    }
}

function Select-Files {
    param(
        [System.Collections.Generic.List[string]]$Files,
        [string]$Pattern,
        [int]$Limit = 200
    )

    $matched = @($Files | Where-Object { $_ -match $Pattern })
    if ($matched.Count -gt $Limit) { return @($matched | Select-Object -First $Limit) }
    return $matched
}

function Read-XmlFile {
    param([string]$FullPath)

    try {
        $document = New-Object System.Xml.XmlDocument
        $document.PreserveWhitespace = $false
        # Solution.xml and ControlManifest.Input.xml are repository content, but treat them as
        # untrusted input anyway: no DTD resolution, no external entities.
        $settings = New-Object System.Xml.XmlReaderSettings
        $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $reader = [System.Xml.XmlReader]::Create($FullPath, $settings)
        try { $document.Load($reader) } finally { $reader.Dispose() }
        return $document
    }
    catch {
        return $null
    }
}

function Get-SolutionFacts {
    param([string]$Root, [string[]]$SolutionXmlFiles)

    foreach ($relative in $SolutionXmlFiles) {
        $document = Read-XmlFile -FullPath (Join-Path $Root $relative)
        # src/Solutions/<Name>/Other/Solution.xml -> src/Solutions/<Name>
        $folder = ($relative -replace '/Other/Solution\.xml$', '')

        if (-not $document) {
            [pscustomobject]@{
                folder    = $folder
                manifest  = $relative
                readError = 'Solution.xml could not be parsed.'
            }
            continue
        }

        $manifest = $document.SelectSingleNode('/ImportExportXml/SolutionManifest')
        if (-not $manifest) {
            [pscustomobject]@{ folder = $folder; manifest = $relative; readError = 'No SolutionManifest element.' }
            continue
        }

        $publisher = $manifest.SelectSingleNode('Publisher')
        $publisherDisplay = $null
        if ($publisher) {
            $localized = $publisher.SelectSingleNode('LocalizedNames/LocalizedName')
            if ($localized) { $publisherDisplay = $localized.GetAttribute('description') }
        }

        $solutionDisplay = $null
        $solutionLocalized = $manifest.SelectSingleNode('LocalizedNames/LocalizedName')
        if ($solutionLocalized) { $solutionDisplay = $solutionLocalized.GetAttribute('description') }

        $managedNode = $manifest.SelectSingleNode('Managed')

        [pscustomobject]@{
            folder              = $folder
            manifest            = $relative
            uniqueName          = $(if ($manifest.SelectSingleNode('UniqueName')) { $manifest.SelectSingleNode('UniqueName').InnerText } else { $null })
            displayName         = $solutionDisplay
            version             = $(if ($manifest.SelectSingleNode('Version')) { $manifest.SelectSingleNode('Version').InnerText } else { $null })
            managed             = $(if ($managedNode) { $managedNode.InnerText -eq '1' } else { $null })
            publisherUniqueName = $(if ($publisher -and $publisher.SelectSingleNode('UniqueName')) { $publisher.SelectSingleNode('UniqueName').InnerText } else { $null })
            publisherName       = $publisherDisplay
            publisherPrefix     = $(if ($publisher -and $publisher.SelectSingleNode('CustomizationPrefix')) { $publisher.SelectSingleNode('CustomizationPrefix').InnerText } else { $null })
            readError           = $null
        }
    }
}

function Get-ProjectFacts {
    param([string]$Root, [string[]]$ProjectFiles)

    foreach ($relative in $ProjectFiles) {
        $fullPath = Join-Path $Root $relative
        $document = Read-XmlFile -FullPath $fullPath

        if (-not $document) {
            [pscustomobject]@{ path = $relative; readError = 'Project file could not be parsed.' }
            continue
        }

        $projectElement = $document.DocumentElement
        $sdkStyle = $projectElement.HasAttribute('Sdk')

        $properties = @{}
        foreach ($node in $projectElement.SelectNodes('//*[local-name()="PropertyGroup"]/*')) {
            if (-not $properties.ContainsKey($node.LocalName)) { $properties[$node.LocalName] = $node.InnerText.Trim() }
        }

        $packages = foreach ($node in $projectElement.SelectNodes('//*[local-name()="PackageReference"]')) {
            $id = $node.GetAttribute('Include')
            if (-not $id) { $id = $node.GetAttribute('Update') }
            $version = $node.GetAttribute('Version')
            if (-not $version) {
                $versionNode = $node.SelectSingleNode('*[local-name()="Version"]')
                if ($versionNode) { $version = $versionNode.InnerText.Trim() }
            }
            if ($id) { [pscustomobject]@{ id = $id; version = $(if ($version) { $version } else { $null }) } }
        }
        $packages = @($packages)

        $frameworks = @()
        if ($properties.ContainsKey('TargetFramework') -and $properties['TargetFramework']) {
            $frameworks += $properties['TargetFramework']
        }
        if ($properties.ContainsKey('TargetFrameworks') -and $properties['TargetFrameworks']) {
            $frameworks += ($properties['TargetFrameworks'] -split ';' | Where-Object { $_ })
        }
        if (-not $frameworks -and $properties.ContainsKey('TargetFrameworkVersion')) {
            # Legacy csproj: v4.6.2 -> net462
            $frameworks += ('net' + ($properties['TargetFrameworkVersion'] -replace '^v', '' -replace '\.', ''))
        }

        $packageIds = @($packages | ForEach-Object { $_.id })
        $isTest =
            $relative -match '(?i)(\.tests?|\.unittests?)\.csproj$' -or
            $relative -match '(?i)(^|/)tests?/' -or
            ($packageIds | Where-Object { $_ -match '(?i)^(xunit|nunit|mstest\.testframework|microsoft\.net\.test\.sdk)' })

        $role = 'other'
        if ($isTest) { $role = 'test' }
        elseif ($packageIds | Where-Object { $_ -match '(?i)^microsoft\.crmsdk' }) { $role = 'dataverse' }
        elseif ($relative -match '(?i)(^|/)(plugins?|customapis?)(/|$)') { $role = 'dataverse' }

        $signs =
            ($properties.ContainsKey('SignAssembly') -and $properties['SignAssembly'] -match '(?i)^true$') -or
            ($properties.ContainsKey('AssemblyOriginatorKeyFile') -and $properties['AssemblyOriginatorKeyFile'])

        [pscustomobject]@{
            path             = $relative
            role             = $role
            sdkStyle         = $sdkStyle
            targetFrameworks = @($frameworks | Select-Object -Unique)
            rootNamespace    = $(if ($properties.ContainsKey('RootNamespace')) { $properties['RootNamespace'] } else { $null })
            assemblyName     = $(if ($properties.ContainsKey('AssemblyName')) { $properties['AssemblyName'] } else { $null })
            signAssembly     = [bool]$signs
            packages         = $packages
            readError        = $null
        }
    }
}

function Get-PackageJsonFacts {
    param([string]$Root, [string[]]$PackageFiles)

    foreach ($relative in $PackageFiles) {
        try {
            $json = [System.IO.File]::ReadAllText((Join-Path $Root $relative)) | ConvertFrom-Json
        }
        catch {
            [pscustomobject]@{ path = $relative; readError = 'package.json could not be parsed.' }
            continue
        }

        $dependencies = [ordered]@{}
        foreach ($section in @('dependencies', 'devDependencies', 'peerDependencies')) {
            if ($json.PSObject.Properties.Name -contains $section -and $json.$section) {
                foreach ($property in $json.$section.PSObject.Properties) {
                    $dependencies[$property.Name] = [string]$property.Value
                }
            }
        }

        [pscustomobject]@{
            path         = $relative
            name         = $json.name
            version      = $json.version
            private      = $json.private
            scripts      = $(if ($json.scripts) { @($json.scripts.PSObject.Properties.Name) } else { @() })
            dependencies = $dependencies
            readError    = $null
        }
    }
}

function Get-PcfFacts {
    param([string]$Root, [string[]]$ManifestFiles)

    foreach ($relative in $ManifestFiles) {
        $document = Read-XmlFile -FullPath (Join-Path $Root $relative)
        if (-not $document) {
            [pscustomobject]@{ manifest = $relative; readError = 'ControlManifest could not be parsed.' }
            continue
        }

        $control = $document.SelectSingleNode('/manifest/control')
        if (-not $control) {
            [pscustomobject]@{ manifest = $relative; readError = 'No control element.' }
            continue
        }

        $libraries = foreach ($node in $document.SelectNodes('/manifest/control/resources/platform-library')) {
            [pscustomobject]@{ name = $node.GetAttribute('name'); version = $node.GetAttribute('version') }
        }

        [pscustomobject]@{
            manifest         = $relative
            namespace        = $control.GetAttribute('namespace')
            constructor      = $control.GetAttribute('constructor')
            version          = $control.GetAttribute('version')
            controlType      = $control.GetAttribute('control-type')
            platformLibraries = @($libraries)
            readError        = $null
        }
    }
}

# --------------------------------------------------------------------------------------------
# Environment
# --------------------------------------------------------------------------------------------

function Get-AuthProfiles {
    param([string]$Output)

    # pac auth list prints a fixed-width table. Column positions move between versions, so take
    # the pieces that have an unambiguous shape instead: the active marker, an email, a url.
    foreach ($line in ($Output -split "`r?`n")) {
        if ($line -notmatch '^\s*\[\d+\]') { continue }

        $url = [regex]::Match($line, 'https?://[^\s]+')
        $user = [regex]::Match($line, '[^\s]+@[^\s]+')

        [pscustomobject]@{
            index       = [regex]::Match($line, '\[(\d+)\]').Groups[1].Value
            active      = $line -match '^\s*\[\d+\]\s+\*'
            user        = $(if ($user.Success) { $user.Value } else { $null })
            url         = $(if ($url.Success) { $url.Value.TrimEnd('/') } else { $null })
            raw         = $line.Trim()
        }
    }
}

function Get-OrgFacts {
    param([string]$Output)

    $facts = [ordered]@{
        connectedAs   = $null
        friendlyName  = $null
        uniqueName    = $null
        url           = $null
        orgId         = $null
        environmentId = $null
        userEmail     = $null
    }

    $map = @{
        'Org ID'        = 'orgId'
        'Unique Name'   = 'uniqueName'
        'Friendly Name' = 'friendlyName'
        'Org URL'       = 'url'
        'User Email'    = 'userEmail'
        'Environment ID' = 'environmentId'
    }

    foreach ($line in ($Output -split "`r?`n")) {
        $match = [regex]::Match($line, '^\s*([A-Za-z ]+?):\s+(.+?)\s*$')
        if ($match.Success -and $map.ContainsKey($match.Groups[1].Value)) {
            $facts[$map[$match.Groups[1].Value]] = $match.Groups[2].Value
        }
        elseif ($line -match '^\s*Connected as\s+(.+?)\s*$') {
            $facts['connectedAs'] = $Matches[1]
        }
    }

    if ($facts['url']) { $facts['url'] = $facts['url'].TrimEnd('/') }
    return $facts
}

function Get-EnvironmentNameSignal {
    param([string[]]$Values)

    $text = (@($Values) -join ' ')
    if (-not $text) { return 'unknown' }

    # Production first: a name containing both is more likely to be production than not.
    if ($text -match '(?i)(^|[^a-z])(prod|prd|production|live)([^a-z]|$)') { return 'production' }
    if ($text -match '(?i)(^|[^a-z])(test|tst|qa|uat|sit|stag|staging|stage|preprod|pre-prod)([^a-z]|$)') { return 'test' }
    if ($text -match '(?i)(^|[^a-z])(dev|develop|development|sandbox|sbx)([^a-z]|$)') { return 'dev' }
    return 'unknown'
}

function Get-EnvironmentSolutions {
    param([string]$Output)

    $started = $false
    foreach ($line in ($Output -split "`r?`n")) {
        if ($line -match '^\s*Unique Name\s+Friendly Name\s+Version\s+Managed') { $started = $true; continue }
        if (-not $started) { continue }
        if (-not $line.Trim()) { continue }

        $match = [regex]::Match($line, '^(?<unique>\S+)\s+(?<rest>.*?)\s+(?<version>\d+(\.\d+){1,3})\s+(?<managed>True|False)\s*$')
        if (-not $match.Success) { continue }

        $unique = $match.Groups['unique'].Value
        [pscustomobject]@{
            uniqueName   = $unique
            friendlyName = $match.Groups['rest'].Value.Trim()
            version      = $match.Groups['version'].Value
            managed      = $match.Groups['managed'].Value -eq 'True'
            # pac pads the unique name column to a fixed width and cuts anything longer. A name at
            # exactly the limit may be a truncation, and a truncated unique name passed to
            # pac solution export fails or, worse, matches the wrong solution.
            possiblyTruncated = $unique.Length -ge 48
        }
    }
}

# --------------------------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $Path)) {
    Stop-WithError "Path '$Path' does not exist."
}
$Path = (Resolve-Path -LiteralPath $Path).Path

$pluginRoot = Split-Path -Parent $PSScriptRoot
$templatesRoot = Join-Path $pluginRoot 'templates'
$baselinePath = Join-Path $PSScriptRoot 'standards-baseline.json'

$notes = New-Object System.Collections.Generic.List[string]

try {

# ---- tooling ------------------------------------------------------------------------------

$tooling = [ordered]@{
    pwsh    = Get-ToolReport -Name 'pwsh' -VersionArguments @('--version')
    git     = Get-ToolReport -Name 'git' -VersionArguments @('--version')
    pac     = Get-ToolReport -Name 'pac' -VersionArguments @('--version')
    dotnet  = Get-ToolReport -Name 'dotnet' -VersionArguments @('--version')
    node    = Get-ToolReport -Name 'node' -VersionArguments @('--version')
    npm     = Get-ToolReport -Name 'npm' -VersionArguments @('--version')
    gh      = Get-ToolReport -Name 'gh' -VersionArguments @('--version')
}
$tooling['currentPowerShell'] = [ordered]@{
    present = $true
    version = $PSVersionTable.PSVersion.ToString()
    edition = [string]$PSVersionTable.PSEdition
}

if (-not $tooling.pwsh.present -and $PSVersionTable.PSVersion.Major -lt 6) {
    $notes.Add('pwsh 7 is not installed. The scaffold and sync-solution.ps1 run on Windows PowerShell 5.1, but pac and PCF tooling are only tested against pwsh 7.') | Out-Null
}
if (-not $tooling.pac.present) {
    $notes.Add('pac is not installed, so no environment fact could be read. Install the Power Platform CLI to let discovery propose the publisher, prefix and solution from Dataverse.') | Out-Null
}

# ---- repository ---------------------------------------------------------------------------

$inventory = Get-RepoInventory -Root $Path -Limit $MaxFiles
if ($inventory.Truncated) {
    $notes.Add("The file walk stopped at $MaxFiles files; counts below are lower bounds.") | Out-Null
}

$files = $inventory.Files

# The harness is exactly what templates/ holds, so ask templates/ rather than hardcoding a list
# that drifts the next time a standards file is added.
$harnessFiles = @()
if (Test-Path -LiteralPath $templatesRoot) {
    $harnessFiles = @(Get-ChildItem -LiteralPath $templatesRoot -Recurse -File -Force |
        ForEach-Object { $_.FullName.Substring((Resolve-Path -LiteralPath $templatesRoot).Path.Length).TrimStart('\', '/') -replace '\\', '/' })
}
else {
    $notes.Add("templates/ was not found at $templatesRoot; the plugin installation looks incomplete.") | Out-Null
}

$present = @($harnessFiles | Where-Object { $files -contains $_ })
$missing = @($harnessFiles | Where-Object { $files -notcontains $_ })

# The three files the harness cannot merge into silently. .gitignore is excluded on purpose: an
# existing .gitignore is a collision to resolve, not evidence that the harness is installed.
$harnessMarkers = @('CLAUDE.md', 'docs/agents/development-standards.md', 'scripts/sync-solution.ps1')
$markersPresent = @($harnessMarkers | Where-Object { $files -contains $_ })

$solutionXmlFiles = Select-Files -Files $files -Pattern '(?i)(^|/)Other/Solution\.xml$' -Limit 50
$projectFiles = Select-Files -Files $files -Pattern '(?i)\.csproj$' -Limit 100
$packageJsonFiles = Select-Files -Files $files -Pattern '(?i)(^|/)package\.json$' -Limit 50
$pcfManifestFiles = Select-Files -Files $files -Pattern '(?i)(^|/)ControlManifest\.Input\.xml$' -Limit 50

$solutions = @(Get-SolutionFacts -Root $Path -SolutionXmlFiles $solutionXmlFiles)
$projects = @(Get-ProjectFacts -Root $Path -ProjectFiles $projectFiles)
$packages = @(Get-PackageJsonFacts -Root $Path -PackageFiles $packageJsonFiles)
$pcfControls = @(Get-PcfFacts -Root $Path -ManifestFiles $pcfManifestFiles)

$allNodeDependencies = @{}
foreach ($package in $packages) {
    if ($package.dependencies) {
        foreach ($key in $package.dependencies.Keys) {
            if (-not $allNodeDependencies.ContainsKey($key)) { $allNodeDependencies[$key] = $package.dependencies[$key] }
        }
    }
}

$codeArtifacts = @($files | Where-Object {
    $_ -match '(?i)\.(cs|csproj|sln|js|mjs|cjs|ts|tsx|jsx)$' -or
    $_ -match '(?i)(^|/)(package\.json|Solution\.xml|ControlManifest\.Input\.xml)$'
})

$classification = if ($markersPresent.Count -eq 0 -and $codeArtifacts.Count -eq 0) { 'greenfield' } else { 'existing' }

$git = [ordered]@{
    isRepository = $false
    branch       = $null
    commitCount  = $null
    remoteUrl    = $null
    isDirty      = $null
}
if ($tooling.git.present) {
    $insideRun = Invoke-Tool -Name 'git' -Arguments @('-C', $Path, 'rev-parse', '--is-inside-work-tree') -Timeout 20
    if ($insideRun.Ran -and $insideRun.ExitCode -eq 0 -and $insideRun.Stdout.Trim() -eq 'true') {
        $git['isRepository'] = $true

        $branchRun = Invoke-Tool -Name 'git' -Arguments @('-C', $Path, 'rev-parse', '--abbrev-ref', 'HEAD') -Timeout 20
        if ($branchRun.ExitCode -eq 0) { $git['branch'] = $branchRun.Stdout.Trim() }

        $countRun = Invoke-Tool -Name 'git' -Arguments @('-C', $Path, 'rev-list', '--count', 'HEAD') -Timeout 20
        if ($countRun.ExitCode -eq 0) { $git['commitCount'] = [int]$countRun.Stdout.Trim() } else { $git['commitCount'] = 0 }

        $remoteRun = Invoke-Tool -Name 'git' -Arguments @('-C', $Path, 'remote', 'get-url', 'origin') -Timeout 20
        if ($remoteRun.ExitCode -eq 0) { $git['remoteUrl'] = $remoteRun.Stdout.Trim() }

        $statusRun = Invoke-Tool -Name 'git' -Arguments @('-C', $Path, 'status', '--porcelain') -Timeout 30
        if ($statusRun.ExitCode -eq 0) { $git['isDirty'] = [bool]$statusRun.Stdout.Trim() }
    }
}

$repository = [ordered]@{
    path           = $Path
    classification = $classification
    fileCount      = $files.Count
    walkTruncated  = $inventory.Truncated
    prunedFolders  = @($inventory.Pruned | Sort-Object)
    git            = $git
    harness        = [ordered]@{
        installed    = $markersPresent.Count -gt 0
        markers      = $markersPresent
        presentFiles = $present
        missingFiles = $missing
    }
    agentDocs      = [ordered]@{
        claudeMd        = $files -contains 'CLAUDE.md'
        agentsMd        = $files -contains 'AGENTS.md'
        copilotMd       = @($files | Where-Object { $_ -match '(?i)^\.github/copilot-instructions\.md$' }).Count -gt 0
        cursorRules     = @($files | Where-Object { $_ -match '(?i)^\.cursor' }).Count -gt 0
        claudeMdFiles   = Select-Files -Files $files -Pattern '(?i)(^|/)CLAUDE\.md$' -Limit 20
        docsAgents      = Select-Files -Files $files -Pattern '(?i)^docs/agents/' -Limit 30
        docsDevelopment = Select-Files -Files $files -Pattern '(?i)^docs/development/' -Limit 30
        adrs            = Select-Files -Files $files -Pattern '(?i)^docs/adr/' -Limit 50
    }
    layout         = [ordered]@{
        expected = [ordered]@{}
        actual   = [ordered]@{
            solutionFolders   = @($solutions | ForEach-Object { $_.folder })
            pluginFolders     = @($inventory.Directories | Where-Object { $_ -match '(?i)(^|/)plugins?$' } | Select-Object -First 20)
            customApiFolders  = @($inventory.Directories | Where-Object { $_ -match '(?i)(^|/)customapis?$' } | Select-Object -First 20)
            webResourceFolders = @($inventory.Directories | Where-Object { $_ -match '(?i)(^|/)webresources?$' } | Select-Object -First 20)
            testFolders       = @($inventory.Directories | Where-Object { $_ -match '(?i)^tests?(/|$)' } | Select-Object -First 20)
        }
    }
    pipelines      = [ordered]@{
        githubWorkflows = Select-Files -Files $files -Pattern '(?i)^\.github/workflows/.+\.(yml|yaml)$' -Limit 30
        azurePipelines  = Select-Files -Files $files -Pattern '(?i)(^|/)azure-pipelines.*\.(yml|yaml)$' -Limit 30
    }
    counts         = [ordered]@{
        csharp        = @($files | Where-Object { $_ -match '(?i)\.cs$' }).Count
        javascript    = @($files | Where-Object { $_ -match '(?i)\.(js|mjs|cjs)$' }).Count
        typescript    = @($files | Where-Object { $_ -match '(?i)\.(ts|tsx)$' }).Count
        codeArtifacts = $codeArtifacts.Count
    }
}

foreach ($expected in @('src/Plugins', 'src/CustomAPIs', 'src/WebResources', 'src/Solutions', 'tests/Plugins', 'tests/CustomAPIs', 'docs/adr')) {
    $repository.layout.expected[$expected] = ($inventory.Directories -contains $expected)
}

$dotnet = [ordered]@{
    solutionFiles = Select-Files -Files $files -Pattern '(?i)\.slnx?$' -Limit 20
    projects      = $projects
    projectCount  = $projects.Count
}

$node = [ordered]@{
    packages       = $packages
    eslintFlat     = Select-Files -Files $files -Pattern '(?i)(^|/)eslint\.config\.(js|mjs|cjs|ts)$' -Limit 20
    eslintLegacy   = Select-Files -Files $files -Pattern '(?i)(^|/)\.eslintrc(\..+)?$' -Limit 20
    tsconfigs      = Select-Files -Files $files -Pattern '(?i)(^|/)tsconfig.*\.json$' -Limit 20
    vitestConfigs  = Select-Files -Files $files -Pattern '(?i)(^|/)vitest\.config\.(js|mjs|cjs|ts)$' -Limit 20
    jestConfigs    = Select-Files -Files $files -Pattern '(?i)(^|/)jest\.config\.(js|mjs|cjs|ts|json)$' -Limit 20
}

# ---- environment --------------------------------------------------------------------------

$environment = [ordered]@{
    probed             = -not $SkipEnvironment
    authProfiles       = @()
    connected          = $false
    org                = $null
    nameSignal         = 'unknown'
    treatAsProduction  = $true
    solutions          = @()
    solutionCount      = 0
    unmanagedSolutions = 0
    resolvedPublisher  = $null
    errors             = @()
}

if (-not $SkipEnvironment -and $tooling.pac.present) {
    $authRun = Invoke-Tool -Name 'pac' -Arguments @('auth', 'list')
    if ($authRun.Ran -and $authRun.ExitCode -eq 0) {
        $environment['authProfiles'] = @(Get-AuthProfiles -Output $authRun.Stdout)
    }
    else {
        $environment.errors += "pac auth list failed: $(if ($authRun.Error) { $authRun.Error } else { $authRun.Stderr })"
    }

    $whoArguments = @('org', 'who')
    if ($EnvironmentUrl) { $whoArguments += @('--environment', $EnvironmentUrl) }
    $whoRun = Invoke-Tool -Name 'pac' -Arguments $whoArguments -Timeout ([Math]::Max($TimeoutSeconds, 120))

    if ($whoRun.Ran -and $whoRun.ExitCode -eq 0) {
        $org = Get-OrgFacts -Output $whoRun.Stdout
        $environment['connected'] = [bool]$org['url']
        $environment['org'] = $org
        $environment['nameSignal'] = Get-EnvironmentNameSignal -Values @($org['friendlyName'], $org['url'])
        # The standards treat an unverified environment as production. A name that merely looks
        # like a dev environment is a signal, never a verification.
        $environment['treatAsProduction'] = ($environment['nameSignal'] -ne 'dev')
    }
    else {
        $detail = if ($whoRun.Error) { $whoRun.Error } elseif ($whoRun.Stderr) { $whoRun.Stderr } else { $whoRun.Stdout }
        $environment.errors += "pac org who failed: $detail"
        $notes.Add('No Dataverse environment is connected, so the publisher, prefix and solution could not be read from the platform. Authenticate with pac auth create, or supply the values.') | Out-Null
    }

    if ($environment['connected']) {
        $listArguments = @('solution', 'list')
        if ($EnvironmentUrl) { $listArguments += @('--environment', $EnvironmentUrl) }
        $listRun = Invoke-Tool -Name 'pac' -Arguments $listArguments -Timeout ([Math]::Max($TimeoutSeconds, 180))

        if ($listRun.Ran -and $listRun.ExitCode -eq 0) {
            $environmentSolutions = @(Get-EnvironmentSolutions -Output $listRun.Stdout)
            $environment['solutionCount'] = $environmentSolutions.Count
            $environment['unmanagedSolutions'] = @($environmentSolutions | Where-Object { -not $_.managed }).Count
            # Only the unmanaged ones can be a DEV working solution, and the list is long in a
            # mature environment: report those, capped.
            $environment['solutions'] = @($environmentSolutions | Where-Object { -not $_.managed } | Select-Object -First 100)
            if (@($environmentSolutions | Where-Object { $_.possiblyTruncated }).Count -gt 0) {
                $notes.Add('pac solution list truncates the unique name column, and at least one name reached that width. Confirm a truncated name against the environment before using it as SolutionName.') | Out-Null
            }
        }
        else {
            $environment.errors += "pac solution list failed: $(if ($listRun.Error) { $listRun.Error } else { $listRun.Stderr })"
        }
    }

    if ($ResolvePublisherFromSolution -and $environment['connected']) {
        $exportRoot = Join-Path $script:scratchRoot 'publisher'
        New-Item -ItemType Directory -Path $exportRoot -Force | Out-Null
        $zipPath = Join-Path $exportRoot "$ResolvePublisherFromSolution.zip"

        $exportArguments = @('solution', 'export', '--name', $ResolvePublisherFromSolution, '--path', $zipPath, '--overwrite')
        if ($EnvironmentUrl) { $exportArguments += @('--environment', $EnvironmentUrl) }
        $exportRun = Invoke-Tool -Name 'pac' -Arguments $exportArguments -Timeout ([Math]::Max($TimeoutSeconds, 600))

        if ($exportRun.Ran -and $exportRun.ExitCode -eq 0 -and (Test-Path -LiteralPath $zipPath)) {
            $extractRoot = Join-Path $exportRoot 'unzipped'
            try {
                Expand-Archive -LiteralPath $zipPath -DestinationPath $extractRoot -Force
                $solutionXml = Get-ChildItem -LiteralPath $extractRoot -Filter 'solution.xml' -Recurse -File |
                    Select-Object -First 1
                if ($solutionXml) {
                    $facts = @(Get-SolutionFacts -Root $extractRoot -SolutionXmlFiles @(
                        ($solutionXml.FullName.Substring($extractRoot.Length).TrimStart('\', '/') -replace '\\', '/')
                    ))
                    # The archive keeps solution.xml at the root, not under Other/, so parse it directly.
                    if (-not $facts -or -not $facts[0].uniqueName) {
                        $document = Read-XmlFile -FullPath $solutionXml.FullName
                        $manifest = if ($document) { $document.SelectSingleNode('/ImportExportXml/SolutionManifest') } else { $null }
                        if ($manifest) {
                            $publisher = $manifest.SelectSingleNode('Publisher')
                            $localized = if ($publisher) { $publisher.SelectSingleNode('LocalizedNames/LocalizedName') } else { $null }
                            $environment['resolvedPublisher'] = [ordered]@{
                                solutionUniqueName  = $(if ($manifest.SelectSingleNode('UniqueName')) { $manifest.SelectSingleNode('UniqueName').InnerText } else { $null })
                                publisherUniqueName = $(if ($publisher -and $publisher.SelectSingleNode('UniqueName')) { $publisher.SelectSingleNode('UniqueName').InnerText } else { $null })
                                publisherName       = $(if ($localized) { $localized.GetAttribute('description') } else { $null })
                                publisherPrefix     = $(if ($publisher -and $publisher.SelectSingleNode('CustomizationPrefix')) { $publisher.SelectSingleNode('CustomizationPrefix').InnerText } else { $null })
                                source              = "pac solution export $ResolvePublisherFromSolution"
                            }
                        }
                    }
                    else {
                        $environment['resolvedPublisher'] = [ordered]@{
                            solutionUniqueName  = $facts[0].uniqueName
                            publisherUniqueName = $facts[0].publisherUniqueName
                            publisherName       = $facts[0].publisherName
                            publisherPrefix     = $facts[0].publisherPrefix
                            source              = "pac solution export $ResolvePublisherFromSolution"
                        }
                    }
                }
                else {
                    $environment.errors += 'The exported solution archive contained no solution.xml.'
                }
            }
            catch {
                $environment.errors += "The exported solution archive could not be read: $($_.Exception.Message)"
            }
        }
        else {
            $detail = if ($exportRun.Error) { $exportRun.Error } elseif ($exportRun.Stderr) { $exportRun.Stderr } else { $exportRun.Stdout }
            $environment.errors += "pac solution export '$ResolvePublisherFromSolution' failed: $detail"
        }
    }
}
elseif (-not $SkipEnvironment) {
    $environment['probed'] = $false
    $environment.errors += 'pac is not installed; no environment fact was read.'
}

# ---- deviations from the shipped standards -------------------------------------------------

$baseline = $null
if (Test-Path -LiteralPath $baselinePath) {
    try { $baseline = [System.IO.File]::ReadAllText($baselinePath) | ConvertFrom-Json }
    catch { $notes.Add("standards-baseline.json could not be parsed: $($_.Exception.Message)") | Out-Null }
}
else {
    $notes.Add("standards-baseline.json was not found at $baselinePath; no deviation check ran.") | Out-Null
}

function Get-NodeDependency {
    param([string]$Name)

    if ($allNodeDependencies.ContainsKey($Name)) { return $allNodeDependencies[$Name] }
    return $null
}

function Get-PackageVersions {
    param([string]$Id)

    $found = @()
    foreach ($project in $projects) {
        foreach ($package in @($project.packages)) {
            if ($package.id -and $package.id -eq $Id) {
                $found += [pscustomobject]@{ version = $package.version; project = $project.path }
            }
        }
    }
    return $found
}

function New-Assessment {
    param(
        $Assertion,
        [string]$Status,
        $Detected,
        [string[]]$Evidence = @(),
        [string]$Detail
    )

    return [ordered]@{
        id            = $Assertion.id
        kind          = $Assertion.kind
        topic         = $Assertion.topic
        standard      = $Assertion.standard
        standardLabel = $Assertion.standardLabel
        targetFile    = $Assertion.targetFile
        status        = $Status
        detected      = $Detected
        detail        = $Detail
        evidence      = @($Evidence | Select-Object -First 10)
        guidance      = $Assertion.guidance
    }
}

$assessments = @()
$staleBaseline = @()

if ($baseline) {
    $nonTestProjects = @($projects | Where-Object { $_.role -ne 'test' })
    $testProjects = @($projects | Where-Object { $_.role -eq 'test' })

    foreach ($assertion in $baseline.assertions) {
        # The baseline is only trustworthy while the text it quotes is still in the template it
        # points at. Check that before using the assertion to judge somebody's repository.
        if ($assertion.assertedIn -and $assertion.assertedText) {
            $assertedFile = Join-Path $pluginRoot ($assertion.assertedIn -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            if (Test-Path -LiteralPath $assertedFile) {
                $content = [System.IO.File]::ReadAllText($assertedFile)
                if (-not $content.Contains($assertion.assertedText)) {
                    $staleBaseline += [ordered]@{
                        id       = $assertion.id
                        file     = $assertion.assertedIn
                        expected = $assertion.assertedText
                        detail   = 'The baseline quotes text that is no longer in that file. Update scripts/standards-baseline.json.'
                    }
                }
            }
            else {
                $staleBaseline += [ordered]@{
                    id       = $assertion.id
                    file     = $assertion.assertedIn
                    expected = $assertion.assertedText
                    detail   = 'The file the baseline points at does not exist.'
                }
            }
        }

        switch ($assertion.id) {

            'plugins.targetFramework' {
                $frameworks = @($nonTestProjects | ForEach-Object { $_.targetFrameworks } | Where-Object { $_ } | Select-Object -Unique)
                if (-not $nonTestProjects) { $assessments += New-Assessment -Assertion $assertion -Status 'not-applicable' -Detected $null -Detail 'No C# projects in the repository.' }
                elseif (-not $frameworks) { $assessments += New-Assessment -Assertion $assertion -Status 'unknown' -Detected $null -Detail 'C# projects exist but declare no target framework this script could read.' -Evidence @($nonTestProjects | ForEach-Object { $_.path }) }
                else {
                    $offenders = @($nonTestProjects | Where-Object { @($_.targetFrameworks) -notcontains 'net462' })
                    $status = if ($offenders.Count -eq 0) { 'match' } else { 'deviates' }
                    $assessments += New-Assessment -Assertion $assertion -Status $status -Detected $frameworks -Evidence @($offenders | ForEach-Object { "$($_.path) -> $(@($_.targetFrameworks) -join ', ')" })
                }
            }

            'plugins.sdkStyle' {
                if (-not $nonTestProjects) { $assessments += New-Assessment -Assertion $assertion -Status 'not-applicable' -Detected $null -Detail 'No C# projects in the repository.' }
                else {
                    $legacy = @($nonTestProjects | Where-Object { -not $_.sdkStyle })
                    $status = if ($legacy.Count -eq 0) { 'match' } else { 'deviates' }
                    $assessments += New-Assessment -Assertion $assertion -Status $status -Detected $(if ($legacy.Count -eq 0) { 'sdk-style' } else { 'legacy csproj' }) -Evidence @($legacy | ForEach-Object { $_.path })
                }
            }

            'plugins.strongNaming' {
                if (-not $nonTestProjects) { $assessments += New-Assessment -Assertion $assertion -Status 'not-applicable' -Detected $null -Detail 'No C# projects in the repository.' }
                else {
                    $signed = @($nonTestProjects | Where-Object { $_.signAssembly })
                    $snkFiles = Select-Files -Files $files -Pattern '(?i)\.snk$' -Limit 10
                    $status = if ($signed.Count -eq 0 -and $snkFiles.Count -eq 0) { 'match' } else { 'deviates' }
                    $assessments += New-Assessment -Assertion $assertion -Status $status -Detected $(if ($status -eq 'match') { 'unsigned' } else { 'strong-named' }) -Evidence (@($signed | ForEach-Object { $_.path }) + @($snkFiles))
                }
            }

            'plugins.test.xunit' {
                $found = Get-PackageVersions -Id 'xunit'
                $otherRunners = @()
                foreach ($runner in @('nunit', 'MSTest.TestFramework', 'xunit.v3')) {
                    $otherRunners += Get-PackageVersions -Id $runner | ForEach-Object { "$runner $($_.version) ($($_.project))" }
                }
                if (-not $testProjects) { $assessments += New-Assessment -Assertion $assertion -Status 'not-applicable' -Detected $null -Detail 'No test projects in the repository.' }
                elseif ($otherRunners.Count -gt 0 -and $found.Count -eq 0) { $assessments += New-Assessment -Assertion $assertion -Status 'deviates' -Detected $otherRunners -Detail 'The repository uses a different test runner.' -Evidence @($testProjects | ForEach-Object { $_.path }) }
                elseif ($found.Count -eq 0) { $assessments += New-Assessment -Assertion $assertion -Status 'unknown' -Detected $null -Detail 'Test projects exist but reference no runner this script recognises.' -Evidence @($testProjects | ForEach-Object { $_.path }) }
                else {
                    $versions = @($found | ForEach-Object { $_.version } | Select-Object -Unique)
                    $status = if (@($versions | Where-Object { $_ -ne '2.9.3' }).Count -eq 0) { 'match' } else { 'deviates' }
                    $assessments += New-Assessment -Assertion $assertion -Status $status -Detected $versions -Evidence @($found | ForEach-Object { "$($_.project) -> xunit $($_.version)" })
                }
            }

            'plugins.test.fakeXrmEasyPlugins' {
                $found = @()
                foreach ($project in $projects) {
                    foreach ($package in @($project.packages)) {
                        if ($package.id -match '(?i)^FakeXrmEasy') { $found += [pscustomobject]@{ id = $package.id; version = $package.version; project = $project.path } }
                    }
                }
                if (-not $testProjects) { $assessments += New-Assessment -Assertion $assertion -Status 'not-applicable' -Detected $null -Detail 'No test projects in the repository.' }
                elseif ($found.Count -eq 0) { $assessments += New-Assessment -Assertion $assertion -Status 'deviates' -Detected $null -Detail 'No FakeXrmEasy package is referenced, so plugin tests either do not exist or use another approach.' -Evidence @($testProjects | ForEach-Object { $_.path }) }
                else {
                    $pluginPackage = @($found | Where-Object { $_.id -match '(?i)^FakeXrmEasy\.Plugins\.v9$' })
                    $status = if ($pluginPackage.Count -gt 0 -and @($pluginPackage | Where-Object { $_.version -ne '2.9.4' }).Count -eq 0) { 'match' } else { 'deviates' }
                    $assessments += New-Assessment -Assertion $assertion -Status $status -Detected @($found | ForEach-Object { "$($_.id) $($_.version)" } | Select-Object -Unique) -Evidence @($found | ForEach-Object { "$($_.project) -> $($_.id) $($_.version)" })
                }
            }

            'plugins.test.fakeXrmEasyMessages' {
                $found = Get-PackageVersions -Id 'FakeXrmEasy.Messages.v9'
                if ($found.Count -eq 0) { $assessments += New-Assessment -Assertion $assertion -Status 'not-applicable' -Detected $null -Detail 'The package is optional and is not referenced.' }
                else {
                    $versions = @($found | ForEach-Object { $_.version } | Select-Object -Unique)
                    $status = if (@($versions | Where-Object { $_ -ne '2.9.4' }).Count -eq 0) { 'match' } else { 'deviates' }
                    $assessments += New-Assessment -Assertion $assertion -Status $status -Detected $versions -Evidence @($found | ForEach-Object { "$($_.project) -> $($_.version)" })
                }
            }

            'pcf.controlType' {
                if (-not $pcfControls) { $assessments += New-Assessment -Assertion $assertion -Status 'not-applicable' -Detected $null -Detail 'No PCF controls in the repository.' }
                else {
                    $types = @($pcfControls | ForEach-Object { if ($_.controlType) { $_.controlType } else { 'standard' } } | Select-Object -Unique)
                    $status = if (@($types | Where-Object { $_ -ne 'virtual' }).Count -eq 0) { 'match' } else { 'deviates' }
                    $assessments += New-Assessment -Assertion $assertion -Status $status -Detected $types -Evidence @($pcfControls | ForEach-Object { "$($_.manifest) -> control-type=$(if ($_.controlType) { $_.controlType } else { 'standard (default)' })" })
                }
            }

            { $_ -in @('pcf.platformLibrary.react', 'pcf.platformLibrary.fluent') } {
                if (-not $pcfControls) { $assessments += New-Assessment -Assertion $assertion -Status 'not-applicable' -Detected $null -Detail 'No PCF controls in the repository.' }
                else {
                    $libraryName = $assertion.platformLibrary
                    $found = @()
                    foreach ($control in $pcfControls) {
                        foreach ($library in @($control.platformLibraries)) {
                            if ($library.name -and $library.name -match "(?i)^$libraryName") {
                                $found += [pscustomobject]@{ version = $library.version; manifest = $control.manifest }
                            }
                        }
                    }
                    if ($found.Count -eq 0) { $assessments += New-Assessment -Assertion $assertion -Status 'deviates' -Detected $null -Detail "No $libraryName platform library is declared, so the control bundles its own copy." -Evidence @($pcfControls | ForEach-Object { $_.manifest }) }
                    else {
                        $versions = @($found | ForEach-Object { $_.version } | Select-Object -Unique)
                        $status = if (@($versions | Where-Object { $_ -ne $assertion.standard }).Count -eq 0) { 'match' } else { 'deviates' }
                        $assessments += New-Assessment -Assertion $assertion -Status $status -Detected $versions -Evidence @($found | ForEach-Object { "$($_.manifest) -> $libraryName $($_.version)" })
                    }
                }
            }

            { $_ -in @('pcf.test', 'javascript.test') } {
                $applies = if ($assertion.id -eq 'pcf.test') { [bool]$pcfControls } else { $repository.counts.javascript -gt 0 }
                if (-not $applies -or -not $packages) { $assessments += New-Assessment -Assertion $assertion -Status 'not-applicable' -Detected $null -Detail 'No relevant JavaScript or PCF code with a package.json.' }
                else {
                    $vitest = Get-NodeDependency -Name 'vitest'
                    $jest = Get-NodeDependency -Name 'jest'
                    if ($vitest -and -not $jest) { $assessments += New-Assessment -Assertion $assertion -Status 'match' -Detected "vitest $vitest" -Evidence $node.vitestConfigs }
                    elseif ($jest) { $assessments += New-Assessment -Assertion $assertion -Status 'deviates' -Detected "jest $jest" -Detail 'The repository tests with Jest.' -Evidence (@($node.jestConfigs) + @($packages | ForEach-Object { $_.path })) }
                    else { $assessments += New-Assessment -Assertion $assertion -Status 'unknown' -Detected $null -Detail 'No JavaScript test runner is declared in any package.json.' -Evidence @($packages | ForEach-Object { $_.path }) }
                }
            }

            'javascript.lint' {
                if (-not $packages) { $assessments += New-Assessment -Assertion $assertion -Status 'not-applicable' -Detected $null -Detail 'No package.json in the repository.' }
                else {
                    $eslint = Get-NodeDependency -Name 'eslint'
                    $flat = @($node.eslintFlat).Count -gt 0
                    $legacy = @($node.eslintLegacy).Count -gt 0
                    $major = if ($eslint) { [regex]::Match($eslint, '(\d+)').Groups[1].Value } else { $null }
                    if (-not $eslint) { $assessments += New-Assessment -Assertion $assertion -Status 'deviates' -Detected $null -Detail 'ESLint is not a dependency of any package.json.' -Evidence @($packages | ForEach-Object { $_.path }) }
                    elseif ($major -eq '9' -and $flat -and -not $legacy) { $assessments += New-Assessment -Assertion $assertion -Status 'match' -Detected "eslint $eslint (flat config)" -Evidence $node.eslintFlat }
                    else { $assessments += New-Assessment -Assertion $assertion -Status 'deviates' -Detected "eslint $eslint$(if ($legacy) { ' (.eslintrc)' } elseif ($flat) { ' (flat config)' } else { ' (no config file found)' })" -Evidence (@($node.eslintLegacy) + @($node.eslintFlat)) }
                }
            }

            'javascript.language' {
                $webResourceFolders = @($repository.layout.actual.webResourceFolders)
                $typescriptInWebResources = @($files | Where-Object {
                    $_ -match '(?i)\.tsx?$' -and $_ -match '(?i)(^|/)webresources?/'
                })
                $bundlers = @('webpack', 'rollup', 'vite', 'esbuild', 'parcel') | Where-Object { Get-NodeDependency -Name $_ }

                if (-not $webResourceFolders -and $repository.counts.javascript -eq 0) { $assessments += New-Assessment -Assertion $assertion -Status 'not-applicable' -Detected $null -Detail 'No web resources in the repository.' }
                elseif ($typescriptInWebResources.Count -gt 0) { $assessments += New-Assessment -Assertion $assertion -Status 'deviates' -Detected 'TypeScript web resources' -Detail 'Web resources are authored in TypeScript, so the committed file is not the deployed file.' -Evidence $typescriptInWebResources }
                elseif ($bundlers) { $assessments += New-Assessment -Assertion $assertion -Status 'unknown' -Detected "bundler present: $($bundlers -join ', ')" -Detail 'A bundler is a dependency. Confirm whether web resources go through it, or only PCF does.' -Evidence @($packages | ForEach-Object { $_.path }) }
                else { $assessments += New-Assessment -Assertion $assertion -Status 'match' -Detected 'plain JavaScript' -Evidence $webResourceFolders }
            }

            'alm.solutionMirrorPath' {
                if (-not $solutions) { $assessments += New-Assessment -Assertion $assertion -Status 'not-applicable' -Detected $null -Detail 'No unpacked solution is committed.' }
                else {
                    $misplaced = @($solutions | Where-Object { $_.folder -ne "src/Solutions/$($_.uniqueName)" })
                    $status = if ($misplaced.Count -eq 0) { 'match' } else { 'deviates' }
                    $assessments += New-Assessment -Assertion $assertion -Status $status -Detected @($solutions | ForEach-Object { $_.folder }) -Evidence @($misplaced | ForEach-Object { "$($_.folder) holds solution '$($_.uniqueName)'; the standard expects src/Solutions/$($_.uniqueName)" })
                }
            }

            'alm.singleSolution' {
                $unmanaged = @($solutions | Where-Object { $_.managed -ne $true })
                if (-not $solutions) { $assessments += New-Assessment -Assertion $assertion -Status 'not-applicable' -Detected $null -Detail 'No unpacked solution is committed.' }
                else {
                    $status = if ($unmanaged.Count -le 1) { 'match' } else { 'deviates' }
                    $assessments += New-Assessment -Assertion $assertion -Status $status -Detected $unmanaged.Count -Evidence @($unmanaged | ForEach-Object { "$($_.uniqueName) ($($_.folder))" })
                }
            }

            'layout.folders' {
                $missingFolders = @($repository.layout.expected.Keys | Where-Object { -not $repository.layout.expected[$_] })
                $alternatives = @()
                foreach ($group in @(
                    @{ Expected = 'src/Plugins'; Found = $repository.layout.actual.pluginFolders },
                    @{ Expected = 'src/CustomAPIs'; Found = $repository.layout.actual.customApiFolders },
                    @{ Expected = 'src/WebResources'; Found = $repository.layout.actual.webResourceFolders },
                    @{ Expected = 'src/Solutions'; Found = $repository.layout.actual.solutionFolders }
                )) {
                    foreach ($found in @($group.Found)) {
                        if ($found -and $found -notlike "$($group.Expected)*") { $alternatives += "$found (the standard references $($group.Expected))" }
                    }
                }
                if ($classification -eq 'greenfield') { $assessments += New-Assessment -Assertion $assertion -Status 'not-applicable' -Detected $null -Detail 'Empty folder: the scaffold creates the layout.' }
                elseif ($alternatives.Count -eq 0 -and $missingFolders.Count -eq 0) { $assessments += New-Assessment -Assertion $assertion -Status 'match' -Detected 'the expected layout' }
                else { $assessments += New-Assessment -Assertion $assertion -Status 'deviates' -Detected @($alternatives | Select-Object -Unique) -Detail "Missing from the expected layout: $(@($missingFolders) -join ', ')" -Evidence @($alternatives | Select-Object -Unique) }
            }

            default {
                $assessments += New-Assessment -Assertion $assertion -Status 'unknown' -Detected $null -Detail 'No detection is implemented for this assertion.'
            }
        }
    }
}

# ---- proposed values -----------------------------------------------------------------------

function New-Proposal {
    param([string]$Value, [string]$Source, [string]$Confidence, [string[]]$Alternatives = @())

    return [ordered]@{
        value        = $Value
        source       = $Source
        confidence   = $Confidence
        alternatives = @($Alternatives | Where-Object { $_ } | Select-Object -Unique | Select-Object -First 10)
    }
}

$primarySolution = @($solutions | Where-Object { $_.managed -ne $true -and $_.uniqueName }) | Select-Object -First 1
$resolved = $environment['resolvedPublisher']

# SolutionName
$solutionProposal = $null
if ($primarySolution) {
    $solutionProposal = New-Proposal -Value $primarySolution.uniqueName -Source "$($primarySolution.manifest) (committed solution manifest)" -Confidence 'high' -Alternatives @($solutions | ForEach-Object { $_.uniqueName })
}
elseif ($resolved -and $resolved['solutionUniqueName']) {
    $solutionProposal = New-Proposal -Value $resolved['solutionUniqueName'] -Source $resolved['source'] -Confidence 'high'
}
elseif (@($environment['solutions']).Count -eq 1) {
    $solutionProposal = New-Proposal -Value $environment['solutions'][0].uniqueName -Source 'pac solution list (the only unmanaged solution in the environment)' -Confidence 'medium'
}
elseif (@($environment['solutions']).Count -gt 1) {
    $solutionProposal = New-Proposal -Value $null -Source 'pac solution list returned several unmanaged solutions; the user has to choose' -Confidence 'none' -Alternatives @($environment['solutions'] | ForEach-Object { $_.uniqueName })
}
else {
    $solutionProposal = New-Proposal -Value $null -Source 'No committed solution and no environment solution list' -Confidence 'none'
}

# Publisher name and prefix
$publisherNameProposal = New-Proposal -Value $null -Source 'Not derivable: no committed solution manifest and no exported solution' -Confidence 'none'
$publisherPrefixProposal = New-Proposal -Value $null -Source 'Not derivable: no committed solution manifest and no exported solution' -Confidence 'none'

if ($primarySolution -and $primarySolution.publisherPrefix) {
    $publisherNameProposal = New-Proposal -Value $primarySolution.publisherName -Source "$($primarySolution.manifest) (committed solution manifest)" -Confidence 'high' -Alternatives @($solutions | ForEach-Object { $_.publisherName })
    $publisherPrefixProposal = New-Proposal -Value $primarySolution.publisherPrefix -Source "$($primarySolution.manifest) (committed solution manifest)" -Confidence 'high' -Alternatives @($solutions | ForEach-Object { $_.publisherPrefix })
}
elseif ($resolved -and $resolved['publisherPrefix']) {
    $publisherNameProposal = New-Proposal -Value $resolved['publisherName'] -Source $resolved['source'] -Confidence 'high'
    $publisherPrefixProposal = New-Proposal -Value $resolved['publisherPrefix'] -Source $resolved['source'] -Confidence 'high'
}
elseif ($environment['connected']) {
    $hint = 'pac reports no publisher for an environment; re-run with -ResolvePublisherFromSolution <name> to read it out of an existing solution, or ask the user.'
    $publisherNameProposal = New-Proposal -Value $null -Source $hint -Confidence 'none'
    $publisherPrefixProposal = New-Proposal -Value $null -Source $hint -Confidence 'none'
}

# Prefix evidence from existing component names: bshcs_accountform.js, prefix_table, and so on.
$prefixCandidates = @{}
foreach ($file in @($files | Where-Object { $_ -match '(?i)(^|/)[a-z][a-z0-9]{1,7}_[a-z0-9]' })) {
    $leaf = [System.IO.Path]::GetFileName($file)
    $match = [regex]::Match($leaf, '^([a-z][a-z0-9]{1,7})_')
    if ($match.Success) {
        $candidate = $match.Groups[1].Value
        if ($candidate -in @('mscrm', 'msdyn', 'msdynce', 'test', 'adx')) { continue }
        if (-not $prefixCandidates.ContainsKey($candidate)) { $prefixCandidates[$candidate] = 0 }
        $prefixCandidates[$candidate] = $prefixCandidates[$candidate] + 1
    }
}
$prefixEvidence = @($prefixCandidates.Keys | Sort-Object { -$prefixCandidates[$_] } | Select-Object -First 5 |
    ForEach-Object { "$_ ($($prefixCandidates[$_]) file name(s))" })

if (-not $publisherPrefixProposal['value'] -and $prefixCandidates.Count -gt 0) {
    $best = @($prefixCandidates.Keys | Sort-Object { -$prefixCandidates[$_] })[0]
    $publisherPrefixProposal = New-Proposal -Value $best -Source "Inferred from component file names ($($prefixCandidates[$best]) match(es)). Confirm against the environment: a wrong prefix cannot be undone." -Confidence 'medium' -Alternatives $prefixEvidence
}

# RootNamespace
$namespaceProposal = New-Proposal -Value $null -Source 'No C# project declares a namespace' -Confidence 'none'
$declaredNamespaces = @($projects | Where-Object { $_.role -ne 'test' } | ForEach-Object {
    if ($_.rootNamespace) { $_.rootNamespace } elseif ($_.assemblyName) { $_.assemblyName } else { [System.IO.Path]::GetFileNameWithoutExtension($_.path) }
} | Where-Object { $_ } | Select-Object -Unique)

if ($declaredNamespaces.Count -gt 0) {
    # The shared root is the longest dotted prefix every project agrees on.
    $segments = @($declaredNamespaces | ForEach-Object { ,@($_ -split '\.') })
    $shared = @()
    for ($index = 0; ; $index++) {
        $current = $null
        $agree = $true
        foreach ($parts in $segments) {
            if ($index -ge $parts.Count) { $agree = $false; break }
            if ($null -eq $current) { $current = $parts[$index] }
            elseif ($parts[$index] -ne $current) { $agree = $false; break }
        }
        if (-not $agree -or $null -eq $current) { break }
        $shared += $current
    }
    $value = if ($shared.Count -gt 0) { $shared -join '.' } else { $declaredNamespaces[0] }
    $confidence = if ($shared.Count -gt 0) { 'high' } else { 'medium' }

    # With a single project the shared prefix is the whole namespace, which usually ends in the
    # layer it implements. The root namespace is what sits above that layer.
    $layerSegments = @('Plugins', 'Plugin', 'CustomAPIs', 'CustomApis', 'CustomApi', 'WebResources', 'Workflows', 'Tests', 'Common', 'Shared', 'Core')
    $trimmed = $value
    while (($trimmed -match '\.') -and ($layerSegments -contains ($trimmed -split '\.')[-1])) {
        $trimmed = ($trimmed -split '\.' | Select-Object -SkipLast 1) -join '.'
    }
    $alternatives = @($declaredNamespaces)
    if ($trimmed -ne $value) { $alternatives = @($value) + $alternatives }

    $namespaceProposal = New-Proposal -Value $trimmed -Source $(if ($trimmed -ne $value) {
        "Shared root namespace of the existing C# projects ($value), with the layer segment removed"
    } else {
        'Shared root namespace of the existing C# projects'
    }) -Confidence $confidence -Alternatives $alternatives
}

# ProjectName
$projectNameProposal = New-Proposal -Value $null -Source 'No evidence in the repository. Ask the user; never derive it from the folder name silently.' -Confidence 'none' -Alternatives @(
    [System.IO.Path]::GetFileName($Path)
)
$solutionFileName = @($dotnet.solutionFiles | Select-Object -First 1)
if ($namespaceProposal['value']) {
    $firstSegment = ($namespaceProposal['value'] -split '\.')[0]
    if ($firstSegment -match '^[A-Za-z][A-Za-z0-9]*$') {
        $projectNameProposal = New-Proposal -Value $firstSegment -Source 'First segment of the existing root namespace' -Confidence 'medium' -Alternatives @([System.IO.Path]::GetFileName($Path))
    }
}
elseif ($solutionFileName) {
    $candidate = [System.IO.Path]::GetFileNameWithoutExtension($solutionFileName)
    if ($candidate -match '^[A-Za-z][A-Za-z0-9]*$') {
        $projectNameProposal = New-Proposal -Value $candidate -Source "Name of $solutionFileName" -Confidence 'medium' -Alternatives @([System.IO.Path]::GetFileName($Path))
    }
}

# ProjectDescription
$descriptionProposal = New-Proposal -Value $null -Source 'Ask the user: one or two sentences on what the project delivers' -Confidence 'none'
$readme = @($files | Where-Object { $_ -match '(?i)^readme(\.md|\.txt)?$' } | Select-Object -First 1)
if ($readme) {
    try {
        $readmeLines = [System.IO.File]::ReadAllLines((Join-Path $Path $readme))
        $paragraph = @($readmeLines | Where-Object { $_.Trim() -and $_ -notmatch '^\s*#' -and $_ -notmatch '^\s*\[!\[' } | Select-Object -First 2)
        if ($paragraph) {
            $descriptionProposal = New-Proposal -Value (($paragraph -join ' ').Trim()) -Source "First paragraph of $readme" -Confidence 'medium'
        }
    }
    catch { }
}

$proposedValues = [ordered]@{
    ProjectName        = $projectNameProposal
    PublisherName      = $publisherNameProposal
    PublisherPrefix    = $publisherPrefixProposal
    SolutionName       = $solutionProposal
    RootNamespace      = $namespaceProposal
    ProjectDescription = $descriptionProposal
}

$missingValues = @($proposedValues.Keys | Where-Object { -not $proposedValues[$_]['value'] })

# ---- recommendation ------------------------------------------------------------------------

$deviating = @($assessments | Where-Object { $_.status -eq 'deviates' })

$recommendation = [ordered]@{
    mode                = if ($classification -eq 'greenfield') { 'initialise' } else { 'adopt' }
    scaffoldArguments   = @()
    askUserFor          = $missingValues
    deviationCount      = $deviating.Count
    blockers            = @()
}

if ($classification -eq 'greenfield') {
    if (@($present).Count -gt 0) {
        $recommendation['scaffoldArguments'] = @('-SkipExisting')
        $recommendation['blockers'] += "The folder is otherwise empty but already contains: $(@($present) -join ', '). Use -SkipExisting, or -Force to overwrite."
    }
}
else {
    $recommendation['scaffoldArguments'] = @('-SkipExisting')
    if (@($repository.layout.actual.solutionFolders).Count -gt 0 -or @($repository.layout.actual.pluginFolders).Count -gt 0) {
        $recommendation['scaffoldArguments'] += '-SkipLayout'
    }
    if ($repository.agentDocs.claudeMd) {
        $recommendation['blockers'] += 'CLAUDE.md already exists. The scaffold will skip it with -SkipExisting: merge the harness sections into the existing file by hand rather than overwriting instructions the project already relies on.'
    }
    if (@($repository.harness.presentFiles).Count -gt 0 -and @($repository.harness.missingFiles).Count -gt 0) {
        $recommendation['blockers'] += 'The harness is partially installed. Only the missing files will be written; compare the present ones against the templates before assuming they are current.'
    }
}

if ($environment['treatAsProduction'] -and $environment['connected']) {
    $recommendation['blockers'] += "The connected environment ($($environment.org.friendlyName)) does not look like a DEV environment (name signal: $($environment.nameSignal)). The standards permit write operations in DEV only: verify before running anything that writes."
}

# ---- output --------------------------------------------------------------------------------

$report = [ordered]@{
    schemaVersion  = 1
    generatedAt    = (Get-Date).ToString('o')
    pluginRoot     = $pluginRoot
    tooling        = $tooling
    repository     = $repository
    dotnet         = $dotnet
    node           = $node
    solutions      = $solutions
    pcfControls    = $pcfControls
    environment    = $environment
    standards      = [ordered]@{
        baselineFound = [bool]$baseline
        assessments   = $assessments
        deviations    = @($deviating | ForEach-Object { $_.id })
        staleBaseline = $staleBaseline
    }
    prefixEvidence = $prefixEvidence
    proposedValues = $proposedValues
    recommendation = $recommendation
    notes          = @($notes)
}

$report | ConvertTo-Json -Depth 12

}
finally {
    if (Test-Path -LiteralPath $script:scratchRoot) {
        Remove-Item -LiteralPath $script:scratchRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
