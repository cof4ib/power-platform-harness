# WebResources Project Standards

Read `docs/agents/development-standards.md` first, and `docs/development/javascript.md` for the
language, structure and testing rules the web resources themselves follow. This file only covers
the project that wraps them for the IDE and the test/lint tooling.

## Stack

- The WebResources folder is an SDK-style project: `src/WebResources/{{publisher_prefix}}.WebResources/{{publisher_prefix}}.WebResources.esproj`, using `Sdk="Microsoft.VisualStudio.JavaScript.Sdk"` with no pinned version — the resolver picks the release installed with Visual Studio, so the standard is the SDK identity, not a build number.
- `Dataverse.sln`, at the repository root, references this project. Add further Dataverse projects (plugins, custom APIs) to the same solution as they are created; do not scaffold placeholder projects for work that does not exist yet.
- Tooling is test and lint only: Vitest + ESLint, per `docs/development/javascript.md`. No bundler, no TypeScript, no UI framework — the `.esproj` is a Visual Studio convenience for editing and testing the plain JavaScript web resources described there, not a build step. Introducing one is a separate, deliberate decision, not a side effect of adopting this standard.

## Structure

- Source lives under `{{publisher_prefix}}_/src/{js,html,css,icons}`, matching the prefix-underscore convention Dataverse expects component names to start with.
- `package.json`, `vitest.config.mjs` and `eslint.config.js` sit next to the `.esproj`, scoped to this project only.

## Adapting to an existing project

A repository that already edits web resources without this project is not missing something
broken — many teams manage Dataverse web resources with nothing more than a text editor. Installing
this project into an existing repository happens only when the user asks for it: see the
reconciliation step in the `set-power-platform` skill.
