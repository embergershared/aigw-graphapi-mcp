# __PROJECT_NAME__

__DESCRIPTION__

<!-- template:start -->
> [!IMPORTANT]
> **This is embergershared/azd-private-starter-template**, a starting point for Azure
> projects. The Azure Developer CLI (`azd`) deploys subscription-scope modular Bicep with
> deterministic naming, an approved region catalog, lifecycle tags and fail-closed preflight
> checks. Start with `core` (a resource group and monitoring), add resources from the module
> catalog, and step up to `private` or `full` when the project needs a network.
>
> Create a repository with **Use this template**, clone it, then run once (PowerShell, in its
> folder):
> ```powershell
> ./scripts/Initialize-Repo.ps1 -Description '<one line about the project>' -Stacks dotnet,python
> ```
> It names the project, removes the stacks you don't use, sets the repository up and opens
> the first PR; see [docs/template.md](docs/template.md). Then record your tenants in the
> local files it created and follow [docs/getting-started.md](docs/getting-started.md).
<!-- template:end -->

> [!NOTE]
> This is a personal project, shared as is to help others. It is not an official Microsoft
> product and is not supported by Microsoft. Review and test it before using any part of it
> in your environment. See [docs/SUPPORT.md](docs/SUPPORT.md).

## Contents

<!-- Keep this README a table of contents: one line on the project above, then the pages.
     Background, how-tos and long explanations go in docs/, one page per topic. -->

**Use it**

| Page | What it covers |
|---|---|
| [docs/getting-started.md](docs/getting-started.md) | **Start here:** local tenant files, a first environment and preview, profiles, adding resources, tests |
| [docs/architecture.md](docs/architecture.md) | The conventions layer, profiles, network, naming contract, extension points |
| [docs/configuration.md](docs/configuration.md) | Profiles, environment values, preflight, expert overrides, resource naming |
| [docs/deployment.md](docs/deployment.md) | Prerequisites and roles, prepare → validate → deploy, Bastion access, cost and teardown |
| [docs/modules.md](docs/modules.md) | The module catalog and its lifecycle scripts |
| [docs/security.md](docs/security.md) | Public exceptions, private DNS, monitoring access, break glass |
| [docs/ci-cd.md](docs/ci-cd.md) | CI, PR rules, public logs and the repository settings |
| [docs/ci-deployment.md](docs/ci-deployment.md) | Pull request deployments into throwaway environments |
| [docs/supply-chain.md](docs/supply-chain.md) | Package feeds, lock files and the 7-day age gate |
| [docs/database.md](docs/database.md) | Database changes: migration, backup, way back |
| [docs/SUPPORT.md](docs/SUPPORT.md) | Questions, bugs, and what support to expect |
| [docs/CHANGELOG.md](docs/CHANGELOG.md) | Changes |
| [docs/template.md](docs/template.md) | What the template contains and how a new project is set up |

**Contribute**

Every change starts with an issue, gets its own `<type>/<issue>-<slug>` branch, and reaches
`main` only through a PR that closes the issue.

| Page | What it covers |
|---|---|
| [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md), [docs/CODE_OF_CONDUCT.md](docs/CODE_OF_CONDUCT.md) | How to contribute |
| [.github/copilot-instructions.md](.github/copilot-instructions.md), [.github/instructions/](.github/instructions/) | The full rules, for people and AI coding assistants, and the per-language ones |
| [docs/decisions/](docs/decisions/) | Decision records |
| [.github/SECURITY.md](.github/SECURITY.md) | Reporting a vulnerability |

## License

[MIT](LICENSE)
