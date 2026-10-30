---
name: triage-image-failure
description: Map a failing image build, validate, native-arm64, approve, or monitor job to its root cause and the minimal fix. Use when a PR or workflow run for an image is red.
---

# Triage an image failure

Get the real error, not the noise (logs include huge metrics charts):

```sh
gh run view --job <job_id> --log-failed | sed 's/^[^\t]*\t[^\t]*\t//' | grep -E '##\[error\]|ERRO|rror:' | head
```

Job id is the number after `/job/` in `gh pr checks <n>` links. `./check` needs
`/nix/var/nix/profiles/default/bin` on PATH if it reports nix missing.

| Symptom | Cause | Action |
|---|---|---|
| `Found N fixable findings` on a pure APKO image | Lock or Wolfi lacks fix | Check Wolfi APKINDEX (x86_64 and aarch64) for the fixed version. Absent: upstream blocker, report. Present: refresh lock or bump the `apko.yaml` pin. |
| Fixable finding on a local melange package `name X-rN -> X-rM`, same version | Epoch behind the fixed epoch | First look for the monitor's queued `local-package-revision.yaml` proposal or its PR (`classify_monitor_remediation.py` emits `localPackageRevisions`); do not open a duplicate. Bump `package.epoch` by hand to the highest M listed only when the monitor reported it blocked (`unsafe` or `ambiguous local package revision epoch`). Rebuild alone will not clear it. |
| Fixable Go module finding in a Wolfi recipe | Needs `go/remediate` or recipe change | Do not edit lock. Check recipe invokes `go/remediate`. |
| `fetch: Expected sha256 does not match found: <hash>` in native-arm64 | Version bumped without `expected-sha256` | Verify the hash against the real artifact independently, then update it. Renovate does not do this. |
| `Download native arm64 packages` fails in validate | Native row failed first | Debug the `native-arm64` job, not validate. |
| `approve` job: `floor version is not an upgrade` | `scripts/validate_security_floor_pr.py` only knows go/semver/semver-coerced/maven schemes; npm datasource unsupported | Needs a separate prerequisite PR to the script with a test; human review covers meanwhile. |
| `lint: no changed pure APKO configuration` on an actions bump | Stale, PR behind main | Rebase (`@dependabot rebase`) and re-evaluate. |
| V8 `Check failed: ch <= 0xffff` in `gen-regexp-special-case` during a source-built Node `native-arm64` build | Wolfi `icu-dev` moved to 79.1 while the recipe uses `--with-intl=system-icu`; independent of the PR's change | Not a quick fix: pin ICU 78 at build and runtime, or use bundled ICU. Needs a decision; report it. |
| PR `BEHIND` | main advanced | Rebase once; cancel obsolete runs only if up-to-date policy requires. |

Melange pins (version, checksum, security floor) need an inline `# renovate:` annotation.

Wolfi index check:

```sh
curl -sfL https://packages.wolfi.dev/os/<arch>/APKINDEX.tar.gz | tar -xzO APKINDEX
```
