ARG BASE=scratch
FROM ${BASE}

RUN set -eux; \
    tmp="$(mktemp -d)"; \
    export npm_config_cache="$tmp/cache"; \
    npm install --global "npm@12.0.2" --ignore-scripts; \
    npm_dir="$(npm root --global)/npm"; \
    npm pack --ignore-scripts --silent --pack-destination "$tmp" \
      "ip-address@10.3.1" "undici@6.28.0"; \
    rm -rf "$npm_dir/node_modules/ip-address" "$npm_dir/node_modules/undici"; \
    mkdir -p "$npm_dir/node_modules/ip-address" "$npm_dir/node_modules/undici"; \
    tar -xzf "$tmp/ip-address-10.3.1.tgz" \
      --strip-components=1 -C "$npm_dir/node_modules/ip-address"; \
    tar -xzf "$tmp/undici-6.28.0.tgz" \
      --strip-components=1 -C "$npm_dir/node_modules/undici"; \
    test "$(npm --version)" = "12.0.2"; \
    test "$(node -p "require('$npm_dir/node_modules/ip-address/package.json').version")" = "10.3.1"; \
    test "$(node -p "require('$npm_dir/node_modules/undici/package.json').version")" = "6.28.0"; \
    rm -rf "$tmp"
