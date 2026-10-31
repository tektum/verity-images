ARG BASE=scratch
FROM ${BASE}

ARG NPM_VERSION=12.0.2 # renovate: datasource=npm depName=npm
ARG IP_ADDRESS_VERSION=10.7.4 # renovate: datasource=npm depName=ip-address
ARG UNDICI_VERSION=6.29.1 # renovate: datasource=npm depName=undici
ARG BRACE_EXPANSION_VERSION=5.0.12 # renovate: datasource=npm depName=brace-expansion
ARG POSTCSS_SELECTOR_PARSER_VERSION=7.1.6 # renovate: datasource=npm depName=postcss-selector-parser
ARG TAR_VERSION=7.5.22 # renovate: datasource=npm depName=tar
ARG GLOB_VERSION=14.0.3 # renovate: datasource=npm depName=glob
ARG MINIMATCH_VERSION=11.0.3 # renovate: datasource=npm depName=minimatch
ARG PATH_SCURRY_VERSION=3.0.0 # renovate: datasource=npm depName=path-scurry
ARG NONRECURSIVE_GLOB_MATCH_VERSION=1.0.3 # renovate: datasource=npm depName=@isaacs/nonrecursive-glob-match

RUN set -eux; \
    tmp="$(mktemp -d)"; \
    export npm_config_cache="$tmp/cache"; \
    npm install --global "npm@${NPM_VERSION}" --ignore-scripts; \
    npm_dir="$(npm root --global)/npm"; \
    npm pack --ignore-scripts --silent --pack-destination "$tmp" \
      "ip-address@${IP_ADDRESS_VERSION}" "undici@${UNDICI_VERSION}" \
      "brace-expansion@${BRACE_EXPANSION_VERSION}" \
      "postcss-selector-parser@${POSTCSS_SELECTOR_PARSER_VERSION}" \
      "tar@${TAR_VERSION}" "glob@${GLOB_VERSION}" \
      "minimatch@${MINIMATCH_VERSION}" "path-scurry@${PATH_SCURRY_VERSION}" \
      "@isaacs/nonrecursive-glob-match@${NONRECURSIVE_GLOB_MATCH_VERSION}"; \
    for spec in \
      "ip-address ${IP_ADDRESS_VERSION}" \
      "undici ${UNDICI_VERSION}" \
      "brace-expansion ${BRACE_EXPANSION_VERSION}" \
      "postcss-selector-parser ${POSTCSS_SELECTOR_PARSER_VERSION}" \
      "tar ${TAR_VERSION}" \
      "glob ${GLOB_VERSION}" \
      "minimatch ${MINIMATCH_VERSION}" \
      "path-scurry ${PATH_SCURRY_VERSION}" \
      "@isaacs/nonrecursive-glob-match ${NONRECURSIVE_GLOB_MATCH_VERSION}"; do \
      set -- $spec; \
      rm -rf "$npm_dir/node_modules/$1"; \
      mkdir -p "$npm_dir/node_modules/$1"; \
      tgz="$tmp/$(printf '%s' "${1#@}" | tr / -)-$2.tgz"; \
      tar -xzf "$tgz" --strip-components=1 -C "$npm_dir/node_modules/$1"; \
      test "$(node -p "require('$npm_dir/node_modules/$1/package.json').version")" = "$2"; \
    done; \
    test "$(npm --version)" = "${NPM_VERSION}"; \
    rm -rf "$tmp"
