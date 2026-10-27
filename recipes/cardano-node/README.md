# cardano-node

A local `cardano-node` bootstrapped with Mithril, then `hydra-node` and `hydra-tui`.

## Run

```
nix run .#cardano-node
```

Order: `mithril-bootstrap` (skipped when `state/cardano-node/db` exists),
`cardano-node`, `wait-for-sync`, `wait-for-fuel`, `hydra-node`, then `hydra-tui`
(select it and press F7). The first run downloads the chain database and takes
a while.

To sync from genesis without a Mithril download:

```sh
SKIP_MITHRIL=true nix run .#cardano-node
```

An existing `state/cardano-node/db` is reused either way. To use a node that is
already running elsewhere, use [existing-node](../existing-node/README.md).

`wait-for-fuel` waits while `credentials/cardano.addr` has no UTxO. Fund
`credentials/funds.addr`, then select `distribute` and press F7 to send half of
it to the fuel address.

## Configure

`config/hydra-node.yaml` and `peers/`, see the root README. The node configuration
and topology for `NETWORK` come from the cardano-node flake.

## State

`state/cardano-node/{db,node.socket,persistence,logs}`.
