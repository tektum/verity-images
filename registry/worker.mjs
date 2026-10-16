const GHCR = "https://ghcr.io";
const GHCR_ORGANIZATION = "tektum";
const TOKEN_TTL_MS = 4 * 60 * 1000;
const TOKEN_REFRESH_SKEW_MS = 30 * 1000;
const MIN_TOKEN_CACHE_MS = 1_000;
const MAX_TOKEN_CACHE_ENTRIES = 64;

const tokenCache = new Map();
const repositoryPath = "[a-z0-9]+(?:[._-][a-z0-9]+)*(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)*";
const digest = "sha256:[a-f0-9]{64}";
const artifactPath = new RegExp(
  `^/v2/(${repositoryPath})(/(?:manifests/[^/]+|blobs/${digest}|referrers/${digest}|tags/list))$`
);
const forbiddenRepository = /^(?:charts|tektum)(?:\/|$)/;
const TAGS_LIST_SUFFIX = "/tags/list";
const tagsListQueryParameters = ["n", "last"];
const forwardedHeaders = ["accept", "if-modified-since", "if-none-match", "range"];

export default {
  async fetch(request) {
    if (request.method !== "GET" && request.method !== "HEAD") {
      return noStoreResponse("Method not allowed", 405, { Allow: "GET, HEAD" });
    }

    const url = new URL(request.url);
    if (url.pathname === "/v2" || url.pathname === "/v2/") {
      return registryRoot();
    }

    const route = parseArtifactRoute(url.pathname);
    if (!route) {
      return noStoreResponse("Not found", 404);
    }

    try {
      const token = await anonymousPullToken(`${GHCR_ORGANIZATION}/${route.aliasRepository}`);
      const isTagsList = route.suffix === TAGS_LIST_SUFFIX;
      const upstream = await fetch(
        `${GHCR}/v2/${GHCR_ORGANIZATION}/${route.aliasRepository}${route.suffix}${isTagsList ? tagsListSearch(url) : url.search}`,
        {
          // GHCR answers HEAD on tags/list with 405, so list with GET and drop the body for HEAD.
          method: isTagsList ? "GET" : request.method,
          headers: isTagsList
            ? new Headers({ Accept: "application/json", Authorization: `Bearer ${token}` })
            : upstreamRequestHeaders(request.headers, token),
          redirect: "manual",
          cf: { cacheTtl: 0, cacheEverything: false },
        }
      );
      if (isTagsList) {
        return await tagsListResponse(upstream, route.aliasRepository, url, request.method);
      }
      return noStoreUpstreamResponse(upstream, request.method);
    } catch (error) {
      if (route.suffix === TAGS_LIST_SUFFIX && isUnknownRepositoryStatus(error?.upstreamStatus)) {
        return unknownRepository();
      }
      console.error(JSON.stringify({
        event: "registry_proxy_error",
        message: error instanceof Error ? error.message : String(error),
        path: url.pathname,
      }));
      return noStoreResponse("Bad gateway", 502);
    }
  },
};

/** Return the alias repository and matching OCI distribution suffix, if supported. */
export function parseArtifactRoute(pathname) {
  const match = artifactPath.exec(pathname);
  const aliasRepository = match?.[1];
  const suffix = match?.[2];
  if (!aliasRepository || !suffix || forbiddenRepository.test(aliasRepository)) {
    return null;
  }
  return { aliasRepository, suffix };
}

/** Keep a short-lived cache entry even when GHCR returns an unusually short token TTL. */
export function cacheLifetime(expiresInMs) {
  return Math.max(MIN_TOKEN_CACHE_MS, Math.min(expiresInMs - TOKEN_REFRESH_SKEW_MS, TOKEN_TTL_MS));
}

function registryRoot() {
  return new Response(null, {
    status: 200,
    headers: {
      "Cache-Control": "no-store",
      "Docker-Distribution-API-Version": "registry/2.0",
    },
  });
}

function tagsListSearch(url) {
  const search = new URLSearchParams();
  for (const name of tagsListQueryParameters) {
    const value = url.searchParams.get(name);
    if (value !== null) {
      search.set(name, value);
    }
  }
  const query = search.toString();
  return query === "" ? "" : `?${query}`;
}

// GHCR denies the anonymous token (403) for repositories that do not exist.
function isUnknownRepositoryStatus(status) {
  return status === 401 || status === 403 || status === 404;
}

