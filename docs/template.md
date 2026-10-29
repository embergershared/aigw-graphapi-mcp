# What the template contains

New Azure projects start from
[embergershared/azd-private-starter-template](https://github.com/embergershared/azd-private-starter-template).
It brings the azd and Bicep conventions, the module catalog and the pull request deployments,
and the rules, tools, CI and security settings shared with
[embergershared/repo-template](https://github.com/embergershared/repo-template), so each
project doesn't re-create them. Most of these projects are public: the template assumes it.

## Start a project

1. On GitHub: **embergershared/azd-private-starter-template → Use this template → Create a
   new repository** (owner `embergershared` or `g62priv`, public).
2. Clone it, then in its folder (PowerShell):
   ```powershell
   ./scripts/Initialize-Repo.ps1 -Description '<one line about the project>' -Stacks dotnet,python
   ```
   `-Stacks dotnet` or `-Stacks python` removes the other stack's files. `-WhatIf` shows what
   would change; `-SkipGitHub` only edits the files.
   The script replaces the placeholders `__PROJECT_NAME__`, `__REPO__`, `__DESCRIPTION__` and
   `__YEAR__` (this file keeps them) and removes the Markdown between
   `<!-- template:start -->` and `<!-- template:end -->` (the README banner, the template's
   changelog entries). It creates this clone's local tenant files from their examples
   (`scripts/init-local-files.ps1`). It sets the repository (description, issues on, wiki off,
   branches deleted on merge, label `phase`, GitHub Actions) and, when it is public, its
   security features and the `main` ruleset (see [ci-cd.md](ci-cd.md#repository-settings)).
   Where the organization runs Actions in selected repositories only, it adds the repository
   to that list, which needs the `admin:org` scope (`gh auth refresh -h github.com -s
   admin:org`); without it, it skips what needs Actions and says how to finish (see
   [ci-cd.md](ci-cd.md#when-github-actions-is-off)). Then it opens issue *Initialize the
   repository from azd-private-starter-template*, commits on
   `<prefix>/chore/<issue>-initialize-from-template` (`emberger/` in `embergershared`, `emm/`
   in `g62priv`), and opens the PR.
3. Merge that PR once its checks are green. Then see [After the first PR](#after-the-first-pr).

Every other clone of the project, and every CI runner, creates its local tenant files with
`./scripts/init-local-files.ps1` (the test suite runs it too); it never overwrites them.

## Files

| Path | What it does |
|---|---|
| `azure.yaml`, `infra/` | The azd project: subscription-scope Bicep, the conventions layer (`infra/core/`) and the module catalog (`infra/modules/`). See [architecture.md](architecture.md). |
| `scripts/*.ps1` | Preflight, deployment tags, the module catalog tools, the PR deployment helpers, `init-local-files.ps1` (each clone's tenant files) and `Initialize-Repo.ps1` (one-time setup, removes itself). |
| `tests/` | The PowerShell suite: names, rules, catalog, profiles, Bicep build and lint, workflow rules. |
| `infra/core/tenant-codes.example.json`, `docs/targets.example.md` | The committed examples of the gitignored local tenant files. |
| `.github/copilot-instructions.md` | **The rules** for people and AI coding assistants, shared with repo-template, then the *This project* section with the Azure specifics. |
| `.github/instructions/*.instructions.md` | Copilot rules per file type: Azure, Bicep, naming, workflows, .NET, Python. |
| `.github/workflows/ci.yml` | Workflow lint, infrastructure validation, .NET and Python (auto-detected), package age gate, one `CI result` check. |
| `.github/workflows/pr-rules.yml` | Branch name (no owner prefix from a fork), base branch, linked issue, no AI attribution, commit style warnings. |
| `.github/workflows/pr-deployment*.yml`, `deploy-environment.yml` | Pull request deployments into throwaway environments, off until set up ([ci-deployment.md](ci-deployment.md)). |
| `.github/actions/mask-values/` | Masks identifiers and the GUIDs inside them in a job's logs and summary (see [ci-cd.md](ci-cd.md#public-logs)). |
| `.github/dependabot.yml` | GitHub Actions updates with a 7-day cooldown (NuGet and Docker ready to uncomment). |
| `.github/pull_request_template.md`, `.github/ISSUE_TEMPLATE/` | PR body and issue forms (feature, bug, phase). |
| `README.md` | Project page: the description, the "personal project, not an official Microsoft product" note, the **Overview** and **Quick start** sections for the project to fill in, then a table of contents of the pages. |
| `.github/SECURITY.md`, `docs/SUPPORT.md`, `docs/CONTRIBUTING.md`, `docs/CODE_OF_CONDUCT.md` | Private vulnerability reporting, as-is support, how to contribute, Contributor Covenant. |
| `.editorconfig`, `.gitattributes`, `.gitignore`, `.dockerignore` | Editor rules, line endings, ignored secrets, local azd state, tenant files, databases and build output. |
| `global.json`, `Directory.Build.props`, `Directory.Packages.props`, `nuget.config` | .NET 10 SDK, `net10.0`, analyzers, lock files, central package versions, approved feed only. |
| `.python-version`, `ruff.toml`, `scripts/lock_requirements.py` | Python 3.13, ruff settings, hash-locked requirements through the approved feed. |
| `scripts/check_package_age.py` | CI gate: every locked NuGet/PyPI version is at least 7 days old. |
| `scripts/db/` | SQLite backups and EF Core migrations with a way back ([database.md](database.md)). |
| `docs/` | Every other page: getting started, architecture, configuration, deployment, modules, security, CI/CD, PR deployments, supply chain, database, decisions. |
| `docs/CHANGELOG.md`, `LICENSE` | Keep a Changelog; MIT. |

## After the first PR

- **Tenants:** record your tenants and subscriptions in `infra/core/tenant-codes.json` and
  `docs/targets.md` ([deployment.md](deployment.md#local-tenant-and-subscription-files)), then
  follow [getting-started.md](getting-started.md).
- **PR deployments:** set them up when the project deploys to Azure
  ([ci-deployment.md](ci-deployment.md#setup)).
- **Dependabot:** uncomment the `nuget` / `docker` blocks the project needs.
- **CodeQL:** once the project has code, check **Security → Code scanning** lists its
  languages.
- Fill in the *This project* section of `.github/copilot-instructions.md`.

## Keep projects in step with the template

The template only copies files once. When it improves, port the change to existing projects
through an issue and PR in each; a fix found in a project comes back here the same way.
