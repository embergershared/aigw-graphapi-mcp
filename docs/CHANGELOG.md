# Changelog

What changed for users of aigw-graphapi-mcp, newest first. Each merged PR adds its line under
**Unreleased** (with its issue number); a release moves them under a dated version.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Unreleased

### Added
- Repository created from
  [embergershared/azd-private-starter-template](https://github.com/embergershared/azd-private-starter-template).
- Default-off APIM Developer, Foundry account/project/model composition and Key Vault
  integration, preserving the existing core/private/full profile defaults (#6).
- Four delegated read-only Graph REST/native MCP tools with shared authentication/OBO,
  validated paging, offset-aware 31-day calendar windows and explicit UTF-8 byte bounds (#6).
- Offline-first owned-identity, credential and custom OAuth preparation helpers with
  separately gated changes, no automatic consent, credential resets or secret output (#6).
- A .NET SDK verifier and synthetic protocol/policy/configuration regression coverage (#6).
- [Graph MCP deployment, identity, test and recovery runbook](graph-mcp.md) (#6).

### Changed
- Convention adoption carries preflight's default-off Graph configuration validator,
  so copied hooks remain executable without enabling workload resources (#6).
- The preprovision hook encodes selected model JSON for azd parameter transport,
  preserving nonempty deployment arrays and existing direct ARM callers (#6).
- APIM's Azure Monitor logger omits optional credentials instead of sending
  an invalid empty object; its diagnostic depends on the declared logger.
  Metrics-only monitoring and zero payload/header sampling remain unchanged.
  Live child-resource validation is required; schema validation is insufficient (#6).
- Repeat Graph-gateway provisioning explicitly preserves APIM's disabled legacy
  portal/insecure protocols and the vault's disabled public network access,
  retaining the default-deny firewall and trusted-service exception (#6).
- Gateway credential creation/rotation now fails before `addPassword` until a
  separately approved Set Secret readiness probe/route and verification are
  implemented. Metadata, tokens and read access are not write-readiness proof.
  Post-create storage failures preserve exact nonsecret recovery metadata and
  never retry, print the value or remove credentials automatically (#6).
