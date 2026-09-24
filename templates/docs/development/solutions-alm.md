# Solutions & ALM Standards

Read `docs/agents/development-standards.md` first. This file only adds what is specific to solutions, environments and delivery.

## Environments

- The chain starts at DEV. There are no per-developer environments: DEV is shared, and every change lands where colleagues are working.
- Name the environment before any operation against it (`pac org who`). An environment you have not verified is production.
- Write operations are permitted in DEV only.
- Irreversible operations are prepared, not executed: deleting a table, column, relationship or record; changing the data type of a populated column; deleting or overwriting a solution. A human runs them.
- Before creating any component, verify the active solution and publisher. Components created without them land in the Common Data Services Default Solution, outside the ALM chain — a silent loss that only surfaces when the deployment is missing half the change.

## Solution strategy

- Two kinds of solution, and only two. `{{solution_name}}` is the **core** solution: it owns every component and is the source of truth. A **feature solution** is a per-branch container that references the components one piece of work touches. It never owns a component and never holds a definition of its own.
- Every unit of work — feature, fix or chore — gets its own branch and its own feature solution. Work that does not touch Dataverse components needs the branch only.
- Both are unmanaged in DEV. Downstream environments follow the promotion topology below.
- Never edit a component directly in a downstream environment. Changes start in DEV and travel the chain.
- The publisher is `{{publisher_name}}`, prefix `{{publisher_prefix}}`, for every component and every solution.
- Solution unique names carry no publisher prefix: the core solution is `{{solution_name}}`, a feature solution is named from its branch.

## Starting a unit of work

Before writing any code or touching any component, settle where the work lives. Ask the user, and wait:

> Do you want to develop this on the current branch `<branch>`, or on a new one?

- **Current branch** — continue. If that branch already has a feature solution, components go into it. If the current branch is the trunk, say so: trunk work has no feature solution, so the change would land in the core solution alone and lose its isolation.
- **New branch** — derive the names, create the branch and the worktree, then create the feature solution. Never skip the question because the intent seems obvious.

### Names

Derive both names from one answer, so the branch and the solution can never drift apart:

| Thing | Rule | Example |
| --- | --- | --- |
| Branch | `<type>/<short-description>`, type is `feature`, `fix` or `chore` | `feature/lead-scoring-widget` |
| Feature solution | `<type>_<ShortDescriptionInPascalCase>` | `feature_LeadScoringWidget` |
| Worktree | `../<repo>.worktrees/<branch>` | `../contoso.worktrees/feature/lead-scoring-widget` |

Propose the branch name from what the user asked for and confirm it before creating anything: the solution unique name follows it and cannot be renamed afterwards.

### Create the branch and its worktree

```bash
git worktree add -b <type>/<short-description> ../<repo>.worktrees/<type>/<short-description>
```

A worktree, not a checkout: another session may be working in this directory, and switching its branch underneath them loses work. Continue the task inside the new worktree.

### Create the feature solution

`pac` has no command that creates a solution in Dataverse — `pac solution init` only scaffolds a local project. The sequence below is the whole creation path; run it in a throwaway folder, never inside the repository.

```bash
pac solution init --publisher-name <publisher-unique-name> --publisher-prefix {{publisher_prefix}} --outputDirectory <temp>/<type>_<Name>
pac solution pack --folder <temp>/<type>_<Name>/src --zipfile <temp>/<type>_<Name>.zip --packagetype Unmanaged
pac solution import --path <temp>/<type>_<Name>.zip --publish-changes
```

- `--publisher-name` takes the publisher's **unique** name, not its display name. Read it from the core solution before running this; a wrong value tries to create a second publisher and the import fails on the duplicate prefix.
- Creating a solution is irreversible enough to be a human decision. Show the commands and the resolved names, ask, and only then run them. Never as a side effect of another task.
- Report the created solution and verify it with `pac solution list`.

## Components belong to two solutions

A component created or modified on a branch belongs to the core solution — which owns it — and to that branch's feature solution, which records that this work touched it. One without the other is a defect:

