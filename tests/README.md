# Validation

## Funding regression tests

`nix flake check` runs `funding.sh` against fixture node and Blockfrost responses
with a restricted PATH. The tests check that distribution accounts for its fee,
splits odd balances within one lovelace, leaves token-bearing inputs alone,
handles more than 100 Blockfrost UTxOs, rejects insufficient funds and backend
errors, and releases the startup gate once fuel arrives.

CI also runs the same suite inside the pinned Cardano Docker image. Only its
existing Bash, jq and coreutils are needed. These are adapter regression tests;
they do not contact Blockfrost or replace the real transaction test below.

## Real two-peer lifecycle

```sh
nix run .#test-lifecycle
# Linux with Docker: Alice uses existing-node, Bob uses the Docker recipe.
nix run .#test-lifecycle -- --docker-peer --output-dir state/validation/mixed
```

The test starts a private Cardano devnet with network magic 42 using the fixtures
from the pinned Hydra input. It generates disposable participant credentials,
seeds their funds addresses from that devnet's public faucet fixture, publishes
Hydra scripts and runs the repository's funding script to create fuel.

Two participants then initialize a head, deposit funds, agree on its UTxO,
restart and recover it, close it, wait for the contestation period and fan out.
The test verifies that both participants observe the same head and that the
committed ada returns to their layer 1 addresses. Hydra 2.4 opens an empty head
on `Init`; `/commit` deposits into the open head.

The default uses two `existing-node` processes. `--docker-peer` uses the existing
Compose services for Bob's funding and Hydra node, with a test override for the
devnet socket and host networking. The external Cardano devnet is already ready,
so that variant uses `--no-deps` and does not run the managed-node/Mithril startup
chain. It requires Linux and a working Docker daemon.

Each run stores `result.json`, version information, timestamped phases, transaction
IDs, WebSocket events and process logs in its output directory. CI uploads these
as `lifecycle-evidence`. A failed run writes a failed report and exits nonzero;
absence of credentials or Docker is never reported as a successful test.

The test workspace is temporary and cleaned up on exit. Existing repository
credentials and chain databases are not used. There are no public-network
transactions and no faucet or Blockfrost credentials are required.

## Remaining external validation

A successful devnet run proves the local protocol workflow. It does not establish
public Preview/Preprod connectivity, Mithril snapshot availability, live
Blockfrost behavior or ARM/macOS compatibility. Live Blockfrost validation is
deferred until a project ID is available. Run a public-network acceptance test
and retain its evidence before claiming those environments have been validated.
