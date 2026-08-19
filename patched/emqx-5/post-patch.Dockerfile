ARG BASE=scratch
FROM ${BASE}
USER 0
RUN mkdir -p /var/lib/apt/lists/partial \
 && apt-get update \
 && apt-get install --no-install-recommends -y curl \
 && rm -rf /var/lib/apt/lists/*
USER emqx
