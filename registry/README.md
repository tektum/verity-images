# Verity vanity OCI registry

`worker.mjs` is a read-only Cloudflare Worker that exposes public Verity images
through `verity.supply/<image>` while preserving `ghcr.io/tektum/<image>` as the
canonical registry.

The Worker never accepts pushes or client credentials. It obtains a short-lived
anonymous GHCR pull token for the namespaced upstream repository, then proxies
the requested artifact. Requests outside the OCI read surface return `404`.

## Supported OCI distribution requests

- `GET` and `HEAD` on `/v2/`
- image manifests, including legacy cosign signature tags
- `sha256` blobs
- OCI referrers, used by modern signature and attestation discovery

For example, the alias request below is resolved upstream as shown:

```text
verity.supply/caddy:latest
ghcr.io/tektum/caddy:latest
```

`charts` and `tektum` are deliberately reserved and cannot be used as alias
repositories. This prevents namespace confusion such as
`verity.supply/tektum/caddy`.

## Deployment

Install the pinned Wrangler version with `npm ci`, start the Worker locally with
`npm run dev -- --ip "$(tailscale ip -4)"`, then deploy it with
`npx wrangler deploy`. `wrangler.jsonc` binds the Worker to
`verity.supply/v2/*`; the website continues to serve the remaining paths.

No secrets or environment variables are required. The Worker requests only
anonymous, repository-scoped pull tokens from GHCR and never forwards a client
`Authorization` header upstream.

Cloudflare security controls must allow OCI clients on `/v2/*`. A WAF or bot
rule that challenges Docker's manifest `HEAD` requests blocks the request before
it reaches this Worker.

## Verification

Run the unit tests, syntax check, Wrangler dry-run, and startup profile locally:

```bash
cd registry
npm ci
npm test
npm run check
npm run deploy:dry-run
npm run check:startup
```

With `npm run dev -- --ip "$(tailscale ip -4)"` running, replace
`TAILSCALE_IPV4` below with the address printed by `tailscale ip -4`:

```bash
curl --resolve verity.supply:8787:TAILSCALE_IPV4 \
  http://verity.supply:8787/v2/
```

After deployment, verify an alias through an OCI client:

```bash
docker pull verity.supply/caddy:latest
```

The Worker exposes the manifest, legacy cosign signature-tag, and OCI-referrer
surfaces used by signature and attestation tooling. Verification also requires
that the image has an associated signature or attestation. If a tool only
follows GitHub's attestation API, use the canonical image reference instead:

```bash
gh attestation verify oci://ghcr.io/tektum/caddy:latest --repo tektum/verity-images
```
