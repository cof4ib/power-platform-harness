# Power Automate Cloud Flow Standards

Read `docs/agents/development-standards.md` first. This file only adds what is specific to cloud flows.

## When a flow is the right tool

- A rule that must **reject an operation** or preserve **transactional consistency** CANNOT be a cloud flow. Flows run after the commit: they cannot prevent anything, and by the time they detect the problem the invalid data is already saved. That requirement is a plugin.
- Cloud flow: asynchronous work, integration with external services and connectors, notifications, approvals, waits, scheduled work, temporal orchestration.
- Plugin: synchronous validation, integrity, transactional logic, anything the platform must guarantee before the record is written.
- JavaScript or PCF: interface behaviour and immediate user feedback.
- Where both would genuinely work, prefer the one whose failure mode is cheaper to live with.

## Stack & packaging

- Every flow is solution-aware and lives in `{{solution_name}}`, plus the feature solution of the branch that created it. A flow created outside a solution is not deliverable — recreate it inside.
- Connections are referenced through connection references, never bound to a personal account.
- Anything that varies between DEV, TEST and PROD is an environment variable: URLs, endpoints, keys, external identifiers, toggles. No literal URL, GUID, key or endpoint inside a flow.
- Flows are deployed only as part of the solution. Never edit a flow directly in TEST or PROD.

## Naming & structure

- Flow name: `<Table or Domain> - <Capability> (<Trigger type>)`, e.g. `Work Order - Notify Technician On Assignment (Dataverse)`.
- Rename every action to its intent. Default names — `Compose 2`, `Condition 3`, `Get items 4` — are not acceptable: they make the flow unreadable in run history, in the unpacked JSON and in review.
- Do not nest expressions more than two levels inline. Extract to a named `Compose` and reference it.
- Child flows only when at least two parent flows genuinely reuse them. A child flow costs a connection reference, a context boundary and an extra hop in run history; do not pay that for one caller.
- One flow, one capability. A flow that branches into three unrelated outcomes is three flows.

## Triggers

- Filter at the trigger, never with a first `Condition` that terminates the run. A terminated run has still consumed a run and still counts towards throttling.
- Dataverse triggers MUST declare filtering columns, and only the columns that actually drive the rule.
- Prevent self-triggering with a trigger condition whenever the flow writes to the table that triggers it. Execution depth is not observable inside a flow: the guard has to live in the trigger.
- Set the trigger scope (`Organization`, `Business Unit`, `User`) deliberately. Do not leave the default because it happened to work in DEV.
- Configure concurrency explicitly when order matters; the default is parallel.

## Error handling

- Flows that write data or call an external service MUST use the scope pattern: `Try` / `Catch` (run after: has failed, has timed out, is skipped) / `Finally`. Read-only notification flows do not need the ceremony.
- A flow NEVER ends in `Succeeded` when an action failed. `Catch` ends with `Terminate` in status `Failed`, and a message naming the operation, the record and the underlying error. A run history that reports green for a failed run is worse than no logging at all.
- Never leave a partial write. If step 3 of 4 fails, `Catch` either compensates or fails loudly; silently half-applied data is the worst outcome available.
- Configure the retry policy deliberately on external calls. The default exponential retry is wrong for non-idempotent operations.
- Never use `Terminate` with status `Succeeded` to exit a failure path.

## Performance & limits

- Select only the columns you need (`Select columns`) and filter server-side (`Filter rows`). Never retrieve and then filter inside the flow.
- Never call an action inside `Apply to each` when one filtered query answers the same question.
- Set a row limit on list actions, and enable pagination explicitly when volume requires it. Do not rely on the default cap.
- Prefer the trigger payload over re-reading the record that triggered the flow.
- Long-running work belongs in an asynchronous branch or a queue, not in a chain a user is waiting on.

## Verification

- A flow with no executed run is a drawing. Before the change is done: at least one real run in DEV per path — the success path and the failure path — with the run id recorded in the issue.
- The flow is turned on, and the run history shows the expected outcome, not merely a green tick.
- The unpacked solution diff for the flow is committed with the change (`scripts/sync-solution.ps1`).
- `pac solution check` reports no high-severity issues. If it could not be run, say so explicitly.
