# Catalog recovery

Image publication and catalog publication are separate gates. A successful
`Build images` run can publish signed GHCR images while the public catalog stays
on an older source run. Treat the catalog as recovered only when the live JSON
advances and contains every enabled image version.

## Diagnose

Record the live catalog source and current main commit:

```sh
repository=tektum/verity-images
catalog_url=https://tektum.github.io/verity-images/catalog.json
catalog_source=$(curl -fsSL "$catalog_url" | jq -r .source.commit)
main=$(gh api "repos/$repository/branches/main" --jq .commit.sha)
printf 'catalog=%s\nmain=%s\n' "$catalog_source" "$main"
```

The catalog source must be an ancestor of current main:

```sh
git fetch origin main
git merge-base --is-ancestor "$catalog_source" origin/main
```

Inspect the latest main workflows before recovery. Do not rebuild or restart a
green run merely to refresh the catalog.

```sh
gh run list --repo "$repository" --branch main --limit 20 \
  --json databaseId,workflowName,event,status,conclusion,headSha,url
```

## Recover a stale image catalog

Use one changed-image Build run from the live catalog source to current main.
This creates one complete delta report and avoids rebuilding unchanged images.

```sh
build_url=$(gh workflow run build.yaml --repo "$repository" --ref main \
  -f base-sha="$catalog_source")
build_run=${build_url##*/}
gh run watch "$build_run" --repo "$repository" --exit-status
```

The successful Build run automatically triggers `Build catalog data`. If that
event was not delivered, dispatch the catalog workflow once with the exact
successful Build run ID:

```sh
catalog_run_url=$(gh workflow run catalog.yaml --repo "$repository" --ref main \
  -f mode=images -f run-id="$build_run")
catalog_run=${catalog_run_url##*/}
gh run watch "$catalog_run" --repo "$repository" --exit-status
```

Do not replay historical single-image catalog runs in series. Each replay is
checked against the current complete matrix, so an intermediate catalog remains
incomplete and cannot deploy.

## Verify the public result

Read the successful Build run source SHA and require the live catalog to bind to
that run, contain no fixable findings, and include every currently enabled image
version:

```sh
build_sha=$(gh run view "$build_run" --repo "$repository" --json headSha --jq .headSha)
curl -fsSL "$catalog_url" > catalog.json
jq -e --arg sha "$build_sha" --argjson run "$build_run" '
  .schemaVersion == 2 and
  .source.commit == $sha and
  (.source.runId | tonumber) == $run and
  (.images | length > 0) and
  all(.images[]; .scan.fixable == 0)
' catalog.json >/dev/null
python3 scripts/gen_matrix.py --all > expected-images.json
jq -e --slurp '
  (.[0].images | map([.name, .version]) | sort) ==
  (.[1].include | map([.name, .tag_version]) | sort)
' catalog.json expected-images.json >/dev/null
```

Also verify the latest `github-pages` deployment succeeded and its environment
URL is the catalog URL.

## Known artifact layouts

`actions/download-artifact` extracts multiple `scan-*` matches into
artifact-named subdirectories. A single match can be extracted directly into the
target directory. `scripts/build_catalog.py` supports both layouts and still
rejects missing or mismatched scan evidence.
