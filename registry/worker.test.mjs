import assert from "node:assert/strict";
import test from "node:test";
import worker, { cacheLifetime, parseArtifactRoute } from "./worker.mjs";

test("parseArtifactRoute maps an alias manifest request to the Tektum GHCR namespace", () => {
  assert.deepEqual(parseArtifactRoute("/v2/caddy/manifests/latest"), {
    aliasRepository: "caddy",
    suffix: "/manifests/latest",
  });
});

test("parseArtifactRoute permits OCI referrer discovery but blocks canonical namespace aliases", () => {
  assert.deepEqual(
    parseArtifactRoute(`/v2/caddy/referrers/${"sha256:" + "a".repeat(64)}`),
    {
      aliasRepository: "caddy",
      suffix: `/referrers/${"sha256:" + "a".repeat(64)}`,
    }
  );
  assert.equal(parseArtifactRoute("/v2/tektum/caddy/manifests/latest"), null);
});

test("cacheLifetime retains tokens with short expiry windows", () => {
  assert.equal(cacheLifetime(10_000), 1_000);
  assert.equal(cacheLifetime(300_000), 240_000);
});

test("worker proxies alias manifests with a namespaced GHCR token", async () => {
  const fetch = globalThis.fetch;
  const calls = [];
  globalThis.fetch = async (input, init = {}) => {
    calls.push({ url: String(input), init });
    if (String(input).startsWith("https://ghcr.io/token?")) {
      return Response.json({ token: "pull-token", expires_in: 300 });
    }
    return new Response("manifest", { headers: { "Docker-Content-Digest": "sha256:test" } });
  };

  try {
    const response = await worker.fetch(
      new Request("https://verity.supply/v2/caddy/manifests/latest", {
        headers: { Authorization: "Bearer client-token", Accept: "application/vnd.oci.image.manifest.v1+json" },
      })
    );

    assert.equal(response.status, 200);
    assert.equal(await response.text(), "manifest");
    assert.equal(calls.length, 2);
    assert.match(calls[0].url, /scope=repository%3Atektum%2Fcaddy%3Apull/);
    assert.equal(calls[1].url, "https://ghcr.io/v2/tektum/caddy/manifests/latest");
    assert.equal(calls[1].init.headers.get("Authorization"), "Bearer pull-token");
    assert.equal(calls[1].init.headers.get("Accept"), "application/vnd.oci.image.manifest.v1+json");
  } finally {
    globalThis.fetch = fetch;
  }
});

test("worker forwards HEAD upstream and returns a bodyless manifest response", async () => {
  const fetch = globalThis.fetch;
  const calls = [];
  globalThis.fetch = async (input, init = {}) => {
    calls.push({ url: String(input), init });
    if (String(input).startsWith("https://ghcr.io/token?")) {
      return Response.json({ token: "pull-token", expires_in: 300 });
    }
    return new Response("manifest", { headers: { "Docker-Content-Digest": "sha256:test" } });
  };

  try {
    const response = await worker.fetch(
      new Request("https://verity.supply/v2/caddy-head/manifests/latest", { method: "HEAD" })
    );

    assert.equal(response.status, 200);
    assert.equal(await response.text(), "");
    assert.equal(calls[1].init.method, "HEAD");
    assert.equal(response.headers.get("Docker-Content-Digest"), "sha256:test");
  } finally {
    globalThis.fetch = fetch;
  }
});

// Records only registry calls; the token exchange is cached per repository across tests.
async function withUpstream(handler, run) {
  const fetch = globalThis.fetch;
  const calls = [];
  globalThis.fetch = async (input, init = {}) => {
    if (String(input).startsWith("https://ghcr.io/token?")) {
      return Response.json({ token: "pull-token", expires_in: 300 });
    }
    calls.push({ url: String(input), init });
    return handler(String(input), init);
  };
  try {
    return await run(calls);
  } finally {
    globalThis.fetch = fetch;
  }
}

const tagsUpstream = () =>
  Response.json(
    { name: "tektum/caddy", tags: ["2.11.7-fips"] },
    { headers: { Link: '</v2/tektum/caddy/tags/list?last=2.11.7-fips&n=1>; rel="next"' } }
  );