function unknownRepository() {
  return noStoreResponse(
    JSON.stringify({ errors: [{ code: "NAME_UNKNOWN", message: "repository name not known to registry" }] }),
    404,
    { "Content-Type": "application/json" }
  );
}

/** Rewrite a GHCR tag list to the alias name and a verity.supply pagination link. */
async function tagsListResponse(upstream, aliasRepository, url, requestMethod) {
  if (isUnknownRepositoryStatus(upstream.status)) {
    return unknownRepository();
  }
  if (!upstream.ok) {
    return noStoreUpstreamResponse(upstream, requestMethod);
  }

  const payload = await upstream.json();
  const body = JSON.stringify({
    name: aliasRepository,
    tags: Array.isArray(payload?.tags) ? payload.tags : [],
  });
  const headers = new Headers(upstream.headers);
  headers.delete("set-cookie");
  headers.delete("www-authenticate");
  headers.delete("link");
  headers.set("Cache-Control", "no-store");
  headers.set("Content-Type", "application/json");
  headers.set("Content-Length", String(new TextEncoder().encode(body).length));
  const next = nextTagsLink(upstream.headers.get("link"), aliasRepository, url);
  if (next) {
    headers.set("Link", next);
  }
  return new Response(requestMethod === "HEAD" ? null : body, { status: 200, headers });
}

/** Return GHCR's next-page link rebased onto the requested host and alias, or null. */
function nextTagsLink(link, aliasRepository, url) {
  const match = /^\s*<([^>]*)>\s*;\s*rel="?next"?\s*$/i.exec(link ?? "");
  if (!match) {
    return null;
  }
  const upstreamNext = new URL(match[1], GHCR);
  if (upstreamNext.origin !== GHCR || upstreamNext.pathname !== `/v2/${GHCR_ORGANIZATION}/${aliasRepository}${TAGS_LIST_SUFFIX}`) {
    return null;
  }
  const next = new URL(`/v2/${aliasRepository}${TAGS_LIST_SUFFIX}`, url.origin);
  next.search = tagsListSearch(upstreamNext);
  return `<${next}>; rel="next"`;
}

async function anonymousPullToken(repository) {
  const cached = tokenCache.get(repository);
  if (cached && cached.expiresAt > Date.now()) {
    return cached.token;
  }

  const tokenURL = new URL(`${GHCR}/token`);
  tokenURL.searchParams.set("service", "ghcr.io");
  tokenURL.searchParams.set("scope", `repository:${repository}:pull`);
  const response = await fetch(tokenURL, {
    headers: { Accept: "application/json" },
    redirect: "manual",
    cf: { cacheTtl: 0, cacheEverything: false },
  });
  if (!response.ok || response.status >= 300) {
    throw Object.assign(new Error(`GHCR token request failed with ${response.status}`), { upstreamStatus: response.status });
  }

  const payload = await response.json();
  const token = typeof payload.token === "string" ? payload.token : payload.access_token;
  if (typeof token !== "string" || token === "") {
    throw new Error("GHCR token response did not include a bearer token");
  }

  const expiresInMs = typeof payload.expires_in === "number" ? payload.expires_in * 1000 : TOKEN_TTL_MS;
  tokenCache.delete(repository);
  if (tokenCache.size >= MAX_TOKEN_CACHE_ENTRIES) {
    const oldestRepository = tokenCache.keys().next().value;
    if (typeof oldestRepository === "string") {
      tokenCache.delete(oldestRepository);
    }
  }
  tokenCache.set(repository, { token, expiresAt: Date.now() + cacheLifetime(expiresInMs) });
  return token;
}

function upstreamRequestHeaders(requestHeaders, token) {
  const headers = new Headers();
  for (const name of forwardedHeaders) {
    const value = requestHeaders.get(name);
    if (value) {
      headers.set(name, value);
    }
  }
  headers.set("Accept", headers.get("Accept") ?? "*/*");
  headers.set("Authorization", `Bearer ${token}`);
  return headers;
}

function noStoreUpstreamResponse(upstream, requestMethod) {
  const headers = new Headers(upstream.headers);
  headers.delete("set-cookie");
  headers.delete("www-authenticate");
  headers.set("Cache-Control", "no-store");
  return new Response(requestMethod === "HEAD" ? null : upstream.body, { status: upstream.status, headers });
}

function noStoreResponse(message, status, additionalHeaders = {}) {
  return new Response(message, {
    status,
    headers: {
      "Cache-Control": "no-store",
      "Content-Type": "text/plain; charset=utf-8",
      ...additionalHeaders,
    },
  });
}
