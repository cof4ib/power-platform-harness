---
name: set-power-platform
description: "Initialise the current folder as a Power Platform / Dynamics 365 CE repository: agent instructions, development standards per technology, solution sync script and the folder layout. Run once, at the start of a project."
disable-model-invocation: true
allowed-tools: Bash(pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/scaffold.ps1" *)
---

# Set up a Power Platform repository

Scaffold this folder into a Power Platform / Dynamics 365 CE repository carrying the harness:

- `CLAUDE.md` pointing the agent at the standards
- `docs/agents/development-standards.md`: technology-agnostic rules, Definition of Done, standards index
- `docs/development/*.md`: one standards file per technology (JavaScript, C# plugins, PCF, Custom APIs, cloud flows, Dataverse schema, solutions & ALM)
- `scripts/sync-solution.ps1`: keeps the unpacked solution in sync with the environment
- `.gitignore`, and the `src/`, `tests/` and `docs/adr/` layout

The copy is deterministic: a bundled script writes the files. Your job is to collect the six project values, confirm the plan, run the script and report. Do not write or paraphrase the template content yourself.

## 1. Preflight

Run these checks and report what you found before asking anything:

- Is the folder already initialised? Look for `CLAUDE.md`, `docs/agents/development-standards.md`, `scripts/sync-solution.ps1`. If any exists, say so and stop unless the user explicitly asks to overwrite.
- Is this a git repository? `git rev-parse --is-inside-work-tree`
- Which PowerShell is available? Prefer `pwsh --version`; fall back to `powershell -Command $PSVersionTable.PSVersion`. The scaffold script and `sync-solution.ps1` both need one of them.
- Is `pac` installed? `pac help` (only affects step 5; absence is not a blocker).

## 2. Collect the six values

Ask for all six in a single plain-text message: a numbered list, one line per value, each with its rule. Then stop and wait for the reply.

**Do not use `AskUserQuestion` to collect them.** That tool takes at most 4 questions and requires 2 to 4 predefined options per question, so it cannot collect free text and a six-value round fails outright. Use it only for the closed choices in this skill: the go-ahead in step 3 and which platform steps to run in step 5.

**Never invent a value and never derive one silently from the folder name** — a wrong prefix cannot be undone later.

| Value | What it is | Rules |
| --- | --- | --- |
| `ProjectName` | Short project name. Lands in .NET namespaces and JavaScript form API objects | Starts with a letter, letters and digits only |
| `PublisherName` | Dataverse publisher **display** name | Free text |
| `PublisherPrefix` | Dataverse customization prefix, carried by every component | 2-8 lowercase alphanumeric, starts with a letter, not `mscrm`. **Permanent**: say this out loud before accepting it |
| `SolutionName` | **Unique** name of the unmanaged solution in DEV, not its display name | Letters, digits and underscores, no spaces |
| `RootNamespace` | Root .NET namespace | Valid .NET namespace, dots allowed |
| `ProjectDescription` | One or two sentences on what the project delivers. Becomes the Description section of `CLAUDE.md` | Free text |

If the user already supplied values as arguments to this skill, treat them as proposals: echo them back for confirmation rather than assuming.

If the publisher and solution already exist in Dataverse, take the real values from the environment (`pac solution list`, or the Dataverse MCP) instead of inventing new ones.

## 3. Dry run, then confirm

```bash
pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/scaffold.ps1" -ProjectName <name> -PublisherName "<publisher>" -PublisherPrefix <prefix> -SolutionName <solution> -RootNamespace <namespace> -ProjectDescription "<description>" -DryRun
```

Show the resulting file list and the resolved values, and get an explicit go-ahead. The script validates every value, so a rejected value surfaces here, before anything is written.

## 4. Scaffold

Re-run the same command without `-DryRun`. Add `-Force` only when the user has explicitly accepted overwriting the files listed in the preflight.

The script refuses to overwrite by default and fails if any `{{token}}` survives substitution. If it fails, report its output verbatim; do not hand-edit the generated files to work around it.

## 5. Platform steps

Offer these one at a time, and run only what the user accepts. Report the real output of each.

1. **Authenticate against DEV**: `pac auth create --environment <DEV environment url>`. Ask for the url as plain text and wait for it — `AskUserQuestion` cannot collect it, for the reason given in step 2. Never guess it.
2. **Name the environment**: `pac org who`. The standards treat any unverified environment as production, so this is worth running even when auth already existed.
3. **Initialise git**: `git init` plus a first commit of the scaffold, if the folder is not a repository yet.

## 6. Report

State what was created and what was verified. Then hand over the steps only a human can do, with the resolved values filled in:

1. Create the publisher `<PublisherName>` with prefix `<PublisherPrefix>` in DEV.
2. Create the unmanaged solution `<SolutionName>` under that publisher.
3. Take the first solution snapshot and commit it: `./scripts/sync-solution.ps1 -SolutionName <SolutionName>`.
4. Read `docs/agents/development-standards.md` before the first change.

Creating a publisher or a solution is irreversible, so never do it on the user's behalf, even when you have write access to the environment.
