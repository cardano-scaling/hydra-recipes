# single-party

A head with you as the only participant, using Blockfrost instead of a local
cardano-node. The quickest way to see a head open and close.

## Run

```
nix run .#single-party
```

Runs `hydra-node` with `hydra-node.yaml` from this folder, then `hydra-tui`
(select it and press F7). Follow [Using a head](../../README.md#using-a-head)
to initialize, deposit, transfer, close and fan out.

`wait-for-fuel` runs first and waits while `credentials/cardano.addr` has no
UTxO. Fund `credentials/funds.addr`, then select `distribute` and press F7 to
send half of it to the fuel address.

## Configure

`credentials/blockfrost-project.txt` with a project id for the network in
`config/env`. Nothing else: this recipe has its own `hydra-node.yaml` with no peers.

## State

`state/single-party/persistence` and `state/single-party/logs`.
