# existing-node

Run `hydra-node` and `hydra-tui` against a Cardano node you already operate.
This recipe does not start or stop that node, download a database, or use Mithril.

## Run

From the repository root:

```sh
export CARDANO_NODE_SOCKET_PATH=/absolute/path/to/node.socket
nix run .#existing-node
```

Set `NETWORK` and `NETWORK_MAGIC` in `config/env` to match the existing node.
Your user needs access to its socket. The recipe waits for sync and fuel before
starting Hydra. Fund `credentials/funds.addr`, then select `distribute` and press
F7, or run this in another terminal with the same socket variable:

```sh
nix run .#distribute -- --node-socket "$CARDANO_NODE_SOCKET_PATH"
```

Select `hydra-tui` and press F7 after Hydra starts. Peer configuration, keys and
protocol parameters are shared with the other multi-party recipes.

For a custom test network with scripts you published yourself, set
`HYDRA_SCRIPTS_TX_ID` to the comma-separated transaction IDs. This overrides the
prepublished scripts normally selected by `NETWORK`; the lifecycle test uses it
with the devnet's `NETWORK_MAGIC=42`.

## State

`state/existing-node/{persistence,logs}`. The Cardano database remains wherever
your existing node stores it.
