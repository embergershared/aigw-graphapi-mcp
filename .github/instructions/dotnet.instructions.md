---
applyTo: "**/*.cs,**/*.csproj,**/*.props,**/*.targets,**/*.slnx,**/*.sln"
---

# .NET

- **SDK and target:** `global.json` pins the SDK (10.0.4xx, `rollForward: latestFeature`);
  `Directory.Build.props` sets `net10.0`, nullable, implicit usings, analyzers
  (`latest-recommended`) and code style enforced in the build. A project overrides only what it
  must.
- **Packages:** Central Package Management. Add a version once in `Directory.Packages.props`;
  projects use `<PackageReference Include="..." />` without a version. Restore only from the
  feed in `nuget.config`. A new version must be at least 7 days old.
- **Lock files:** commit every `packages.lock.json`. After changing a package, run
  `dotnet restore --force-evaluate` and commit the updated lock files; CI restores in locked
  mode and fails on a stale lock.
- **Format:** `dotnet format --verify-no-changes` runs in CI; run `dotnet format` before
  committing.
- **Tests:** xUnit, one test project per production project (`<Project>.Tests`). A bug fix
  comes with a regression test.
- **EF Core migrations:** only through `scripts/db/Invoke-EfMigration.ps1` (backup first, trial
  on a copy, rollback on failure). See `docs/database.md`.
- **Configuration and secrets:** options classes bound once at startup; secrets from
  user-secrets or environment variables, never `appsettings*.json`.

## Code

These adapt the
[Awesome Copilot C#](https://github.com/github/awesome-copilot/blob/main/instructions/csharp.instructions.md)
and [.NET architecture](https://github.com/github/awesome-copilot/blob/main/instructions/dotnet-architecture-good-practices.instructions.md)
guidance.
- **Nullable:** prefer non-nullable models, validate at entry points, and use `is null` /
  `is not null`.
- **Async:** `async`/`await` for I/O, with a `CancellationToken` passed through every
  asynchronous boundary.
- **Style:** standard C# naming, pattern matching where it reads better, `nameof` for member
  names, and XML documentation on public APIs. `.editorconfig` sets the rest.
- **Services:** built-in dependency injection, options validation, structured logging, managed
  identity, and current Azure SDK clients. Never log secrets or tokens.
- **Errors:** explicit, centralized exception handling; HTTP APIs return RFC 9457 Problem
  Details, without stack traces or sensitive data.
- **Clean Architecture, dependencies inward:** `Presentation -> Application -> Domain`.
  Domain holds the business rules and depends on no persistence, HTTP, Azure SDK or framework
  infrastructure. Application holds the use cases and ports; Infrastructure implements those
  ports as adapters and is wired at the composition root; Presentation translates transport
  concerns. Add no repository abstraction over EF Core unless it protects a real domain
  boundary or makes testing easier.
- **Test** normal, boundary, cancellation, authorization and failure paths.
