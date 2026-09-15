# Dataverse Plugin Standards

Read `docs/agents/development-standards.md` first. This file only adds what is specific to plugins.

## Stack
- Target .NET Framework 4.6.2.
- Use SDK-style projects and deploy as Dataverse `.nupkg` plug-in packages.
- Do not strong-name assemblies. Initialize with `pac plugin init --skip-signing`; no `.snk`; `<SignAssembly>false</SignAssembly>`.
- Generate early-bound classes with `pac modelbuilder` into `src/Plugins/Generated/`. Never edit generated files manually.
- Tests: xUnit 2.9.3 + FakeXrmEasy.Plugins.v9 2.9.4. Add FakeXrmEasy.Messages.v9 2.9.4 only when message/Custom API simulation requires it.
- Each plugin project has exactly one test project: `<PluginProject>.Tests`.

## Structure
- All plugins MUST inherit `src/Plugins/Common/PluginBase.cs`; never resolve services directly from `IServiceProvider`.
- One plugin class = one business capability, not one entity. Split distinct behaviors into separate plugins/steps.
- Plugin classes SHOULD be `sealed`.
- Namespace: `{{root_namespace}}.Plugins.<Entity>`. Class names describe the capability, e.g. `ValidateCreditLimitOnUpdate`.
- Keep plugins stateless: no mutable instance/static state. `static readonly` is allowed only for immutable compile-time values.
- Do not reference plugin classes from other plugins as an API; shared logic belongs in a shared internal library.

## Business Logic
- Dataverse-specific code (`IOrganizationService`, `IPluginExecutionContext`, `Entity`, etc.) belongs in the integration layer; pure rules use plain C# values and POCOs.

## Pipeline
- Prefer PreValidation for validation, PreOperation for modifying `Target`, and PostOperation when the operation requires persisted data.
- Prefer `Target`, registered images and execution context data over unnecessary `Retrieve` calls.
- Register filtering attributes only for attributes actually required by the plugin.
- Register required pre/post images explicitly. If required data is missing, fail fast with tracing.
- Avoid outbound HTTP calls in synchronous plugins if possible. If explicitly required, use strict timeouts and follow sandbox constraints. Move long-running or reliability-sensitive work to async processing or queues.
- Prevent recursive/self-triggering writes. Use `context.Depth` only when appropriate; never use a blanket `Depth > 1` guard as a substitute for correct trigger design.

## Error Handling & Tracing
- Expected business/validation failures: `InvalidPluginExecutionException` with a user-safe message.
- Use `ITracingService` for diagnostics: the trace is the only forensic record a synchronous plugin leaves behind.

## Testing
- Plugin tests MUST execute the production `Execute` path using FakeXrmEasy; never test against a live Dataverse environment.
- Cover recursion and pipeline-depth behavior wherever the plugin can retrigger itself.
- After changes, build affected projects and run all affected tests.
