# Add the next 50 Tektum image families

## TL;DR

Admit exactly 50 new families through a shared Stage 0 preflight, then deliver
one image-local pull request per family. Stage 0 freezes the release line,
source, registry, track, remediation hypothesis, runtime contract, and duration
class before any agent launches. Merges are serialized through GHCR and public
catalog receipts.

## Scope and guardrails

- Add exactly the 50 families in the manifest below.
- Use one family per row, one image directory, and one image pull request.
- Support plain linux/amd64 and linux/arm64 only.
- Do not add FIPS, extra architectures, waivers, shared workflow changes, or
  implementation scaffolding in family PRs.
- Do not invent exact patches, digests, scanner outcomes, or architecture child
  digests in this plan.
- Every release line below means verify and freeze in Stage 0.

## Lessons converted to rules

- Queue-time runner allocation and execution time are separate budgets. A stall
  guard and catch-up path are required; retries and longer timeouts are not a
  queue fix.
- Schedule long builds late on dedicated capacity. Do not repeatedly rebase them.
  Freeze or serialize final merges so they are not invalidated.
- Cancel obsolete validation only when GitHub reports `BEHIND` and required
  up-to-date protection demands a new head.
- GitHub is authoritative. One owner has one workspace. The supervisor owns
  heartbeats, reconciliation, and cleanup.
- Treat GHCR publication and catalog publication as separate gates. A failed
  `main` build automatically dispatches catalog catch-up from an ancestor-checked
  live source SHA, and an unsuccessful catalog source run must fail loudly. Use
  manual delta recovery only when that automatic path cannot complete.
- Test the stall guard's real pagination and aggregation command. Because `gh api`
  rejects `--slurp` combined with `--jq`, classify required checks from branch
  protection and do not promote auxiliary guard failures to required failures.

## Stage 0 prerequisites

Stage 0 runs before image work. No agent launches until all 50 candidates pass.
Commit one manifest receipt per family. Every receipt contains the exact stable
version or tag, license and redistribution result, selected repository track and
build method, zero-fixable remediation hypothesis, trial scan/build evidence,
runtime and negative tests, privilege and secret profile, expected duration
class, and a held or admitted disposition. APKO receipts contain a reviewed lock
and package provenance. Melange receipts contain the pinned source commit and
dependencies, signed package provenance, and build-specific generated lock.
Patched receipts contain the allowlisted canonical upstream repository identity
or verified upstream signature/checksum, immutable index digest, and amd64 and
arm64 child digests.

The patched-source registry allowlist is `docker.io`, `registry.k8s.io`,
`docker.elastic.co`, and `ghcr.io`, enforced by `scripts/gen_matrix.py`. Any
change is a shared prerequisite, not part of an image PR.

Use `short` for less than 30 minutes, `medium` for 30 to 120 minutes, and `long`
for more than 120 minutes. Exact digests belong only in committed receipts,
never in this planning document. A candidate that fails any admission field is
held until this plan is explicitly amended with a replacement that passes the
same gate.

## Locked candidate release-line manifest

All release lines, tracks, and build methods are feasibility hypotheses, not
approval. They must be verified and frozen in Stage 0.

