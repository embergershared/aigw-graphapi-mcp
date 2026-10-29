# Changelog

What changed for users of __PROJECT_NAME__, newest first. Each merged PR adds its line under
**Unreleased** (with its issue number); a release moves them under a dated version.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Unreleased

### Added
- Repository created from
  [embergershared/azd-private-starter-template](https://github.com/embergershared/azd-private-starter-template).
<!-- template:start -->
- One setup script, `scripts/Initialize-Repo.ps1`, turns a new repository into its own
  project: names, stacks, repository settings and security features, then its first issue
  and PR (#17).
- .NET and Python scaffolding: SDK and Python pins, central NuGet versions, the approved feed,
  hash-locked requirements, the 7-day package age gate, database backup and migration scripts;
  CI builds, lints and tests a stack once the repository has its code (#16).
- CI: one **CI result** check sums up the workflow lint and the infrastructure validation;
  **PR rules** checks the branch name, the linked issue, authorship and commit style; Dependabot
  updates the pinned workflow actions after a 7-day cooldown (#15).
- Public repository pages: MIT license, security policy, support, contributing, code of
  conduct, this changelog, decision records, a PR template and issue forms. The README is a
  table of contents; its how-to moved to [getting-started.md](getting-started.md) (#14).
- Pull request deployments: infrastructure changes are previewed, deployed, checked and torn
  down before they merge, once the deployment identity is set up (#21).

### Changed
- The history no longer holds the owner's real tenant and subscription IDs: every commit was
  rewritten with fictitious values, so existing clones must clone again
  ([decision 0001](decisions/0001-history-scrub.md), #19).
- `scripts/init-from-template.ps1` is now `scripts/init-local-files.ps1`: it creates each
  clone's local tenant files, and `Initialize-Repo.ps1` does the one-time setup (#17).
- The tenant catalog and the targets page are local to each clone, created from their
  committed examples by `scripts/init-from-template.ps1` (#12).

### Removed
- The Squad agent workspace (#11).
<!-- template:end -->
