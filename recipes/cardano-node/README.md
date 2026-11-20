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

The Preview database occupied roughly 16 GB in the November 2026 validation
run. Allow additional space for downloads, Nix dependencies, logs and database
growth; this measurement is not a fixed disk requirement.

To sync from genesis without a Mithril download:

```sh
SKIP_MITHRIL=true nix run .#cardano-node
```

An existing `state/cardano-node/db` is reused either way. To use a node that is
already running elsewhere, use [existing-node](../existing-node/README.md).

`wait-for-fuel` waits while `credentials/cardano.addr` has no UTxO. Fund
`credentials/funds.addr`, then select `distribute` and press F7 to send half of
it to the fuel address, or run this in another terminal:

```sh
just distribute cardano-node
```

Once Hydra starts, select `hydra-tui` and press **F7**. Follow
[Using a head](../../README.md#using-a-head) for deposits, transfers, closing
and fanout.

## Configure

`config/hydra-node.yaml` and `peers/`, see the root README. The node configuration
and topology for `NETWORK` come from the cardano-node flake.

For a solo head, use `peers: []`, set `listen` to `127.0.0.1:5001` and remove
the example `advertise` address. This recipe can run a solo head without
Blockfrost; the separately named `single-party` recipe uses Blockfrost.

## Background operation

Run these commands from the repository root:

```sh
nix run .#cardano-node -- --detached --tui=false
nix run .#cardano-node -- attach
```

In process-compose, select `hydra-tui` and press F7. To stop the background
recipe, keeping its database, keys and head persistence:

```sh
nix run .#cardano-node -- down
```

Run the detached start command again to resume.

## Verify returned funds

After `HeadIsFinalized`, use the project's development environment
(`nix develop`) to query the synced node. The following commands use Preview;
use the network magic from `config/env` if you changed networks:

```sh
cardano-cli query tip --socket-path state/cardano-node/node.socket --testnet-magic 2
cardano-cli query utxo \
  --socket-path state/cardano-node/node.socket --testnet-magic 2 \
  --address "$(cat credentials/funds.addr)" \
  --out-file state/cardano-node/returned-funds-utxo.json
jq '[.[].value.lovelace] | add // 0' state/final-head-utxo.json
jq '[.[].value.lovelace] | add // 0' state/cardano-node/returned-funds-utxo.json
```

The first file is the snapshot saved before closing in the shared instructions.
Values are in lovelace (1,000,000 lovelace = 1 ada). For a solo head where you
deposited all funds and only sent to yourself, the totals should match exactly,
provided there were no unrelated payments or subsequent spends. Also compare
individual outputs and the closed snapshot number as described there. Query
other recipients separately if funds were sent to other addresses.

To save API events for checking deposit progress, snapshot numbers and
finalization, run this in the development environment:

```sh
jq -Rc 'fromjson? | .message | fromjson? | .message.api.sentOutput? // empty' \
  state/cardano-node/logs/hydra-node.log > state/cardano-node/api-events.jsonl
```

Repeat after fanout to include `HeadIsFinalized` and its layer 1 output IDs.

## State

`state/cardano-node/{db,node.socket,persistence,logs}`.
