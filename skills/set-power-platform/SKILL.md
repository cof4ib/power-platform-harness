---
name: set-power-platform
description: "Install the Power Platform / Dynamics 365 CE harness in this folder: agent instructions, development standards per technology, solution sync script and folder layout. Works on an empty folder and on an existing project, where it reads the publisher, prefix, solution and stack from the repository and the environment instead of asking, and reports where the project's versions differ from the standards."
disable-model-invocation: true
allowed-tools: Bash(pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/discover.ps1" *), Bash(pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/scaffold.ps1" *), Bash(pac auth create *), Bash(pac auth list*), Bash(pac org who*), Bash(pac solution list*), Bash(git init*), Bash(git status*), Bash(git add *), Bash(git commit *), Bash(git diff*), Read, Write, Edit, Glob, Grep, AskUserQuestion
---

# Install the Power Platform harness

Two jobs, decided by what is already in the folder:

- **Empty folder** — scaffold the full harness: `CLAUDE.md`, `docs/agents/development-standards.md`, `docs/development/*.md`, `scripts/sync-solution.ps1`, `.gitignore`, and the `src/`, `tests/`, `docs/adr/` layout.
- **Existing project** — adopt the harness into it: add only what is missing, keep what the project already has, and reconcile the standards with the stack the project actually uses. Never set a version, framework or layout the project does not use.

Two bundled scripts do the work. `discover.ps1` reads; `scaffold.ps1` writes. Do not write or paraphrase template content yourself, and do not hand-craft files the scaffold produces.

## Asking the user: hard constraint

`AskUserQuestion` takes at most 4 questions, and each needs 2 to 4 concrete predefined options. It cannot collect free text, a name, a prefix or a url. Calling it for those fails with `Invalid tool parameters` — that is what happens when this rule is ignored, twice in one session.

- **Free-text values** (project name, publisher, prefix, solution, namespace, description, environment url): ask in a plain assistant message as a numbered list, then stop and wait.
- **`AskUserQuestion` is for closed choices only**, and this skill has exactly three: the single go-ahead in step 4, how to resolve deviations in step 3, and which platform steps to run in step 6.

Never invent a value. Never derive one silently from the folder name. A wrong publisher prefix cannot be undone once components exist.

## 1. Discover

One command, before any question:

```bash
pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/discover.ps1" -Path .
```

Add `-SkipEnvironment` only when the user says the environment is irrelevant or unreachable. It reads the repository and, through `pac`, the connected environment; it writes nothing, in the repo or in Dataverse. Everything downstream comes from its JSON.

Report, in a few lines: the tooling that is missing, `repository.classification`, the connected environment and its `nameSignal`, the values it derived with their source, and how many deviations it found. Then follow `recommendation.mode`:

| `recommendation.mode` | Go to |
| --- | --- |
| `initialise` | step 2 |
| `adopt` | step 3 |

If `tooling.pwsh.present` is false and this shell is Windows PowerShell 5.1, say so and continue: both scripts run, but `pac` and PCF tooling expect pwsh 7. If `standards.staleBaseline` is not empty, report it as a bug in this plugin, not in the user's project.

## 2. New project: take the values from the environment first

The environment, not the user, is the cheapest source of truth for what already exists.

1. **Not connected** (`environment.connected` is false): offer to authenticate. Ask for the DEV environment url as plain text, wait, then run `pac auth create --environment <url>` and re-run `discover.ps1`. If the user declines, continue and collect every value by hand.
2. **Connected**: report `environment.org.friendlyName`. If `environment.nameSignal` is not `dev`, say that the standards permit write operations in DEV only and that this environment does not look like one — ask before anything that writes.
3. **Check the solution name against `environment.solutions` before proposing it.** A name that already exists in the environment means the solution is not new: either reuse it — re-run discovery with `-ResolvePublisherFromSolution <name>` to read its real publisher and prefix instead of inventing them — or pick a different name. A name flagged `possiblyTruncated` was cut by `pac solution list` at 48 characters: confirm it against the environment before using it.
4. Ask, in one plain-text message, only for what `recommendation.askUserFor` lists. For a new project that is normally all six, and `pac` cannot report a publisher prefix for an environment, so the prefix always comes from the user:

| Value | What it is | Rules |
| --- | --- | --- |
| `ProjectName` | Short project name. Lands in .NET namespaces and JavaScript form API objects | Starts with a letter, letters and digits only |
| `PublisherName` | Dataverse publisher **display** name | Free text |
| `PublisherPrefix` | Dataverse customization prefix, carried by every component | 2-8 lowercase alphanumeric, starts with a letter, not `mscrm`. **Permanent**: say this out loud before accepting it |
| `SolutionName` | **Unique** name of the unmanaged solution in DEV, not its display name | Letters, digits and underscores, no spaces |
| `RootNamespace` | Root .NET namespace | Valid .NET namespace, dots allowed |
| `ProjectDescription` | One or two sentences on what the project delivers. Becomes the Description section of `CLAUDE.md` | Free text |

Values the user passed as arguments to this skill are proposals: echo them back for confirmation. Then go to step 4.

## 3. Existing project: adapt to it, do not overwrite it

`proposedValues` already carries what the repository knows. Each entry has a `source` and a `confidence`:

- `high` — read out of a committed `Solution.xml` or an exported solution. State the source and move on.
- `medium` — inferred (a shared root namespace, a prefix seen in file names, a README paragraph). Show the evidence and let the user correct it.
- `none` — ask, as plain text, exactly as in step 2.

