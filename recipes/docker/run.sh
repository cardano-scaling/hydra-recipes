#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
HOST_UID=$(id -u)
HOST_GID=$(id -g)
export HOST_UID HOST_GID

compose() {
  docker compose --env-file .env --env-file ../../config/env "$@"
}

case "${1:-}" in
keys)
  # shellcheck disable=SC1091
  . .env
  cd ../..
  run="docker run --rm -u $HOST_UID:$HOST_GID -v $PWD:/work -w /work"
  HYDRA_NODE="$run $HYDRA_NODE_IMAGE" \
    CARDANO_CLI="$run --entrypoint cardano-cli $CARDANO_NODE_IMAGE" \
    scripts/gen-keys.sh
  ;;
up)
  mkdir -p ../../state/docker/{data,ipc,logs,persistence}
  compose up -d
  ;;
distribute) compose run --rm funding distribute --node-socket /ipc/node.socket ;;
tui) compose run --rm hydra-tui ;;
logs)
  shift
  compose logs -f "$@"
  ;;
cli)
  shift
  compose exec cardano-node cardano-cli "$@"
  ;;
down) compose down ;;
*)
  echo "usage: $0 keys | up | distribute | tui | logs [service] | cli args | down" >&2
  exit 1
  ;;
esac
