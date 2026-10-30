# aigw-graphapi-mcp

Prepare an Entra-protected APIM-native MCP gateway for signed-in-user Microsoft Graph mail/calendar access from a Foundry agent.

> [!NOTE]
> This is a personal project, shared as is to help others. It is not an official Microsoft
> product and is not supported by Microsoft. Review and test it before using any part of it
> in your environment. See [docs/SUPPORT.md](docs/SUPPORT.md).

## Overview

<!-- Keep this section: a few lines on what the project does and for whom. The details go in
     docs/architecture.md. -->

A Foundry prompt agent reads the signed-in user's mail and calendar through Azure API
Management's native MCP server. APIM validates the user's delegated Entra token, exchanges
it on behalf of the user for a Microsoft Graph token, and calls only Graph v1.0 `/me`. Four
read-only tools: `list_messages`, `get_message`, `list_calendar_view` and `get_event`.

The azd project deploys APIM Developer, a Foundry account and project with its model, and
Key Vault into one resource group. Graph and MCP stay off (`graphMcp`) until the tenant
apps, consent and the gateway credential are approved; see [docs/graph-mcp.md](docs/graph-mcp.md).

## Quick start

<!-- Keep this section: the few commands that take a new user from a clone to a first
     preview or deployment, each with where it runs. The full walkthrough stays in
     docs/getting-started.md. -->

## Contents

<!-- Keep this README short: the Overview and Quick start above, then this table of contents of
     the pages. Background, how-tos and long explanations go in docs/, one page per topic. -->

**Use it**

| Page | What it covers |
|---|---|
| [docs/graph-mcp.md](docs/graph-mcp.md) | **Graph MCP start here:** contracts, identity, OAuth, deployment gates, synthetic verification and recovery |
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
| [docs/template.md](docs/template.md) | Historical starter provenance; not a project initializer |

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