| # | Family | Release line | Project reference | Track | Build method |
| --- | --- | --- | --- | --- | --- |
| 1 | coredns | 1.14 | https://coredns.io/ | wolfi | APKO |
| 2 | kubernetes-pause | 3.10 | https://github.com/kubernetes/kubernetes/releases | wolfi | APKO |
| 3 | kube-apiserver | 1.36 | https://kubernetes.io/ | wolfi | APKO |
| 4 | kube-controller-manager | 1.36 | https://kubernetes.io/ | wolfi | APKO |
| 5 | kube-scheduler | 1.36 | https://kubernetes.io/ | wolfi | APKO |
| 6 | kube-proxy | 1.36 | https://kubernetes.io/ | wolfi | APKO |
| 7 | helm | current stable 4 line | https://helm.sh/ | wolfi | APKO |
| 8 | opa | current stable 1 line | https://www.openpolicyagent.org/ | wolfi | APKO |
| 9 | thanos | 0.40 | https://thanos.io/ | wolfi | APKO |
| 10 | loki | 3.6 | https://grafana.com/oss/loki/ | wolfi | APKO |
| 11 | tempo | 2.8 | https://grafana.com/oss/tempo/ | wolfi | APKO |
| 12 | grafana-alloy | 1.10 | https://grafana.com/docs/alloy/latest/ | wolfi | APKO |
| 13 | otel-collector | 0.135 | https://opentelemetry.io/docs/collector/ | wolfi | APKO |
| 14 | fluent-bit | 4.2 | https://fluentbit.io/ | wolfi | APKO |
| 15 | vector | 0.51 | https://vector.dev/ | wolfi | Melange |
| 16 | node-exporter | 1.10 | https://github.com/prometheus/node_exporter/releases | wolfi | APKO |
| 17 | cert-manager-controller | 1.19 | https://cert-manager.io/ | wolfi | Melange |
| 18 | external-dns | 0.19 | https://github.com/kubernetes-sigs/external-dns/releases | wolfi | Melange |
| 19 | argocd | 3.1 | https://argo-cd.readthedocs.io/ | wolfi | Melange |
| 20 | argo-workflows | 3.7 | https://argo-workflows.readthedocs.io/ | wolfi | Melange |
| 21 | flux-source-controller | 1.6 | https://fluxcd.io/flux/components/source/ | wolfi | Melange |
| 22 | flux-helm-controller | 1.3 | https://fluxcd.io/flux/components/helm/ | wolfi | Melange |
| 23 | kyverno | 1.15 | https://kyverno.io/ | wolfi | Melange |
| 24 | gatekeeper | 3.19 | https://open-policy-agent.github.io/gatekeeper/ | wolfi | Melange |
| 25 | prometheus-operator | current stable release | https://prometheus-operator.dev/ | wolfi | APKO |
| 26 | metallb-speaker | 0.15 | https://metallb.io/ | wolfi | Melange |
| 27 | contour | 1.32 | https://projectcontour.io/ | wolfi | Melange |
| 28 | envoy-gateway | 1.5 | https://gateway.envoyproxy.io/ | wolfi | Melange |
| 29 | distribution-registry | 3.0 | https://distribution.github.io/distribution/ | wolfi | APKO |
| 30 | zot | 2.1 | https://zotregistry.io/ | wolfi | Melange |
| 31 | gitlab-runner | 18.3 | https://docs.gitlab.com/runner/ | patched | Copa |
| 32 | tekton-controller | 0.61 | https://tekton.dev/ | wolfi | Melange |
| 33 | gitea | 1.24 | https://about.gitea.com/ | wolfi | Melange |
| 34 | cloudnativepg | 1.27 | https://cloudnative-pg.io/ | wolfi | Melange |
| 35 | tidb | 9.0 | https://www.pingcap.com/tidb/ | wolfi | Melange |
| 36 | dragonfly | 1.36 | https://www.dragonflydb.io/ | wolfi | Melange |
| 37 | mosquitto | 2.0 | https://mosquitto.org/ | wolfi | APKO |
| 38 | emqx | 5.8 | https://www.emqx.io/ | patched | Copa |
| 39 | zookeeper | 3.9 | https://zookeeper.apache.org/ | patched | Copa |
| 40 | perl | 5.42 | https://www.perl.org/ | wolfi | APKO |
| 41 | r-base | 4.5 | https://www.r-project.org/ | patched | Copa |
| 42 | swift | 6.2 | https://www.swift.org/ | patched | Copa |
| 43 | cmake | 4.1 | https://cmake.org/ | wolfi | APKO |
| 44 | maven | 3.9 | https://maven.apache.org/ | wolfi | APKO |
| 45 | gradle | 9 | https://gradle.org/ | wolfi | APKO |
| 46 | kube-bench | 0.11 | https://github.com/aquasecurity/kube-bench/releases | wolfi | Melange |
| 47 | syft | 1.31 | https://github.com/anchore/syft/releases | wolfi | Melange |
| 48 | grype | 0.99 | https://github.com/anchore/grype/releases | wolfi | Melange |
| 49 | restic | 0.18 | https://restic.net/ | wolfi | Melange |
| 50 | rclone | 1.71 | https://rclone.org/ | wolfi | Melange |

## Wave strategy

