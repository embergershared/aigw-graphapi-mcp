# Deployment targets

The tenants and subscriptions this clone deploys to. This file is the committed
example: `scripts/init-local-files.ps1` copies it to `docs/targets.md`, which
is gitignored. Replace the example values there with your own, and list each
tenant in `infra/core/tenant-codes.json`.

The default target is tenant `<tenant-guid>` (code `<tenant-code>`) and
subscription `<subscription name>` (`<subscription-guid>`).

| Tenant | Tenant ID | Code | Subscriptions |
|---|---|---|---|
| Contoso | `00000000-0000-0000-0000-000000000000` | `123456` | `Contoso-s1-Hub`, `Contoso-s2-Sandbox` (default) |

Every tenant in this table must be listed in `infra/core/tenant-codes.json`. To
add one, follow
[Deploy to another tenant or subscription](deployment.md#deploy-to-another-tenant-or-subscription).
