# Power Platform Harness

A Claude Code plugin that installs the same development harness in every Power Platform /
Dynamics 365 CE repository, so the coding agent knows the rules: what to read before a change,
how to separate business logic from the platform, what evidence a declarative change needs, and
when a task is actually done.

It works on an empty folder and on a project that already exists. In an existing project it
reads the publisher, prefix, solution and stack out of the repository and the environment instead
of asking, writes only the files that are missing, and reports where the project's versions and
layout differ from the standards — it never retargets a framework, swaps a test runner or moves a
folder to make a project fit.

## Install

```
/plugin marketplace add cof4ib/power-platform-harness
/plugin install power-platform-harness
```

Then, in the folder you want to set up:

```
/power-platform-harness:set-power-platform
```

## What it creates

```
CLAUDE.md                                # points the agent at the standards
.gitignore                               # .NET, PCF, Dataverse and secrets hygiene
docs/
├── agents/development-standards.md      # cross-technology rules + Definition of Done
├── development/
│   ├── javascript.md                    # web resources
│   ├── csharp-plugins.md                # Dataverse plugins
│   ├── pcf.md                           # PCF controls
│   ├── custom-apis.md                   # Custom API contracts
│   ├── power-automate.md                # cloud flows
│   ├── dataverse-schema.md              # tables, columns, relationships
│   └── solutions-alm.md                 # solutions, environments, delivery
└── adr/                                 # architecture decision records
scripts/sync-solution.ps1                # export + unpack the solution, or check for drift
src/{Plugins,CustomAPIs,WebResources,Solutions/<SolutionName>}/
tests/{Plugins,CustomAPIs}/
```

## How it decides what to do

The skill runs `scripts/discover.ps1` before it asks anything. That script reads — never writes —
and answers:

- which tools are installed (`pwsh`, `pac`, `git`, `dotnet`, `node`, `gh`);
- whether the folder is empty or an existing project, and whether the harness is already there;
- which publisher, prefix, solution and root namespace the project already uses, taken from a
  committed `Solution.xml`, from the C# projects, or from a solution exported on request;
- which environment the active `pac` profile points at, whether its name looks like DEV, and which
  unmanaged solutions already exist in it;
- where the project's real stack differs from what the standards assert.

Everything downstream follows from that: an empty folder gets the full scaffold, an existing
project gets only what it is missing.

### Existing projects

Six values, derived rather than asked. In a repository with a committed solution, discovery reads
the publisher display name, the customization prefix and the solution unique name straight out of
`Other/Solution.xml`, and the root namespace out of the `.csproj` files — so the usual number of
questions is zero.

Then it compares the project against `scripts/standards-baseline.json`, which records every
version, framework and layout decision the shipped standards assert, and reports the differences:

```
plugins.targetFramework     deviates   standard net462        project net472
plugins.strongNaming        deviates   standard unsigned      project strong-named
plugins.test.xunit          deviates   standard xunit 2.9.3   project 2.4.2
pcf.platformLibrary.react   deviates   standard 16.14.0       project 18.2.0
javascript.lint             deviates   standard eslint 9 flat project eslint 8 (.eslintrc)
alm.solutionMirrorPath      deviates   standard src/Solutions/<name>   project Solutions/AcmeCore
```

The project's answer is the one that stands. You choose whether to reconcile the generated
standards docs with it, or to keep the target versions and treat the list as a migration backlog.
Nothing in the repository is retargeted either way.

## The six values

The skill resolves six values across every generated file, so the result carries no placeholders:

| Value | What it is | Example |
| --- | --- | --- |
| `ProjectName` | Short project name, used in .NET namespaces and JavaScript form API objects | `Northwind` |
| `PublisherName` | Dataverse publisher display name | `Northwind Consulting` |
| `PublisherPrefix` | Dataverse customization prefix, carried by every component | `nwc` |
| `SolutionName` | Unique name of the unmanaged solution in DEV | `NorthwindCore` |
| `RootNamespace` | Root .NET namespace | `Northwind` |
| `ProjectDescription` | What the project delivers; becomes the Description section of `CLAUDE.md` | `Customer Service implementation for Northwind.` |

The skill offers to authenticate against DEV (`pac auth create`), name the environment
(`pac org who`), initialise git and commit the harness on a branch. Creating the publisher and the
solution is irreversible, so it leaves those to you as an explicit checklist.

## Requirements

- **PowerShell** — `pwsh` (7+) or Windows PowerShell 5.1. Both the scaffold and the generated
  `sync-solution.ps1` need one of them.
- **[Power Platform CLI](https://learn.microsoft.com/power-platform/developer/cli/introduction)
  (`pac`)** — only for the environment steps and for `sync-solution.ps1`.

## Run the scripts without Claude Code

The skill is a thin wrapper over two deterministic scripts, both usable on their own.

**Discovery** prints a JSON report and changes nothing:

```powershell
pwsh -NoProfile -File ./scripts/discover.ps1 -Path C:\repos\acme

# Repository only: no pac calls, no network.
pwsh -NoProfile -File ./scripts/discover.ps1 -SkipEnvironment

# Read the real publisher and prefix out of a solution that exists in the environment but has
# never been unpacked into the repository.
pwsh -NoProfile -File ./scripts/discover.ps1 -ResolvePublisherFromSolution AcmeCore
```

**Scaffolding** writes:

```powershell
pwsh -NoProfile -File ./scripts/scaffold.ps1 `
    -ProjectName Northwind `
    -PublisherName 'Northwind Consulting' `
    -PublisherPrefix nwc `
    -SolutionName NorthwindCore `
    -RootNamespace Northwind `
    -ProjectDescription 'Customer Service implementation for Northwind.' `
    -TargetPath C:\repos\northwind `
    -DryRun
```

It validates every value before writing and fails if any token survives substitution. Three ways
to handle a folder that is not empty:

| Flag | Behaviour |
| --- | --- |
| *(none)* | Abort and list the collisions. Nothing is written |
| `-SkipExisting` | Write what is missing, leave every existing file untouched. Idempotent |
| `-Force` | Overwrite. Rejected together with `-SkipExisting` |

`-SkipLayout` suppresses the `src/`, `tests/` and `docs/adr/` folders, for a project that already
has its own layout. `-Json` emits a parseable summary of what was created, skipped and overwritten.

## Contributing

`templates/` is the content shipped to every project: see `CLAUDE.md` for the rules on changing
it. A version or framework stated in `templates/docs/development/*.md` is also recorded in
`scripts/standards-baseline.json`; the two change together, and discovery reports the baseline as
stale if they drift apart.

## License

MIT