- missing from the core solution: the component is outside the ALM chain;
- missing from the feature solution: the feature cannot be promoted on its own, and the branch no longer describes its own footprint.

Create the component in the core solution as usual, then add it to the feature solution:

```bash
pac solution add-solution-component --solutionUniqueName <type>_<Name> --component <schema-name-or-id> --componentType <n> --AddRequiredComponents
```

- `--component` accepts a schema name as well as an id. Prefer the schema name: it is the value already in the diff.
- `--componentType` is a number. The common ones in this stack: entity `1`, attribute `2`, global choice `9`, saved query `26`, workflow and cloud flow `29`, form `60`, web resource `61`, model-driven app `80`, plug-in assembly `91`, plug-in step `92`, canvas app `300`, connection reference `371`, environment variable definition `380`, environment variable value `381`. Anything not on that list is looked up in the [SolutionComponent reference](https://learn.microsoft.com/en-us/power-apps/developer/data-platform/reference/entities/solutioncomponent), never guessed — Microsoft's own documentation notes that newer component types are absent from the classic `componenttype` list.
- Adding a component to a solution is additive and reversible; it does not need the same confirmation the creation of the solution does.
- Do this as each component is created, not as a sweep at the end. A component added to the core solution and forgotten here is invisible until the promotion fails.

## Configuration that varies by environment

- URLs, endpoints, keys, external identifiers and toggles are environment variables. Connections are connection references. Nothing else is acceptable.
- An environment variable ships with a default value only when that default is safe in every environment. Secrets never ship a default value.
- Secrets live in Azure Key Vault, referenced from an environment variable. Never in the solution.
- Every new environment variable and connection reference is documented with the change: name, purpose, and the value expected per environment.

## Source control

- The environment is the source of truth for declarative components. `src/Solutions/{{solution_name}}/` is its committed mirror, produced by `pac solution export` + `pac solution unpack`.
- Only the core solution is mirrored into the repository. A feature solution holds references, not definitions: mirroring it would commit the same components twice under two paths.
- **Before** starting declarative work, run `scripts/sync-solution.ps1 -SolutionName {{solution_name}} -Check`. If the mirror does not match, someone else has uncommitted work in the environment: stop and report it. Do not absorb it into your change.
- **After** finishing declarative work, run `scripts/sync-solution.ps1 -SolutionName {{solution_name}}` and commit the resulting diff together with the rest of the change. The mirror is never more than one task behind.
- Do not hand-edit the unpacked XML, except for translation labels, descriptions and ordering. Everything else is changed in the environment and re-exported.

## Promotion

Which artifact leaves DEV is a decision of the project, not of the individual change. It follows from what the environment after DEV does:

- **The next environment is unmanaged, or is a BUILD environment** — feature solutions are deployed individually into it, and the core solution is assembled there and exported managed for the environments beyond it.
- **The next environment is TEST with managed solutions** — the core solution travels whole from DEV, managed. Feature solutions stay in DEV.

Record which of the two this project uses; until it is recorded, do not promote anything on assumption.

- Today: manual, with `pac`. Automated pipelines are planned and will carry the export and import steps. Write scripts and standards so that automating them later is a move, not a rewrite.
- Never import an unmanaged solution into a managed environment.
- Never delete a managed solution to "clean things up": it deletes the data in its tables.
- Verify after every import: solution version, components present, and one real execution of the affected capability.

## After the merge

- The feature solution stays in DEV. It is the record of what that branch touched, and it may still be the unit of deployment somewhere downstream. Nothing deletes it automatically.
- The branch and its worktree are removed once merged: `git worktree remove <path>`, then delete the branch.

## Verification

- `pac solution check` reports no high-severity issues before the solution moves.
- The unpacked diff of the core solution is committed and matches the environment.
- Every component the change touched is in the feature solution. Verify it against the environment, not from memory.
- Any command that could not be run — missing authentication, missing permissions — is reported explicitly. Never assumed successful.
