# 0001: Rewrite the history to remove real tenant identifiers

- **Date:** 2026-10-28
- **Status:** accepted
- **Issue:** #19

## Context

Until #12, the tracked files named the owner's real tenants: two tenant IDs, two subscription
IDs, the tenants' codes, a managed-environment code and a tenant name, in the tenant catalog,
the targets page, tests and docs. #12 moved them to gitignored local files, but every earlier
commit still showed them, in this public repository, to anyone who browsed or cloned it.

A scan of every commit on every branch found exactly four GUIDs that are no longer on `main`:
the two tenants and two subscriptions. The codes and the name appeared only in tenant contexts
(the catalog, subscription names, expected resource names and some commit messages), so a
literal replacement could not hit anything else. There were no forks and no open pull
requests.

## Options

| Option | For | Against |
|---|---|---|
| Leave the history | Nothing breaks | The identifiers stay public |
| Squash into one new root commit | Simplest | Loses the history and every PR's commits |
| Replace the values in every commit (`git filter-repo --replace-text`) | Keeps the history, its shape and messages | New commit IDs; clones and old branches must start again |

## Decision

Replace each value in every file and commit message with a fictitious one, then force-push
the rewritten branches.

| Real value | Replaced with |
|---|---|
| The two tenant IDs and two subscription IDs | `00000000-0000-4000-8000-00000000000<n>`, and their 8-character prefixes with `00000000` |
| The tenants' codes and the managed-environment code | `100001`, `200002`, `300003` |
| The second tenant's name | `Fabrikam` |

The list of real values was kept outside the repository and is not written here.

## How it was done

1. Backup: a git bundle of a mirror clone (every branch and pull request ref), checked by
   restoring it into an empty repository: same `main`, same 68 commits. The maintainer keeps
   it offline; it still holds the real values.
2. Dry run on another mirror clone: `git filter-repo --replace-text <list> --replace-message
   <list>`. No value left in any file or message, and the latest `main` tree unchanged.
3. The same on a fresh mirror clone of the current history.
4. The `main` ruleset disabled, the five branches force-pushed with a lease on their old commit
   IDs (nothing had moved since the backup), and the ruleset enabled again.
5. A new clone from GitHub: no value left on any branch or in any message, and `main`'s tree
   identical to the one before the rewrite.

## Consequences

- Every commit up to the first one that held a value has a new ID. Existing clones and
  worktrees must clone again (or reset their branches to the new `origin`), and must not push
  old branches back.
- Merged pull requests keep their old commits, and GitHub keeps cached views of them, until
  GitHub Support removes them; that request, and deleting the workflow runs created before
  #12's merge (their logs may show the values), are the maintainer's.
- Secret scanning doesn't recognize tenant or subscription IDs. They stay out of the
  repository because the tenant catalog and the targets page are gitignored, local to each
  clone, and only their fictitious `.example` files are committed.
