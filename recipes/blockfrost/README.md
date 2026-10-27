# blockfrost

`hydra-node` and `hydra-tui` using Blockfrost instead of a local cardano-node.

## Run

```
nix run .#blockfrost
```

Select `hydra-tui` and press F7 to open the TUI.

`wait-for-fuel` runs first and waits while `credentials/cardano.addr` has no
UTxO. Fund `credentials/funds.addr`, then select `distribute` and press F7 to
send half of it to the fuel address.

## Configure

`config/hydra-node.yaml` and `peers/`, see the root README. Plus
`credentials/blockfrost-project.txt` with a project id for the network in
`config/env`.

## State

`state/blockfrost/persistence` and `state/blockfrost/logs`.
