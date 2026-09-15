# Power Platform Harness

A Claude Code plugin that initialises a Power Platform / Dynamics 365 CE repository so every
project starts from the same development standards.

Install it once, run one skill in an empty folder, and you get a repository where the coding
agent already knows the rules: what to read before a change, how to separate business logic from
the platform, what evidence a declarative change needs, and when a task is actually done.

## Install

```
/plugin marketplace add cof4ib/power-platform-harness
/plugin install power-platform-harness
```

Then, in the folder you want to initialise:

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

The skill asks for six project values and resolves them across every generated file, so the
result carries no placeholders:

| Value | What it is | Example |
| --- | --- | --- |
| `ProjectName` | Short project name, used in .NET namespaces and JavaScript form API objects | `Northwind` |
| `PublisherName` | Dataverse publisher display name | `Northwind Consulting` |
| `PublisherPrefix` | Dataverse customization prefix, carried by every component | `nwc` |
| `SolutionName` | Unique name of the unmanaged solution in DEV | `NorthwindCore` |
| `RootNamespace` | Root .NET namespace | `Northwind` |
| `ProjectDescription` | What the project delivers; becomes the Description section of `CLAUDE.md` | `Customer Service implementation for Northwind.` |

After scaffolding, the skill offers to authenticate against DEV (`pac auth create`), name the
environment (`pac org who`) and initialise git. Creating the publisher and the solution is
irreversible, so it leaves those to you as an explicit checklist.

## Requirements

- **PowerShell** — `pwsh` (7+) or Windows PowerShell 5.1. Both the scaffold and the generated
  `sync-solution.ps1` need one of them.
- **[Power Platform CLI](https://learn.microsoft.com/power-platform/developer/cli/introduction)
  (`pac`)** — only for the environment steps and for `sync-solution.ps1`.

## Run the scaffold without Claude Code

The skill is a thin wrapper over a deterministic script, which you can run on its own:

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

It validates every value before writing, refuses to overwrite existing files unless `-Force` is
supplied, and fails if any token survives substitution.

## Contributing

`templates/` is the content shipped to every project: see `CLAUDE.md` for the rules on changing
it.

## License

MIT
