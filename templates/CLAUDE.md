# Description
{{project_description}}

## Development standards

`docs/agents/development-standards.md` is mandatory reading before any change: it holds the technology-agnostic rules, the Definition of Done, and the index of per-technology standards. From that index, read only the file(s) relevant to what you're about to touch; don't preload the others.

## Operating principles

These apply to every task, regardless of technology — unlike the per-technology standards above, don't wait for a lookup to apply them.

### Tool usage

- Inspect available tools before implementing anything; prefer tools over assumptions.
- Use, when applicable: skills for specialized domain knowledge; MCP servers for inspection/operations; `pac` (Power Platform CLI) for Power Platform lifecycle operations; `gh` (GitHub CLI) for repository operations; official docs / web search when current Microsoft behavior, CLI syntax, SDK versions, or platform capabilities are relevant.

### Git rules

- Commit only once the change satisfies the Definition of Done in `docs/agents/development-standards.md` — never leave a commit as the final state of a task in a broken or partially-implemented condition.
- Commit messages describe the change and its motivation, not just the action (`fix`, `update` alone are not enough).
- Never force-push, rewrite published history, or amend commits already pushed to a shared branch, unless explicitly instructed to.
- Prefer `gh` for PR creation, review, and inspection over the web UI.
- Branch naming: `<type>/<short-description>` (e.g. `fix/`, `feature/`, `chore/`).

### Definition of Done

Defined in `docs/agents/development-standards.md`. Read it before starting a change, not after finishing one.

### Undefined decisions

- When a technical decision isn't explicitly defined, resolve it in this order: inspect the existing codebase → inspect the project documentation → inspect available skills → inspect relevant MCPs and official Microsoft documentation → prefer the established project pattern → if no project standard exists, choose the simplest Microsoft-supported approach → document the decision before implementing it, if it affects architecture or project-wide conventions.