Show all six as a table with value, source and confidence. If `PublisherPrefix` is `none` but the environment is connected and a solution exists, offer `discover.ps1 -ResolvePublisherFromSolution <name>` rather than asking the user to remember it.

### Reconcile the standards with the real stack

`standards.assessments` compares every version, framework and layout decision the shipped standards assert against what the repository uses. Report every entry whose `status` is `deviates` as a table: topic, what the standard says, what the project does, and the evidence. Ignore `not-applicable`; report `unknown` as a question for the user.

These differences are not defects in the project. The harness must not retarget a framework, change a test runner, upgrade a platform library or move a folder. Ask with `AskUserQuestion` (one question, three options):

1. **Adjust the standards to the project** (recommended) — after scaffolding, edit the generated `docs/development/*.md` in this repository so each stated version matches reality. Only the lines listed in the deviation table, one by one, shown before applying. Never touch the plugin's own `templates/`.
2. **Install as-is and list the gaps** — leave the standards stating the target versions, and report the differences as a migration backlog the team decides on later.
3. **Decide item by item** — walk the table together.

### Layout and the solution mirror

When `layout.folders` or `alm.solutionMirrorPath` deviates, pass `-SkipLayout`: creating `src/Plugins/` next to an existing `source/plugins/` leaves two conventions in one repository. Say which one the project uses.

`scripts/sync-solution.ps1` resolves the export path as `src/Solutions/<SolutionName>`. If the repository unpacks its solution elsewhere, the script will export into the wrong place — tell the user, and either adjust that one path in the generated copy or do not install the script.

## 4. Confirm once, then write

Run the dry run first and read its output yourself; do not make the user confirm twice:

```bash
pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/scaffold.ps1" -ProjectName <name> -PublisherName "<publisher>" -PublisherPrefix <prefix> -SolutionName <solution> -RootNamespace <namespace> -ProjectDescription "<description>" -Json -DryRun <flags>
```

`<flags>` is exactly what `recommendation.scaffoldArguments` lists — empty for a new project. `-Json` keeps the output parseable. The script validates every value, so a bad prefix or solution name surfaces here, before anything is written.

Then ask for the go-ahead **once**, with `AskUserQuestion`: the resolved values, the file count, and — for an existing project — which files will be skipped. On approval, re-run the same command without `-DryRun`.

Flag rules:

- `-SkipExisting` — existing project, or a folder that already holds some harness files. Writes what is missing, reports what it left alone.
- `-SkipLayout` — the project already has its own layout.
- `-Force` — only when the user has explicitly accepted overwriting the exact files listed. Never combined with `-SkipExisting`; the script rejects that.

If the script fails, report its output verbatim. Do not hand-edit generated files to work around it.

### When `CLAUDE.md` was skipped

`-SkipExisting` keeps the project's `CLAUDE.md`, which means nothing yet points the agent at `docs/agents/development-standards.md` and the whole harness is unreachable. Fix it without paraphrasing: render the templates into a throwaway folder, read the rendered `CLAUDE.md`, and merge its sections into the existing one.

```bash
pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/scaffold.ps1" -ProjectName <name> -PublisherName "<publisher>" -PublisherPrefix <prefix> -SolutionName <solution> -RootNamespace <namespace> -ProjectDescription "<description>" -TargetPath <temp folder> -SkipLayout
```

Keep the project's own content. Add the harness sections it lacks, starting with the mandatory-reading pointer to `docs/agents/development-standards.md`. Show the user the diff. If the existing `CLAUDE.md` contradicts a harness rule, report the conflict instead of resolving it silently.

## 5. Apply the agreed reconciliation

Only if the user chose option 1 or 3 in step 3. For each deviation, edit the stated version or framework in the generated `docs/development/*.md` so it matches the repository, and nothing else. List every edit. The `guidance` field of each assessment says why the project's choice is usually the one to keep.

## 6. Platform steps

Offer only what discovery showed is still needed, run only what the user accepts, and report the real output.

1. **Authenticate against DEV** — skip if `environment.connected` is already true. `pac auth create --environment <url>`; ask for the url as plain text. It opens a browser and waits for the user to sign in, so say so before running it and do not treat a slow return as a failure.
2. **Name the environment** — `pac org who`. Worth running even when auth already existed: the standards treat an unverified environment as production.
3. **Initialise git** — only if `repository.git.isRepository` is false: `git init`, then a first commit of the scaffold.
4. **Commit the harness** — if the repository already existed, the harness files are uncommitted. Offer a commit on a branch (`chore/adopt-power-platform-harness`), never on a shared branch without asking.

Creating a publisher or a solution is irreversible. Never do it on the user's behalf, even with write access.

## 7. Report

State what was created, what was skipped, what was verified, and what you could not run and why.

Then the steps only a human can take, with the values filled in:

1. Create the publisher `<PublisherName>` with prefix `<PublisherPrefix>` in DEV — **only if it does not exist yet**; discovery says whether the solution was already there.
2. Create the unmanaged solution `<SolutionName>` under that publisher, same condition.
3. Take the first solution snapshot and commit it: `./scripts/sync-solution.ps1 -SolutionName <SolutionName>`. For an existing project, run it with `-Check` first: a difference means the environment holds declarative work nobody has committed.
4. Read `docs/agents/development-standards.md` before the first change.
5. For an existing project: the deviations left unreconciled, as a list the team can act on.
