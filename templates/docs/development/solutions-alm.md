# Solutions & ALM Standards

Read `docs/agents/development-standards.md` first. This file only adds what is specific to solutions, environments and delivery.

## Environments

- The chain is DEV → TEST → PROD. There are no per-developer environments: DEV is shared, and every change lands where colleagues are working.
- Name the environment before any operation against it (`pac org who`). An environment you have not verified is production.
- Write operations are permitted in DEV only.
- Irreversible operations are prepared, not executed: deleting a table, column, relationship or record; changing the data type of a populated column; deleting or overwriting a solution. A human runs them.
- Before creating any component, verify the active solution and publisher. Components created without them land in the Common Data Services Default Solution, outside the ALM chain — a silent loss that only surfaces when the deployment is missing half the change.

## Solution strategy

- One unmanaged solution, `{{solution_name}}`, in DEV. Split only when a part genuinely needs to deploy on its own schedule: premature segmentation doubles the cost of every change and creates solution layering that is painful to unwind.
- TEST and PROD receive managed solutions only. No exceptions, no unmanaged import "just this once" — an unmanaged layer in a downstream environment cannot be cleanly removed.
- Never edit a component directly in TEST or PROD. Changes start in DEV and travel the chain.
- The publisher is `{{publisher_name}}`, prefix `{{publisher_prefix}}`, for every component.

## Configuration that varies by environment

- URLs, endpoints, keys, external identifiers and toggles are environment variables. Connections are connection references. Nothing else is acceptable.
- An environment variable ships with a default value only when that default is safe in every environment. Secrets never ship a default value.
- Secrets live in Azure Key Vault, referenced from an environment variable. Never in the solution.
- Every new environment variable and connection reference is documented with the change: name, purpose, and the value expected per environment.

## Source control

- The environment is the source of truth for declarative components. `src/Solutions/{{solution_name}}/` is its committed mirror, produced by `pac solution export` + `pac solution unpack`.
- **Before** starting declarative work, run `scripts/sync-solution.ps1 -SolutionName {{solution_name}} -Check`. If the mirror does not match, someone else has uncommitted work in the environment: stop and report it. Do not absorb it into your change.
- **After** finishing declarative work, run `scripts/sync-solution.ps1 -SolutionName {{solution_name}}` and commit the resulting diff together with the rest of the change. The mirror is never more than one task behind.
- Do not hand-edit the unpacked XML, except for translation labels, descriptions and ordering. Everything else is changed in the environment and re-exported.

## Deployment

- Today: manual, with `pac`. Export managed from DEV, import into the target, publish, verify.
- Planned: GitHub Actions running the same commands. Write scripts and standards so that automating them later is a move, not a rewrite.
- Never import an unmanaged solution into TEST or PROD.
- Never delete a managed solution to "clean things up": it deletes the data in its tables.
- Verify after every import: solution version, components present, and one real execution of the affected capability.

## Verification

- `pac solution check` reports no high-severity issues before the solution moves.
- The unpacked diff is committed and matches the environment.
- Any command that could not be run — missing authentication, missing permissions — is reported explicitly. Never assumed successful.
