#!/bin/bash
set -euo pipefail

track=${1:?usage: install_image_tools.sh TRACK}

if [[ "$track" == wolfi ]]; then
  archive="apko_${APKO_VERSION}_linux_amd64.tar.gz"
  curl -fsSL "https://github.com/chainguard-dev/apko/releases/download/v${APKO_VERSION}/${archive}" \
    -o "/tmp/${archive}"
  printf '%s  %s\n' "$APKO_SHA256" "/tmp/${archive}" | sha256sum --check
  tar -xzf "/tmp/${archive}" -C /tmp
  sudo install "/tmp/apko_${APKO_VERSION}_linux_amd64/apko" /usr/local/bin/apko
  exit
fi

copa_url="https://github.com/project-copacetic/copacetic/releases/download/v${COPA_VERSION}"
trivy_url="https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}"
syft_url="https://github.com/anchore/syft/releases/download/v${SYFT_VERSION}"
grype_url="https://github.com/anchore/grype/releases/download/v${GRYPE_VERSION}"
curl -fsSL "${copa_url}/copa_${COPA_VERSION}_linux_amd64.tar.gz" -o /tmp/copa.tar.gz
curl -fsSL "${trivy_url}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz" -o /tmp/trivy.tar.gz
curl -fsSL "${syft_url}/syft_${SYFT_VERSION}_linux_amd64.tar.gz" -o /tmp/syft.tar.gz
curl -fsSL "${grype_url}/grype_${GRYPE_VERSION}_linux_amd64.tar.gz" -o /tmp/grype.tar.gz
printf '%s  %s\n' "$COPA_SHA256" /tmp/copa.tar.gz | sha256sum --check
printf '%s  %s\n' "$TRIVY_SHA256" /tmp/trivy.tar.gz | sha256sum --check
printf '%s  %s\n' "$SYFT_SHA256" /tmp/syft.tar.gz | sha256sum --check
printf '%s  %s\n' "$GRYPE_SHA256" /tmp/grype.tar.gz | sha256sum --check
tar -xzf /tmp/copa.tar.gz -C /tmp
tar -xzf /tmp/trivy.tar.gz -C /tmp
tar -xzf /tmp/syft.tar.gz -C /tmp
tar -xzf /tmp/grype.tar.gz -C /tmp
sudo install /tmp/copa /tmp/trivy /tmp/syft /tmp/grype /usr/local/bin/
