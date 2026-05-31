#!/usr/bin/env bash
set -euo pipefail

COMPOSE_VERSION="${COMPOSE_VERSION:-v2.29.7}"
BUILDX_VERSION="${BUILDX_VERSION:-v0.17.1}"

ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  x86_64)
    COMPOSE_ARCH="x86_64"
    BUILDX_ARCH="amd64"
    ;;
  aarch64|arm64)
    COMPOSE_ARCH="aarch64"
    BUILDX_ARCH="arm64"
    ;;
  *)
    echo "Unsupported architecture: $ARCH_RAW" >&2
    exit 1
    ;;
esac

PLUGIN_DIR="/usr/local/lib/docker/cli-plugins"

echo "Installing Docker Compose $COMPOSE_VERSION and Buildx $BUILDX_VERSION for $ARCH_RAW..."
sudo mkdir -p "$PLUGIN_DIR"

sudo curl -fL \
  "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-${COMPOSE_ARCH}" \
  -o "$PLUGIN_DIR/docker-compose"

sudo curl -fL \
  "https://github.com/docker/buildx/releases/download/${BUILDX_VERSION}/buildx-${BUILDX_VERSION}.linux-${BUILDX_ARCH}" \
  -o "$PLUGIN_DIR/docker-buildx"

sudo chmod +x "$PLUGIN_DIR/docker-compose" "$PLUGIN_DIR/docker-buildx"

echo
echo "Installed versions:"
docker compose version
docker buildx version

echo
echo "Done."
