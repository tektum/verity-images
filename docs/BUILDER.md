# Builder assessment

This is the assessment of the builder that produces every digest published
under `ghcr.io/tektum`, and the policy a consumer applies to accept one. It
covers the SLSA v1 Build track claim made in [POLICY.md](POLICY.md#sbom-and-provenance).

## Trusted builder

The builder is the reusable workflow
`tektum/verity-images/.github/workflows/publish.yaml` at `refs/heads/main`.
`build.yaml` calls it with no steps of its own, so the Fulcio certificate of
every signature and attestation names `publish.yaml`, not the caller. Only
`main` can run it (`if: github.ref == 'refs/heads/main'`), behind the `release`
environment and the repository's branch protection and merge queue. Workflow
changes are reviewed through the same pull request path as image changes.

The job holds `attestations`, `contents`, `id-token`, and `packages` write on
both caller and callee, and no PAT or stored signing secret.

## Runner isolation

Every build runs on [RunsOn](https://runs-on.com) self-hosted runners in the
operator's own AWS account. GitHub-hosted runners are not used because of build
resource needs. RunsOn documents these per-job properties in its
[security page](https://runs-on.com/docs/control-plane/security/):

- one EC2 instance per job that no other job has used, terminated when the job ends
- a just-in-time runner registration valid for one job
- a runner IAM role that cannot read Secrets Manager
- no inbound traffic unless SSH is allowed
- IMDSv2 only

These are properties of the RunsOn software and are not verified by this
repository. The runner attestation below checks what the job can observe.

## Runner-environment attestation

For every digest, `publish.yaml` attaches a signed in-toto attestation with
predicate type `https://verity.supply/attestations/runner-environment/v1`,
produced with `actions/attest` and pushed to the registry next to the image
before release tags are promoted, so a failed attestation never leaves a tag on a
digest that fails the policy below.
`scripts/runner_environment.sh collect` runs first in the job and fails the job
unless all of these hold:

- IMDSv1 is refused (a request without a session token returns 401) and IMDSv2
  answers. Transport failures are retried three times before the job fails.
- The instance life cycle is `on-demand`.
- `RUNS_ON_INSTANCE_ID` equals the instance id from the IMDS identity document.
- The runner name GitHub assigned (`RUNNER_NAME`) equals `RUNS_ON_RUNNER_NAME`
  and names that same instance, so the runner that took this job is the one
  RunsOn registered on this instance.
- The instance `pendingTime` is at most 900 seconds before the check. The check
  is the first step after checkout, so an instance that had been running for
  longer than that cannot be the instance RunsOn launched for this job.

The predicate records the instance id, AMI id, instance type, life cycle,
architecture, region, availability zone, `pendingTime`, the RunsOn version and
stack name, the run id, attempt, job index, workflow ref, the checks above with
the measured instance age, and `resolvedDependencies`: the digests of the apko
lock (Wolfi track) or the resolved upstream image digest (patched track), the
tool archives installed for the build (checked against the pins in
`publish.yaml` before use), and downloaded native arm64 packages.

What this proves: the signer, `publish.yaml@main`, observed a freshly launched,
IMDSv2-only EC2 instance bound to the job's runner, and bound the listed build
inputs to the digest.

What it does not prove:

- The attestation is produced by the job it describes. Build steps in that job
  can reach the signing identity, so a compromised build could forge it. This is
  the same open limit as the shared signing and build job in
  [POLICY.md](POLICY.md#sbom-and-provenance), and the attestation does not
  close it.
- The IMDS values are read over the instance-local endpoint and the instance
  identity signature is not checked. The age bound shows the instance is young;
  it does not prove no earlier job ran on it. That property is RunsOn's.
- GitHub still reports `runnerEnvironment: self-hosted` in the SLSA provenance.
  The provenance `resolvedDependencies` still list only the Git commit; the
  other build inputs are in this attestation instead.

## Owner-asserted stack settings

These RunsOn stack settings are reported by the stack owner. They are not
verifiable from this repository or from the attestation. Recorded 2026-11-08.

| Setting | Owner assertion |
|---|---|
| `EnableCacheIsolation` | enabled |
| `Private` | `only` |
| `EncryptEbs` | enabled |
| `SSMAllowed` | `false` (Session Manager access to runners is off) |
| SSH, `EnableStickyDiskIsolation` | not asserted |

## Consumer verification policy

Accept a digest only if all of the following pass. Replace `IMAGE` and `DIGEST`.
Use a digest, never a tag.

1. Build provenance exists and was produced by the trusted builder:

   ```sh
   gh attestation verify oci://ghcr.io/tektum/IMAGE@sha256:DIGEST \
     --repo tektum/verity-images \
     --signer-workflow tektum/verity-images/.github/workflows/publish.yaml
   ```

2. The runner-environment attestation exists, was signed by the same builder,
   and records a fresh IMDSv2-only on-demand instance:

   ```sh
   gh attestation verify oci://ghcr.io/tektum/IMAGE@sha256:DIGEST \
     --repo tektum/verity-images \
     --signer-workflow tektum/verity-images/.github/workflows/publish.yaml \
     --predicate-type https://verity.supply/attestations/runner-environment/v1 \
     --format json |
     jq -e '.[0].verificationResult.statement.predicate
       | .checks.imdsV1Refused and .checks.runnerBoundToInstance
         and .checks.instanceAgeSeconds <= 900 and .instance.lifecycle == "on-demand"
         and .builder.runnerEnvironment == "self-hosted"'
   ```

3. The keyless signature and SPDX SBOM verify with the `publish.yaml` identity
   shown in [POLICY.md](POLICY.md#signing-identity).

Digests published before the runner attestation landed have none and fail
step 2. Digests published before `publish.yaml` landed fail the
`--signer-workflow` checks; see POLICY.md for how they verify.

A consumer that does not accept the owner-asserted settings above, or the
shared signing job limit, should not rely on the Build L3 claim for this
builder.
