# Task 8A Evidence

- Oracle session `ses_03cd0bd1dffeQttCdGBVHlHWuz` traced the failure to the outer stdout redirection on the Devbox command. A cold-run Devbox banner entered `expected-images.json`, so the file ceased to be valid JSON before the strict inventory `jq` check.
- The fix moves the redirection into `sh -c`, so only `gen_matrix.py` writes `expected-images.json`; Devbox output remains outside the JSON file.
- Red regression: `scripts/test_workflow_policy.py` failed against the old workflow command after its expected command was changed.
- Green regression: `scripts/test_build_catalog.sh` uses a fake cold-run `devbox` banner, verifies the banner is separate, and parses exactly 22 matrix entries from `expected-images.json`.
- Commits: `3ea0dea` and `6bdb19e`.
- Local gate: `./check` passed before the PR was opened.
- PR and CI run links will be added after push.
