#!/bin/bash
set -euo pipefail

track=${1:?usage: install_image_tools.sh TRACK}

if [[ "$track" == apk ]]; then
  case "$(uname -m)" in
    x86_64)
      melange_arch=amd64
      melange_sha256=40e17d259c9fd7bce8e000a59239d7b9ebf13971117334ad117ae6eefd98f92b
      ;;
    aarch64)
      melange_arch=arm64
      melange_sha256=3b8565a5d924df0a7a7e61895f62972017f5613bead2d45218e0e4d47f7601c1
      ;;
    *)
      printf 'unsupported APK build architecture: %s\n' "$(uname -m)" >&2
      exit 2
      ;;
  esac
  melange_archive="melange_${MELANGE_VERSION}_linux_${melange_arch}.tar.gz"
  curl -fsSL "https://github.com/chainguard-dev/melange/releases/download/v${MELANGE_VERSION}/${melange_archive}" \
    -o "/tmp/${melange_archive}"
  printf '%s  %s\n' "$melange_sha256" "/tmp/${melange_archive}" | sha256sum --check
  tar -xzf "/tmp/${melange_archive}" -C /tmp
  sudo install "/tmp/melange_${MELANGE_VERSION}_linux_${melange_arch}/melange" /usr/local/bin/melange
  exit
fi

grype_url="https://github.com/anchore/grype/releases/download/v${GRYPE_VERSION}"
curl -fsSL "${grype_url}/grype_${GRYPE_VERSION}_linux_amd64.tar.gz" -o /tmp/grype.tar.gz
printf '%s  %s\n' "$GRYPE_SHA256" /tmp/grype.tar.gz | sha256sum --check
tar -xzf /tmp/grype.tar.gz -C /tmp
sudo install /tmp/grype /usr/local/bin/grype

if [[ "$track" == wolfi ]]; then
  melange_sha256=${MELANGE_SHA256:?MELANGE_SHA256 is required for the Wolfi track}
  archive="apko_${APKO_VERSION}_linux_amd64.tar.gz"
  curl -fsSL "https://github.com/chainguard-dev/apko/releases/download/v${APKO_VERSION}/${archive}" \
    -o "/tmp/${archive}"
  printf '%s  %s\n' "$APKO_SHA256" "/tmp/${archive}" | sha256sum --check
  tar -xzf "/tmp/${archive}" -C /tmp
  melange_archive="melange_${MELANGE_VERSION}_linux_amd64.tar.gz"
  curl -fsSL "https://github.com/chainguard-dev/melange/releases/download/v${MELANGE_VERSION}/${melange_archive}" \
    -o "/tmp/${melange_archive}"
  printf '%s  %s\n' "$melange_sha256" "/tmp/${melange_archive}" | sha256sum --check
  tar -xzf "/tmp/${melange_archive}" -C /tmp
  sudo install "/tmp/apko_${APKO_VERSION}_linux_amd64/apko" /usr/local/bin/apko
  sudo install "/tmp/melange_${MELANGE_VERSION}_linux_amd64/melange" /usr/local/bin/melange
  exit
fi

if [[ "$track" != patched ]]; then
  printf 'unsupported track: %s\n' "$track" >&2
  exit 2
fi

syft_url="https://github.com/anchore/syft/releases/download/v${SYFT_VERSION}"
curl -fsSL "${syft_url}/syft_${SYFT_VERSION}_linux_amd64.tar.gz" -o /tmp/syft.tar.gz
printf '%s  %s\n' "$SYFT_SHA256" /tmp/syft.tar.gz | sha256sum --check
tar -xzf /tmp/syft.tar.gz -C /tmp

copa_url="https://github.com/project-copacetic/copacetic/releases/download/v${COPA_VERSION}"
trivy_url="https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}"
curl -fsSL "${copa_url}/copa_${COPA_VERSION}_linux_amd64.tar.gz" -o /tmp/copa.tar.gz
curl -fsSL "${trivy_url}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz" -o /tmp/trivy.tar.gz
printf '%s  %s\n' "$COPA_SHA256" /tmp/copa.tar.gz | sha256sum --check
printf '%s  %s\n' "$TRIVY_SHA256" /tmp/trivy.tar.gz | sha256sum --check
tar -xzf /tmp/copa.tar.gz -C /tmp
tar -xzf /tmp/trivy.tar.gz -C /tmp
sudo install /tmp/copa /tmp/trivy /tmp/syft /usr/local/bin/
