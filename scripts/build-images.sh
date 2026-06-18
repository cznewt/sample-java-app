#!/usr/bin/env bash
# Build the three SpringBoot service images (multi-stage; agents baked in).
# The builder stage compiles all jars once and is cached across the 3 images.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKERFILE="$REPO_ROOT/docker/Dockerfile"
TAG="${TAG:-0.1.0}"
export DOCKER_BUILDKIT=1

for app in front back reader; do
  echo "=================== building sre-${app}:${TAG} ==================="
  docker build -f "$DOCKERFILE" --build-arg "APP=${app}" \
    -t "localhost/sre-${app}:${TAG}" "$REPO_ROOT"
done

echo "=================== ALL BUILDS DONE ==================="
docker images | grep -E "sre-(front|back|reader)" || true
