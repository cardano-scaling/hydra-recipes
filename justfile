alias k := keys
alias c := check

[private]
default:
  @just --list

# generate hydra and cardano keys into credentials/, once
keys:
  nix run .#gen-keys

# send half of credentials/funds.addr to the fuel address, e.g. `just distribute cardano-node`
distribute RECIPE:
  #!/usr/bin/env bash
  set -euo pipefail
  case "{{RECIPE}}" in
  cardano-node) nix run .#distribute -- --node-socket state/cardano-node/node.socket ;;
  existing-node) nix run .#distribute -- --node-socket "${CARDANO_NODE_SOCKET_PATH:?set CARDANO_NODE_SOCKET_PATH}" ;;
  blockfrost | single-party) nix run .#distribute -- --blockfrost credentials/blockfrost-project.txt ;;
  docker) recipes/docker/run.sh distribute ;;
  *)
    echo "unknown recipe: {{RECIPE}}" >&2
    exit 1
    ;;
  esac

# a head with you as the only participant, over Blockfrost
single-party:
  nix run .#single-party

# hydra-node and hydra-tui over Blockfrost
blockfrost:
  nix run .#blockfrost

# local cardano-node bootstrapped with Mithril, then hydra-node and hydra-tui
cardano-node:
  nix run .#cardano-node

# use an existing node; export CARDANO_NODE_SOCKET_PATH first
existing-node:
  nix run .#existing-node

# generate keys with the docker images, instead of `just keys`
docker-keys:
  recipes/docker/run.sh keys

# bootstrap if needed, then start cardano-node and hydra-node in the background
docker-up:
  recipes/docker/run.sh up

# open the TUI against the docker hydra-node
docker-tui:
  recipes/docker/run.sh tui

# follow the docker logs, optionally for one service, e.g. `just docker-logs hydra-node`
docker-logs *SERVICE:
  recipes/docker/run.sh logs {{SERVICE}}

# run cardano-cli in the docker cardano-node, e.g. `just docker-cli query tip --testnet-magic 2`
docker-cli +ARGS:
  recipes/docker/run.sh cli {{ARGS}}

# stop the docker stack, keeping state/docker/
docker-down:
  recipes/docker/run.sh down

# effective hydra-node configuration with resolved paths
config:
  curl -s localhost:4001/config | jq

# connected peers and head state
metrics:
  curl -s localhost:6001/metrics

# run the nix checks, as CI does
check:
  nix flake check -L

# build every recipe, as CI does
build:
  nix build -L .#single-party .#blockfrost .#cardano-node .#existing-node .#gen-keys .#distribute .#test-lifecycle

# two real Hydra peers on a disposable Cardano devnet; pass --docker-peer on Linux to mix recipes
test-lifecycle *ARGS:
  nix run .#test-lifecycle -- {{ARGS}}

# format nix and shell files
fmt:
  nix fmt
