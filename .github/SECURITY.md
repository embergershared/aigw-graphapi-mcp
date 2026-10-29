# Security

## Reporting a vulnerability

Please don't open a public issue for a security problem. Report it privately instead:
**Security → Report a vulnerability** on this repository
([private vulnerability reporting](https://docs.github.com/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)).

Include what you found, how to reproduce it, and what it affects. Leave out real secrets,
customer data, and tenant or subscription IDs: describe them instead.

This is a personal project maintained on a best-effort basis: there is no response-time
commitment, but reports are read and acknowledged.

## Scope

This repository only. A vulnerability in a Microsoft product or service goes to the
[Microsoft Security Response Center](https://msrc.microsoft.com/create-report); one in a
dependency goes to that project.

The security design of what the template deploys (private endpoints, public exceptions,
break glass) is in [docs/security.md](../docs/security.md).

## What the repository does to stay safe

- Dependabot alerts, and Dependabot updates of the workflow actions no sooner than 7 days
  after their release.
- Every workflow action is pinned by commit SHA, and CI lints the workflows.
- Code dependencies, once a project adds them, are locked with hashes, come from an approved
  feed, and are at least 7 days old ([supply-chain.md](../docs/supply-chain.md)).
- The tenants and subscriptions a clone deploys to stay in gitignored local files; only
  fictitious examples are committed.
- Workflows run on GitHub-hosted runners with read-only tokens by default. The pull request
  deployments sign in to Azure through OIDC, never with a stored secret, never run for pull
  requests from forks, and stay off until configured
  ([ci-deployment.md](../docs/ci-deployment.md)).
