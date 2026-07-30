# Contributing

## Add an image

Add one directory under `images/` for a Wolfi image or `patched/` for an
upstream-compatible image. Include `metadata.yaml`, `tests/test.sh`, and either
`apko.yaml` plus its reviewed `apko.lock.json`, or `source.yaml`. A Wolfi image
may instead include `melange.yaml` when it needs a locally built package; its
source commit and dependency overrides must be pinned, and its ephemeral
signed-package lock, provenance, and resolved dependency metadata are uploaded
as build evidence. The smoke test must run the built image and assert real
behavior. Open a pull request; CI generates the affected matrix, builds the
image, scans it, and runs the smoke test without publishing.

Metadata uses this schema:

```yaml
name: example
track: wolfi
description: Direct technical description.
upstream: https://example.com/
versions: [1.0]
owner: tektum
enabled: true
```

Optional `flavors` expand one source definition into tag variants; `plain` has
no suffix and other flavors use `-<flavor>`. Optional `major` adds a major tag.

Use lowercase image names and current upstream versions. Do not add private
repositories, credentials, or custom package feeds. Commit every Wolfi lockfile
update for review with its source change.

## Style

- Use keyboard-only ASCII characters in prose, comments, and documentation.
- Pin every third-party GitHub Action to a full commit SHA with a version
  comment.
- Keep job permissions empty by default and opt in per job.
- Use shell scripts compatible with POSIX `sh`.
- Run `devbox run lint` before requesting review.

## Recommended branch protection

Protect `main` in repository settings. Require pull requests, one approving
review, resolved conversations, the `lint` and `build` checks, and branches to
be current before merge. Block force pushes and branch deletion. Repository
administrators must configure these settings because workflows cannot safely
protect their own branch.
