# Custom API Standards

Read `docs/agents/development-standards.md` first, then `docs/development/csharp-plugins.md`: a Custom API implemented in C# **is** a plugin, and every plugin rule applies to it unchanged. This file covers only what the plugin standards do not — the contract.

## When a Custom API is the right tool

- Use one to expose a named business operation to callers: web resources, PCF controls, flows, external integrations.
- Do not use one to wrap what the Web API already offers. Retrieving, creating and updating records need no custom message.
- A Custom API is a public contract. Once callers exist its shape cannot change freely, so the decision to add one is not reversible in practice.

## Definition

- Unique name: `{{publisher_prefix}}_<VerbNoun>`, e.g. `{{publisher_prefix}}_CalculateWorkOrderPrice`. Name the operation, never the caller.
- Bind to a table only when the operation genuinely acts on that table's record. Otherwise leave it unbound.
- `IsFunction` is true only for side-effect-free reads. Anything that writes is an action.
- `EnabledForWorkflow` only when a flow or workflow actually calls it.
- `IsPrivate` for internal operations that must not surface as a public message.
- `AllowedCustomProcessingStepType` stays at `None` unless third-party plugin steps are explicitly meant to extend the call.
- Set `ExecutePrivilegeName` when the operation requires a specific privilege. Never rely on the caller happening to be a system administrator.

## Request & response

- Declare every parameter with its type, and mark it optional only when the implementation genuinely handles its absence.
- Name parameters for the business concept, not the storage type.
- Return what the caller needs and nothing more. Do not return a whole entity when one value is the answer.
- Never return raw exception details, internal identifiers or diagnostic dumps through a response parameter.
- Failures use `InvalidPluginExecutionException` with a user-safe message, exactly as in any plugin.

## Change & versioning

- Adding an optional request parameter, or a response parameter, is backwards compatible. Removing, renaming or retyping anything is not: create a new Custom API and retire the old one once callers have moved.
- Every Custom API and its parameters are documented as part of the change that introduces them.
- The definition is a solution component: it lives in `{{solution_name}}` and in the feature solution of the branch that created it, and travels with the solution. Never hand-created per environment.

## Testing & verification

- The implementation is tested as a plugin, with FakeXrmEasy, per `docs/development/csharp-plugins.md`.
- The contract itself is verified against the environment: the message exists with the expected parameters, and one real call returns the expected shape.
- The unpacked solution diff is committed with the change.
