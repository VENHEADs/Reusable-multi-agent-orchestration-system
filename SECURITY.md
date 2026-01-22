# Security Policy

## Reporting a Vulnerability

Please report security issues privately and do not open public GitHub issues.

Send a report to: **security@example.com**

Include the following information to help us validate and fix the issue:
- A clear description of the vulnerability and potential impact.
- Steps to reproduce the issue.
- A minimal proof of concept, if available.
- Affected versions or commit hashes.

We will acknowledge receipt within 72 hours and provide a timeline for a fix
after triage.

## Supported Versions

Only the latest commit on the default branch is supported.

## Security Notes

- Never commit API keys or secrets.
- Use environment variables or macOS Keychain for sensitive credentials.
- Keep `.env` files and other local secrets out of version control.
