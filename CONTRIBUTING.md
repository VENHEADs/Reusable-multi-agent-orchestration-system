# Contributing to Agent Factory

Thanks for your interest in contributing! This guide covers the basics for proposing changes and collaborating effectively.

## Table of Contents
- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Workflow](#development-workflow)
- [Testing](#testing)
- [Documentation](#documentation)
- [Security](#security)
- [License](#license)

## Code of Conduct
By participating, you agree to abide by the [Code of Conduct](CODE_OF_CONDUCT.md).

## Getting Started
1. Fork the repository and create your branch from `main`.
2. Run the [Quick Start](QUICKSTART.md) to set up local dependencies.
3. Review the [Best Practices](README.md#best-practices) and [Troubleshooting](TROUBLESHOOTING.md) guides for operational context.

## Development Workflow
- Keep changes focused and scoped to a single improvement.
- Update or add documentation when behavior changes.
- Prefer small, reviewable commits with descriptive messages.

## Testing
This repository primarily relies on shell scripts and runtime behavior.

- If you modify a script, run it manually in a safe environment.
- If you add a new script, include usage instructions in the README or a relevant doc.

Document the tests you ran in your pull request description.

## Documentation
Clear docs are essential. If you change CLI flags, configuration defaults, or workflows, update:
- `README.md`
- `QUICKSTART.md`
- `TROUBLESHOOTING.md`

## Security
Please report vulnerabilities privately via the process in [SECURITY.md](SECURITY.md). Do not open public issues for security reports.

## License
By contributing, you agree that your contributions will be licensed under the [LICENSE](LICENSE).
