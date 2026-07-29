# Security policy

## Reporting

Use GitHub private vulnerability reporting for security issues in an image or
the build pipeline. Do not open a public issue before maintainers have had a
reasonable opportunity to investigate.

Include the image digest, architecture, scanner output or reproduction steps,
and why the issue affects the published artifact.

## Scope

In scope:

- vulnerabilities introduced by this repository's image configuration;
- signature, SBOM, provenance, or digest mismatches;
- workflow permission or supply-chain weaknesses;
- a published image that differs from its recorded build inputs;
- a smoke test or scan gate that can be bypassed.

Upstream package vulnerabilities with no available fix are tracked in scan
reports but are not pipeline vulnerabilities. General support requests and
requests for old image versions are out of scope.
