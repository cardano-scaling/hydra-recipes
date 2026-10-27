# hydra-recipes

Ready-to-run ways of operating a [hydra-node](https://github.com/cardano-scaling/hydra)
on the Cardano testnets. Shared configuration for peers, networks and credentials,
plus a separate peer-free configuration for the single-party example.

## Prerequisites

- Nix with flakes, or Docker with compose v2 for the docker recipe
- A port your peers can reach, 5001 by default

## Quickstart

1. Generate keys: `nix run .#gen-keys` (docker only: `recipes/docker/run.sh keys`)
2. Fund `credentials/funds.addr` once at <https://docs.cardano.org/cardano-testnets/tools/faucet>
3. For a multi-party head, edit `config/hydra-node.yaml` and put each peer's
   `hydra.vk` and `cardano.vk` in `peers/<name>/`. `single-party` uses its own
   configuration and needs no peer edits.
4. Run a recipe. It waits for fuel before starting `hydra-node`: run the
   distribute step from [Funding](#funding) and it carries on.

`just` lists these and the other entrypoints.

## Recipes

| Recipe         | Layer 1                       | Run                       | Needs                                           |
| -------------- | ----------------------------- | ------------------------- | ----------------------------------------------- |
| `single-party` | Blockfrost                    | `nix run .#single-party`  | `credentials/blockfrost-project.txt`, no peers  |
| `blockfrost`   | Blockfrost                    | `nix run .#blockfrost`    | `credentials/blockfrost-project.txt`            |
| `cardano-node` | local node, Mithril bootstrap | `nix run .#cardano-node`  | disk space and sync time                        |
| `existing-node` | your running Cardano node    | `nix run .#existing-node` | `CARDANO_NODE_SOCKET_PATH`, matching network    |
| `docker`       | local node, Mithril bootstrap | `recipes/docker/run.sh up`| docker, no nix                                  |

The nix recipes run in process-compose. Select `hydra-tui` and press F7 to open the TUI.

To reuse a running node, set `CARDANO_NODE_SOCKET_PATH` to its absolute socket
path and select `existing-node`; see [its guide](recipes/existing-node/README.md).
To sync a new managed node from genesis, set `SKIP_MITHRIL=true` when launching
`cardano-node` or Docker. Both managed recipes also reuse an existing database.

## Funding

`hydra-node` pays for `Init`, `Close` and the other layer 1 transactions from
its own wallet, the key behind `credentials/cardano.addr`. The ada there is
**fuel**. `credentials/funds.addr` holds the ada you commit, the **funds**.
Only the funds address needs a faucet request. The distribute step sends half
of it to the fuel address:

| Recipe                       | Distribute                                                                                  |
| ---------------------------- | ------------------------------------------------------------------------------------------- |
| `single-party`, `blockfrost` | `nix run .#distribute -- --blockfrost credentials/blockfrost-project.txt`                   |
| `cardano-node`               | the `distribute` process in process-compose (select it, press F7), needs the synced node    |
| `existing-node`              | `nix run .#distribute -- --node-socket "$CARDANO_NODE_SOCKET_PATH"`                         |
| `docker`                     | `recipes/docker/run.sh distribute`                                                          |

Or `just distribute <recipe>`. Every recipe checks the fuel address before
starting `hydra-node` and waits, printing both addresses, while it is empty.
Run distribute again when fuel runs low: it always splits what is at the funds
address evenly, using its ada-only UTxOs.

## Configuration

- `config/hydra-node.yaml`: used by `blockfrost`, `cardano-node`, `existing-node`
  and `docker`. `single-party` uses `recipes/single-party/hydra-node.yaml` instead.
  Paths are relative to `config/`. Reference:
  <https://hydra.family/head-protocol/docs/configuration#yaml-configuration-file>
- `config/env`: `NETWORK` and `NETWORK_MAGIC` (preview 2, preprod 1). Switching
  network needs matching credentials and separate chain/head state. The recipes
  are configured for preview and preprod; mainnet is outside this quickstart.
- `config/protocol-parameters.json`: the ledger parameters inside the head.
  All peers must use the same file.
- `credentials/`: your keys, never committed. `blockfrost-project.txt` holds a
  Blockfrost project id for the network in `config/env`.
- `peers/<name>/`: a peer's `hydra.vk` and `cardano.vk`. Send yours from
  `credentials/`. All peers must use the same contestation and deposit periods.

## Upgrading

1. Change the versions in `flake.nix` and `recipes/docker/.env`. Mithril's Docker
   tag includes the release and short commit hash; update the verification-key
   commit in `recipes/docker/mithril.sh` to the same release.
2. `nix flake lock`
3. Check the [release notes](https://github.com/cardano-scaling/hydra/releases) for
   changed flags. CI checks that `config/hydra-node.yaml` still loads.

## Validation

`nix flake check` runs formatting, shell checks and funding regression tests.
`nix run .#test-lifecycle` runs two real Hydra nodes against a disposable Cardano
devnet, checks funding, opening, deposits, restart recovery, closing and fanout,
and records the result under `state/validation/lifecycle/`.

On Linux with Docker, `nix run .#test-lifecycle -- --docker-peer` runs one
`existing-node` participant and one participant from the Docker recipe. CI runs
both variants. Neither uses your credentials, a faucet or a Blockfrost token.
See [tests/README.md](tests/README.md) for coverage and evidence limits.

## Troubleshooting

- `curl -s localhost:4001/config | jq` shows the effective configuration with resolved paths.
- `curl -s localhost:6001/metrics` shows connected peers and the head state.
- `PostTxOnChainFailed` with `NoSeedInput` on `Init`: the fuel address has no
  UTxO. Run the distribute step, see [Funding](#funding).
- Logs: `state/<recipe>/logs/` for nix, `recipes/docker/run.sh logs` for docker.
- Delete `state/<recipe>/` to start over. The chain database is in there too.
