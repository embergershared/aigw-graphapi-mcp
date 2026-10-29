---
applyTo: "**/*.py,**/requirements*.in,**/requirements*.lock,ruff.toml,.python-version,pyproject.toml"
---

# Python

- **Version:** `.python-version` (3.13) for the local `.venv`, CI and images.
- **Environment:** always the project's `.venv` (`py -3.13 -m venv .venv`, then
  `.venv\Scripts\python -m pip install --require-hashes -r requirements-dev.lock`), never the
  system Python.
- **Dependencies:** direct dependencies in `requirements.in` (runtime) and
  `requirements-dev.in` (starts with `-r requirements.in`, then ruff, pytest, …). Never edit
  the `.lock` files: run `python scripts/lock_requirements.py`, which pins every package with
  sha256 hashes through the approved feed and keeps only releases at least 7 days old.
- **Lint and format:** `ruff check` and `ruff format` (settings in `ruff.toml`); CI runs both.
- **Tests:** pytest, offline (stub brokers and network clients, fixed seeds and clocks). A bug
  fix comes with a regression test.
- **Logging:** the `logging` module with standard levels only; never `print` for diagnostics.
- **Config:** read environment variables in one module; everything else receives settings.

## Code

- **Types:** type hints on public APIs and on every function's parameters and return; precise
  models for structured data; docstrings on public or non-obvious interfaces. Follow PEP 8.
- **Trust boundaries:** validate every external input where it enters.
- **Idioms:** `pathlib`, context managers for resource lifetime, specific exception types, and
  `async`/`await` for I/O concurrency. No mutable default arguments, bare `except`, swallowed
  exceptions, wildcard imports, or blocking calls in async code.
- **Azure:** managed identity and current Azure SDK clients. Never hardcode or log credentials,
  tokens, connection strings or secret values.
- **Structure:** focused, independently testable modules. Test normal, boundary, async
  cancellation, security and failure paths.