test("parseArtifactRoute maps tags/list and blocks reserved namespaces", () => {
  assert.deepEqual(parseArtifactRoute("/v2/caddy/tags/list"), {
    aliasRepository: "caddy",
    suffix: "/tags/list",
  });
  assert.equal(parseArtifactRoute("/v2/tektum/caddy/tags/list"), null);
  assert.equal(parseArtifactRoute("/v2/charts/caddy/tags/list"), null);
});

test("worker lists tags under the alias name without forwarding client credentials", async () => {
  await withUpstream(tagsUpstream, async (calls) => {
    const response = await worker.fetch(
      new Request("https://verity.supply/v2/caddy/tags/list", { headers: { Authorization: "Bearer client-token" } })
    );

    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { name: "caddy", tags: ["2.11.7-fips"] });
    assert.equal(calls[0].url, "https://ghcr.io/v2/tektum/caddy/tags/list");
    assert.equal(calls[0].init.method, "GET");
    assert.equal(calls[0].init.headers.get("Authorization"), "Bearer pull-token");
  });
});

test("worker passes n and last through and rewrites the next link to the requested host", async () => {
  await withUpstream(tagsUpstream, async (calls) => {
    const response = await worker.fetch(
      new Request("https://verity.supply/v2/caddy/tags/list?n=1&last=2.11.4-fips&other=x")
    );

    assert.equal(calls[0].url, "https://ghcr.io/v2/tektum/caddy/tags/list?n=1&last=2.11.4-fips");
    assert.equal(
      response.headers.get("Link"),
      '<https://verity.supply/v2/caddy/tags/list?n=1&last=2.11.7-fips>; rel="next"'
    );
    assert.doesNotMatch(JSON.stringify([...response.headers]), /ghcr\.io|tektum/);
  });
});

test("worker drops a next link that does not point at the listed repository", async () => {
  await withUpstream(
    () => Response.json({ name: "tektum/caddy", tags: [] }, { headers: { Link: '<https://evil.example/x?n=1>; rel="next"' } }),
    async () => {
      const response = await worker.fetch(new Request("https://verity.supply/v2/caddy/tags/list"));
      assert.equal(response.headers.get("Link"), null);
      assert.deepEqual(await response.json(), { name: "caddy", tags: [] });
    }
  );
});

test("worker answers HEAD on tags/list with GET upstream and no body", async () => {
  await withUpstream(tagsUpstream, async (calls) => {
    const response = await worker.fetch(new Request("https://verity.supply/v2/caddy/tags/list", { method: "HEAD" }));

    assert.equal(response.status, 200);
    assert.equal(await response.text(), "");
    assert.equal(calls[0].init.method, "GET");
    assert.equal(
      response.headers.get("Content-Length"),
      String(JSON.stringify({ name: "caddy", tags: ["2.11.7-fips"] }).length)
    );
  });
});

test("worker rejects reserved namespaces on tags/list without calling upstream", async () => {
  await withUpstream(tagsUpstream, async (calls) => {
    const response = await worker.fetch(new Request("https://verity.supply/v2/tektum/caddy/tags/list"));
    assert.equal(response.status, 404);
    assert.equal(calls.length, 0);
  });
});

test("worker returns 404 for an unknown repository when GHCR denies the listing", async () => {
  await withUpstream(
    () => Response.json({ errors: [{ code: "DENIED", message: "invalid token" }] }, { status: 403 }),
    async () => {
      const response = await worker.fetch(new Request("https://verity.supply/v2/does-not-exist/tags/list"));
      assert.equal(response.status, 404);
      assert.equal((await response.json()).errors[0].code, "NAME_UNKNOWN");
    }
  );
});

test("worker returns 404 for an unknown repository when GHCR refuses the anonymous token", async () => {
  const original = globalThis.fetch;
  globalThis.fetch = async () => Response.json({ errors: [{ code: "DENIED" }] }, { status: 403 });
  try {
    for (const method of ["GET", "HEAD"]) {
      const response = await worker.fetch(new Request("https://verity.supply/v2/no-such-image/tags/list", { method }));
      assert.equal(response.status, 404);
    }
  } finally {
    globalThis.fetch = original;
  }
});