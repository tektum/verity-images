# Scan identity allowlist

Images whose main software the scanners cannot see yet, one file per image, each
with the follow-up that removes it.

`scripts/scan_identity.py` fails the build of any image-local melange recipe that
neither declares `scan-identity` in `metadata.yaml` nor exposes a versioned main
component natively. These entries are the images that predate the rule.

A file is named after the image context with `/` replaced by `__`
(`images/elixir/1.17` is `images__elixir__1.17`). Its first line is the
follow-up and the rest is the reason text:

- `identity`: declare scan-identity in the image's metadata.yaml.
- `go-version`: stamp the Go main module version (or declare scan-identity).
- `unverified`: never published; confirm coverage on its first build, else declare
  scan-identity.
- `no-feed`: no CPE, GHSA or OSV record exists for the main software; the gate
  covers dependencies and OS packages only. Permanent: `FROZEN_NO_FEED` in
  `scripts/test_scan_identity.py` freezes the set.

The list may only shrink. The image-local pull request that declares scan-identity
or stamps the Go main module version deletes its image's file in the same change,
and touches nothing else here or in the test. `scripts/check_scan_identity_allowlist.py`
fails a change that adds an entry, and `scripts/test_scan_identity.py` rejects any
entry outside its frozen baseline.
