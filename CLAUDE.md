# Description

This repository is a Claude Code plugin that scaffolds Power Platform / Dynamics 365 CE
repositories. It ships one skill, `set-power-platform`, and the templates it writes.

It is not a Power Platform project: nothing here is deployed to Dataverse. The standards in
`templates/docs/` govern the projects this plugin creates, not this repository.

## Layout

| Path | What it is |
| --- | --- |
| `.claude-plugin/plugin.json` | Plugin manifest. Lists the skills explicitly |
| `.claude-plugin/marketplace.json` | Makes this repo its own single-plugin marketplace |
| `skills/set-power-platform/SKILL.md` | The skill: collects values, runs the scaffold, reports |
| `scripts/scaffold.ps1` | Deterministic copy + token substitution. The only thing that writes files |
| `templates/` | Content shipped verbatim into every scaffolded project |

## Rules for changing `templates/`

- Template content is the product. Change it only when the standard itself changes, and say why
  in the commit message. No formatting sweeps, no rewording for its own sake.
- Every generated project inherits the change, including projects already scaffolded, which will
  not pick it up automatically. Treat a template change as a breaking change to a published
  contract and note it in the commit.
- `templates/docs/agents/development-standards.md` owns the standards index. Adding a file under
  `templates/docs/development/` without adding its row to that index leaves the file unreachable.
- Keep the template free of anything project-specific or client-specific. This repository is
  public: no environment urls, tenant ids, client names, solution names or real prefixes.

## Tokens

Tokens are written `{{snake_case}}`. The authoritative list lives in two places that must agree:
the `$tokens` hashtable in `scripts/scaffold.ps1`, and the value table in
`skills/set-power-platform/SKILL.md`.

| Token | Resolved from |
| --- | --- |
| `{{project_name}}` | `-ProjectName` |
| `{{publisher_name}}` | `-PublisherName` |
| `{{publisher_prefix}}` | `-PublisherPrefix` |
| `{{solution_name}}` | `-SolutionName` |
| `{{root_namespace}}` | `-RootNamespace` |
| `{{project_description}}` | `-ProjectDescription` |

Adding a token means touching all three: the template, the script parameter and hashtable, and
the skill's table. The script fails the scaffold when an unresolved token survives, so a token
added to a template alone breaks every run.

## Verify a change

Run all three before committing:

```powershell
claude plugin validate .

# Scaffold into a throwaway folder and inspect the result
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "pph-$([guid]::NewGuid())"
pwsh -NoProfile -File ./scripts/scaffold.ps1 -ProjectName Northwind `
    -PublisherName 'Northwind Consulting' -PublisherPrefix nwc -SolutionName NorthwindCore `
    -RootNamespace Northwind -ProjectDescription 'Test scaffold.' -TargetPath $tmp

# A second run over the same folder must abort without writing
pwsh -NoProfile -File ./scripts/scaffold.ps1 -ProjectName Northwind `
    -PublisherName 'Northwind Consulting' -PublisherPrefix nwc -SolutionName NorthwindCore `
    -RootNamespace Northwind -ProjectDescription 'Test scaffold.' -TargetPath $tmp
```

Then bump `version` in `.claude-plugin/plugin.json`: installed plugins update by version.

## Git

- Branch naming: `<type>/<short-description>` (`fix/`, `feature/`, `chore/`).
- Commit messages describe the change and its motivation, not just the action.
- Never force-push or rewrite published history.
- Prefer `gh` for PR creation and inspection over the web UI.