- Prefer APKO for packaged runtimes.
- Prefer Melange for pinned-source Go, Rust, and C builds.
- Use patched only when load-bearing upstream behavior cannot be rebuilt
  minimally. A patched candidate needs a trial scan proving a path to zero
  fixable findings before admission.
- Cap execution at 10 workspaces, 6 implementation agents, 3 CI-active PRs,
  and 3 review-waiting PRs.
- Prepare bounded image-local changes in parallel, but merge one image at a time.
  Wait for serialized main publication and catalog receipt before the next merge.
- Schedule long families late and avoid rebasing them unless GitHub reports the
  head is behind and branch protection requires it.
- Candidates that require capabilities, host namespaces, host sockets, or
  registration credentials need an explicit least-privilege profile. Run those
  checks only on isolated ephemeral runners with synthetic credentials and no
  reusable host access. Exclude a candidate when its contract cannot be tested
  safely under that profile.

## Common family contract

Each family supplies `metadata.yaml`, its reviewed APKO lock, Melange source
recipe and build-specific lock evidence, or digest-pinned patched `source.yaml`,
plus executable `tests/test.sh`.
Metadata names the family, release line, track, upstream, owner, and enabled
state. The image preserves its documented user, command, paths, ports, volumes,
configuration, and data behavior. The test proves one real happy path and one
meaningful negative path on both architectures in CI. No local emulation is
allowed.

## Coordinator and Paseo lifecycle

The Paseo supervisor is the sole launcher and owner. GitHub state is authoritative.
Each workspace has one active owner and one family. The heartbeat reconciles
agents, workspaces, PRs, runs, and schedules without creating duplicates. Archive
the agent and workspace after a verified merge. Stop or remove only resources
proven to belong to this task.

## Verification

- Document-only changes are exempt from TDD, but `./check` must exit 0.
- Verify the table has exactly 50 unique slugs.
- Verify none overlap the current matrix from `python3 scripts/gen_matrix.py --all`.
- The consistency validator must parse plain table cells and must not require
  family names or source URLs to be wrapped in backticks.
- For each family, require lint, build-gate, and apk-gate, classify auxiliary
  checks from branch protection, and scan review threads.
- After merge, verify the GHCR digest, signature, SBOM, provenance, and public
  catalog entry with matching source SHA and `fixable=0`.

## Evidence ledger

Stage 0 receipts are committed per family. Family PR evidence records the base
SHA, head SHA, PR number, required checks, runtime results, scan artifacts, GHCR
digest and verification results, merge SHA, and catalog source SHA. A catalog
receipt shows the public source SHA, run, image entry, digest, tags, and zero
fixable findings. Let the automatic ancestor-validated catalog catch-up run first
when the catalog lags main, then use the documented manual live-source delta only
if automatic recovery cannot complete.

## Cleanup

At each merge, record the PR URL and full merge SHA, verify main publication and
the catalog receipt, archive the owner and workspace, cancel obsolete runs only
when GitHub requires it, and release the slot. At the end, reconcile live
resources and remove only task-owned stale heartbeats, agents, workspaces, and
temporary evidence.

## Deferred exclusions

These families are not reserves and are never automatic substitutions. Replacing
a failed candidate requires an explicit plan amendment and full Stage 0 review.

| Group | Families | Gating reason |
| --- | --- | --- |
| Build and CI | buildkit, docker-in-docker, github-actions-runner, jenkins | privileged runtime, nested daemon, or CI-specific behavior |
| Networking and security | falco, cilium, calico-node, ingress-nginx, harbor, Vault/Nomad | kernel, cluster, registry, or high-risk operational contract |
| Compilers and platforms | clang, forgejo, Neo4j, Jupyter stacks | large dependency surface or unclear runtime scope |
| Databases and queues | kafka, pulsar, MongoDB, CockroachDB, Elasticsearch | long stateful builds, persistence, or license review burden |

## Success criteria

All 50 receipts pass Stage 0, all 50 image-local PRs merge one at a time, and
every merged family has successful required checks, amd64 and arm64
runtime evidence, zero fixable findings, signed digest, SBOM, provenance, and a
matching public catalog entry. No existing family is duplicated and no excluded
family is silently substituted.
