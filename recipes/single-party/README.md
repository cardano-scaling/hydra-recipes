# single-party

A head with you as the only participant, using Blockfrost instead of a local
cardano-node. The quickest way to see a head open and close.

## Run

```
nix run .#single-party
```

Runs `hydra-node` with `hydra-node.yaml` from this folder, then `hydra-tui`
(select it and press F7). Initialize the head, deposit funds from the TUI, close,
wait for the contestation period, then fan out. Hydra 2.4 opens an empty head on
Init; deposits enter the already-open head.

`wait-for-fuel` runs first and waits while `credentials/cardano.addr` has no
UTxO. Fund `credentials/funds.addr`, then select `distribute` and press F7 to
send half of it to the fuel address.

## Configure

`credentials/blockfrost-project.txt` with a project id for the network in
`config/env`. Nothing else: this recipe has its own `hydra-node.yaml` with no peers.

## State

`state/single-party/persistence` and `state/single-party/logs`.
