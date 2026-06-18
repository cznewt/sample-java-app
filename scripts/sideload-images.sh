#!/usr/bin/env bash
# Sideload locally-built images into the single node's cri-o (containers-storage),
# so pods can run them with imagePullPolicy: IfNotPresent and no external registry.
set -euo pipefail
TAG="${TAG:-0.1.0}"
NODE="${NODE:-root@kube.monlab.newt.cz}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH="ssh -i ${SSH_KEY} -o BatchMode=yes -o StrictHostKeyChecking=accept-new"

echo ">> saving 3 images into one (deduped) archive and streaming to ${NODE} ..."
docker save "localhost/sre-front:${TAG}" "localhost/sre-back:${TAG}" "localhost/sre-reader:${TAG}" \
  | ${SSH} "${NODE}" "cat > /tmp/sre-all.tar"

echo ">> importing into cri-o ..."
${SSH} "${NODE}" "set -e; for a in front back reader; do \
    skopeo copy --quiet docker-archive:/tmp/sre-all.tar:localhost/sre-\$a:${TAG} containers-storage:localhost/sre-\$a:${TAG}; \
  done; echo '--- cri-o images ---'; crictl images | grep -E 'sre-(front|back|reader)'; rm -f /tmp/sre-all.tar"
echo ">> done"
