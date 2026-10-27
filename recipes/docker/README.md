# docker

The same stack as the `cardano-node` recipe, from the published images, no nix:
`mithril-client` (one-shot bootstrap), `cardano-node`, `funding` (waits for
fuel), `hydra-node`, `hydra-tui`.

## Run

```
./run.sh keys        # once, instead of nix run .#gen-keys
./run.sh up          # bootstrap if needed, start cardano-node and hydra-node
./run.sh distribute  # once credentials/funds.addr is funded: send half to the fuel address
./run.sh logs        # follow logs, or: ./run.sh logs hydra-node
./run.sh tui         # open the TUI
./run.sh cli query tip --testnet-magic 2
./run.sh down
```

`hydra-node` starts once the node is at the tip and `credentials/cardano.addr`
has a UTxO; `./run.sh logs funding` shows what it is waiting for. Without
`run.sh`, export `HOST_UID=$(id -u)` and `HOST_GID=$(id -g)`, then
`docker compose --env-file .env --env-file ../../config/env up -d`.

To sync from genesis without downloading a Mithril snapshot, run
`SKIP_MITHRIL=true ./run.sh up`. An existing `state/docker/data/db` is reused
either way. Mithril's image and verification-key revision are pinned to the
same release; snapshot selection still uses the latest available snapshot.

## Configure

`config/hydra-node.yaml` and `peers/`, see the root README. If you change the
`listen` port there, change the `5001:5001` mapping in `compose.yaml`. Ports 4001
(API) and 6001 (metrics) bind to 127.0.0.1 only. Image versions are in `.env`.

## State

`state/docker/{data,ipc,logs,persistence}`, owned by your user.

## Notes

`hydra-tui` is published for amd64 only; arm64 hosts need qemu binfmt.
Docker Desktop on macOS cannot share the node socket through a bind mount.
