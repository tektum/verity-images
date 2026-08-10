# kube-proxy 1.36 admission receipt

Disposition: held.

Blocker: the current isolated CI runs the arm64 image through QEMU on an amd64
kernel. The arm64 privileged probe cannot keep its network namespace holder
running and its iptables nft netlink call reports `Protocol not supported`, so
the required arm64 `NET_ADMIN`/iptables runtime contract is not proven. Keep
this definition disabled until an isolated native arm64 runner executes the
same smoke test successfully; then regenerate the lock, repeat both scans, and
revalidate every admission field before enabling.

## Release and provenance

- Exact upstream release: `v1.36.3`, annotated tag object
  `49c14f82ca9748897f0189be31cbf9c2f4085fc1`, commit
  `0f29094e5b73085e3802ecc1298ecae13866bfe6`, published by the Kubernetes
  Release Robot on 2026-07-22. The canonical source archive SHA-512 is
  `c3ea6328aaa970cc6ce9b097a42e7d8e999eff1cbdf2e62759f07332f66115d6a2c5eb2e5973b3891c9ee36ea75fe0be6450b84f6c430ab31b62e0eb53092f9d`.
- License and redistribution: Apache-2.0. The release's `LICENSE` blob is
  `d645695673349e3947e8e5ae42332d0ac3164cd7`; the locked Wolfi package
  metadata records the same SPDX license identifier.
- Build method: pure APKO. Both Wolfi APKINDEX architecture records bind
  `kube-proxy-1.36` `1.36.3-r2` to origin `kubernetes-1.36`, build config
  `54fac7752bf360a2dbc64e38b2449978b9607c3f`, and Apache-2.0. The current
  recipe blob `2e4e128741b633db505499dfbe3cf35c0752d673` pins the same upstream
  tag and commit. `apko.lock.json` was generated with APKO 1.2.31 and locks
  the Wolfi signing key plus every APK checksum.

## Architectures and remediation

- `linux/amd64`: `kube-proxy-1.36` and `kube-proxy-1.36-default`
  `1.36.3-r2`, data checksums
  `sha256-oo35uvusOkDm/EtSV//GYtxZfH6DEXwGs0KkSNo1LoA=` and
  `sha256-dkwqQxkkmixa43t79ybK1yllLMo/C0SobVC5WV2W0W0=`.
- `linux/arm64`: `kube-proxy-1.36` and `kube-proxy-1.36-default`
  `1.36.3-r2`, data checksums
  `sha256-ZT2ZU2GhJCJzviJw8lzSLP6sHxueQb1hOa+WfQN4UwA=` and
  `sha256-+uZ9Dprqpnm23SE4G8oZr5VTe9w2ikkAP2F/Qmxnjv0=`.
- Zero-fixable hypothesis: assemble only the versioned kube-proxy package,
  its Wolfi-declared iptables/conntrack dependencies, and CA certificates.
  The native amd64 APKO trial image
  `sha256:f96f1dfa011f769d5f3669d86089115a61e6e08b341d94833f4d8ef2b851a0de`
  produced no Grype 0.116.1 findings and `fixable=0`. CI is authoritative for
  fresh amd64 and arm64 builds and must hold publication if either scan has a
  fixable finding.

## Runtime and least privilege

- Contract: root entrypoint `/usr/bin/kube-proxy`, Kubernetes 1.36 version,
  iptables mode, package-owned `/var/lib/kube-proxy` and
  `/var/log/kube-proxy`, and a caller-supplied kubeconfig. Invalid
  configuration must fail. Expected duration class: short.
- Production iptables profile: run as UID 0; drop all capabilities and add
  only `NET_ADMIN`; use the host network namespace so rules apply to the
  node. Do not share host PID, IPC, UTS, user, or cgroup namespaces. Mount a
  dedicated kubeconfig read-only and `/run/xtables.lock` read-write. Do not
  mount `/lib/modules`; that is needed for IPVS, not this iptables profile.
  Run the long-lived process with `--proxy-mode=iptables`. No
  `privileged: true`, `NET_RAW`, `SYS_MODULE`, `SYS_ADMIN`, or reusable host
  credentials are admitted.
- Privileged smoke profile: GitHub Actions ephemeral runner only, private
  Docker network namespace, no host namespaces or host mounts, UID 0,
  `cap-drop=ALL`, `cap-add=NET_ADMIN`, iptables mode, and a synthetic
  loopback-only kubeconfig token. The test proves mutation fails without
  `NET_ADMIN`, creates a recognized `KUBE-SERVICES` chain with it, and verifies
  kube-proxy cleanup removes that chain. It never targets the shared host.
