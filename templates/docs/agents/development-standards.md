# Development Standards

Rules that apply to every change in this repository, whatever the technology.

## How to use this file

- Read this file before any change. Then read the standards file for each technology the change touches — only those, not all of them.
- A technology file may make a rule here more specific. It MUST NOT contradict it. On a genuine conflict, this file wins and the conflict is reported.
- If the change touches a technology with no standards file, apply this file alone and state that gap explicitly in the final report.
- Project identity: project `{{project_name}}`, publisher `{{publisher_name}}` with customization prefix `{{publisher_prefix}}`, unmanaged solution `{{solution_name}}` in DEV, root .NET namespace `{{root_namespace}}`. The prefix is permanent and cannot be changed once components exist. When a task needs a value not recorded here — an environment url, a connection reference, an environment variable — stop and ask. Never invent one.

## Design principles

- Prefer the simplest solution that satisfies the requirement. Avoid over-engineering.
- Do not introduce abstractions until there is a demonstrated need. Two call sites are not a need; three divergent ones might be.
- Change only what the task requires. No opportunistic refactors, renames, formatting sweeps or dependency bumps riding along with a functional change: they hide the real diff from the reviewer.
- Never introduce a new technology, framework, library, architectural pattern, testing framework or project convention when an equivalent project standard already exists.
- When nothing here decides it: check the existing codebase, then this repository's docs and skills, then relevant MCPs and official Microsoft documentation. Prefer the established project pattern over a generic best practice.
- Record a decision in `docs/adr/` before implementing it whenever it affects architecture or project-wide conventions — including one resolved through the fallback above.

## Business logic separation

- Express a business rule independently of the platform whenever the rule can be stated without it.
- Pure business rules take and return plain values, are deterministic and side-effect free. Pass non-deterministic inputs (current time, GUIDs, random values, current user) as parameters.
- Platform APIs, context objects and I/O belong in the integration layer, never inside the rule.
- Do not force this separation onto logic that is already simple.

## Error handling

- Never swallow a failure. Silent success after an error is the most expensive defect class in this stack: it produces inconsistent data that nobody is alerted to.
- Expected business or validation failures produce a user-safe message: no stack traces, no internal identifiers, no implementation details.
- Unexpected failures propagate. Do not convert them into a success result or a default value.
- Validate as early as the platform allows, and fail before writing anything.
- Never leave a record, form or process in a half-applied state after a failure.

## Data, secrets & traceability

- Never hardcode connection strings, API keys, secrets, credentials, URLs, endpoints or environment GUIDs in code, configuration, flows, tests or fixtures. Use environment variables and connection references.
- Never commit or log personally identifiable information or other regulated data (GDPR, HIPAA, PCI-DSS, etc.). Test fixtures use synthetic or anonymised data.
- If a task appears to require handling a regulated data category, flag it to the developer instead of proceeding silently.
- Emit enough diagnostic detail to reconstruct what happened: the operation, the record identifier, the outcome. Never the contents of sensitive fields.
- Remove temporary debugging output before the change is done.

## Performance & platform limits

- Never block the user interface. Work that is not needed to render happens after first render, or outside the request entirely.
- Retrieve only the columns and rows the operation needs. No unbounded queries; page explicitly.
- Prefer data already available in context (form values, trigger payload, registered images, framework context) over retrieving the same data again.
- Never query inside a loop when a single filtered query answers the same question.
- Respect platform limits by design: sandbox timeouts, API request limits, throttling, message size. A change that only works below production volume is not done.

## Naming & language

- Identifiers, comments, commit messages and documentation are written in English.
- End-user visible text is never a literal in code, flows or scripts. It comes from Dataverse labels, translations or localised resources.
- The Dataverse base language is English; other languages ship as translations.

## Testing

- Production code and the tests it requires are created or updated in the same change.
- Tests execute the production artifact. They never duplicate, reimplement or paraphrase the logic under test.
- Test observable behaviour through the public surface, not implementation details.
- Cover expected behaviour, the relevant edge cases, and the failure paths.
- Tests are independent of execution order and of state left behind by another test.
- A change is incomplete while a required test is missing or failing.
- Some artifacts cannot be unit tested — flows, schema, security, solution configuration. They are not exempt from proof: see Verification & reporting.

## Verification & reporting

- Never claim a result you have not observed. "Done", "works", "passes" and "deployed" require an executed command, a tool response or a real run.
- Never simulate metadata, tables, columns, relationships, solution components or environment state when a tool can retrieve it. Use the Dataverse MCP or `pac`.
- Name the environment before any operation against it (`pac org who`). Treat any environment you have not verified as production.
- Write operations are permitted in DEV only. Irreversible operations — deleting a table, column, relationship or record, or changing the data type of a populated column — are prepared by the agent and executed by a human.
- Report what you could not run, and why, alongside what you did run. A failing test is reported with its output, never summarised as an obstacle.
- Evidence required for changes that have no automated tests:
  - Any declarative change: the unpacked solution diff committed with the change, and `pac solution check` with no high-severity issues.
  - Cloud flows: at least one real run in DEV per path — success and failure — with the run id recorded in the issue.
  - Schema: the resulting metadata read back from the environment, never asserted from memory.

## Definition of Done

Compiling is not done. A task is complete only when all of the following hold:

- The implementation matches the spec and every applicable standards file.
- Tests were written first and pass; affected projects build with no errors and no new warnings; linting and static analysis are clean.
- The diff was reviewed against spec and standards — `/implement` drives this via `/tdd` and `/code-review`; outside that flow, do the equivalent by hand.
- No secrets, credentials or regulated data are hardcoded, logged or committed.
- Any new public contract is documented: a form API, a Custom API request/response, a plugin step, an environment variable.
- For declarative changes: the evidence listed under Verification & reporting exists, and `src/Solutions/{{solution_name}}/` is in sync with the environment.

## Git

- Commit only once the change satisfies the Definition of Done above — never leave a commit as the final state of a task in a broken or partially-implemented condition.
- Commit messages describe the change and its motivation, not just the action (`fix`, `update` alone are not enough).
- Prefer `gh` for PR creation, review and inspection over the web UI.
- Branch naming: `<type>/<short-description>` (e.g. `fix/`, `feature/`, `chore/`).

## Standards index

Read the file for each technology the change touches, before writing.

| Technology | File | Status |
| --- | --- | --- |
| JavaScript web resources | `docs/development/javascript.md` | Ready |
| WebResources build project | `docs/development/webresources-project.md` | Ready |
| C# Dataverse plugins | `docs/development/csharp-plugins.md` | Ready |
| PCF controls | `docs/development/pcf.md` | Ready |
| Custom APIs | `docs/development/custom-apis.md` | Ready |
| Power Automate cloud flows | `docs/development/power-automate.md` | Ready |
| Dataverse schema | `docs/development/dataverse-schema.md` | Ready |
| Solutions & ALM | `docs/development/solutions-alm.md` | Ready |
| Model-driven app configuration | `docs/development/model-driven-apps.md` | Pending — file does not exist yet |
