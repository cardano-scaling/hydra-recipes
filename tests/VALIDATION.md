# Recorded validation

The following checks were recorded on 2026-10-26 on x86_64 Linux. A separate
manual Preview run on macOS ARM is recorded below. Re-run the relevant checks
after changing versions or recipe behavior; each record applies to its stated
platform, network and recipe.

| Check | Result |
| --- | --- |
| `nix flake check` | Passed: formatting, shell checks, funding regression tests and bootstrap skip/reuse checks |
| Build all four Nix recipes, `gen-keys`, `distribute`, `test-lifecycle` | Passed |
| Base Docker Compose configuration | Validated |
| Mixed-test Compose override and socket mounts | Validated |
| Real two-peer devnet lifecycle, including restart recovery | Passed |
| Competing deposit posts and fatal API error handling | Passed |
| Mixed Nix/Docker runtime | Awaiting CI/a Docker host; no Docker daemon was available locally |
| Live Blockfrost | Deferred; no project ID used |
| Public testnet, Mithril download, ARM/macOS | Not exercised by this run |

## Successful devnet run

- Started: 2026-10-26 13:26:20 UTC.
- Finished: 2026-10-26 13:28:09 UTC.
- Hydra: `2.4.1`, revision `099f5dd775d8640047d0074edef294c1b39a600d`.
- Cardano node: `11.1.3`; CLI: `11.2.3.0`.
- Participants: Alice and Bob, both using `existing-node`.
- Chain: disposable local Cardano devnet, network magic `42`.
- Head ID: `324e62f7cdee55db387fc5d0427a4b1ebd5fce9c7d6ef4a0feb0ef65`.

The run generated fresh keys, seeded both funds addresses, published the Hydra
scripts and submitted real funding transactions. Both peers observed the same
open head, finalized both deposits, and agreed on the committed UTxO and its
amounts. Both processes were restarted and recovered that state. Alice closed
the head; Bob fanned it out after the contestation period. Both peers observed
finalization, and layer 1 queries confirmed that the committed ada was returned
to the original funds addresses.

Full local evidence is generated at `state/validation/nix/result.json` and
`state/validation/nix/logs/` (ignored by Git). CI is configured to retain equivalent artifacts.
To reproduce:

```sh
nix run .#test-lifecycle -- --output-dir state/validation/nix
```

This execution environment initially lacked `/etc/hosts`. Localhost entries
were supplied temporarily for the test and removed afterward. The runner left
no Cardano, Hydra, process-compose or etcd processes running. Normal developer
machines and CI runners are expected to have working localhost resolution.

## Single-party Preview on macOS ARM

Manually exercised on 2026-11-18 using the `cardano-node`
recipe on Apple Silicon (`aarch64-darwin`), with no Blockfrost project ID.

- Hydra: `2.4.1`, revision `099f5dd775d8640047d0074edef294c1b39a600d`.
- Cardano node: `11.1.3`; CLI: `11.2.3.0`; Mithril client: `0.13.20`.
- Network: public Preview, magic `2`.
- One participant, `alice`, with `peers: []`.
- Head ID: `b3df4f2cb24e050ce48cc29058aae7acb2bd87e919fecfe7779909b9`.

| Phase | Observed result |
| --- | --- |
| Bootstrap | Mithril snapshot downloaded and verified; database occupied roughly 16 GB |
| Sync and funding | Cardano reached `100.00` sync; generated keys, faucet funding and fuel distribution succeeded |
| Open | `HeadIsOpen` on 2026-11-19 at 13:15:59 UTC |
| Restart | Logs showed the open head loaded from persistence after restart, before depositing |
| Deposit | `CommitRecorded` at 10:51:56 UTC on 2026-11-20; `CommitFinalized` at 10:59:14 UTC |
| Transactions | Four self-transfers appeared in confirmed snapshots; latest snapshot number was `5` |
| Close | `HeadIsClosed` at 11:02:10 UTC, using snapshot `5`; contestation deadline was 11:09:49 UTC |
| Fanout | `ReadyToFanout` at 11:09:53 UTC; `HeadIsFinalized` at 11:11:16 UTC |
| Layer 1 verification | At Preview block `4875636`, the node was fully synced and every finalized output existed on layer 1 |

The funds address received five outputs: 10, 40, 49, 100 and 4,800.916634 test
ada. Their total, 4,999.916634 test ada, exactly matched the deposited amount.
The returned output addresses and values matched the final confirmed snapshot;
fanout output IDs matched the live layer 1 query. The separate fuel wallet
retained 4,996.513255 test ada after layer 1 fees.

Public layer 1 transaction IDs:

| Transaction | ID |
| --- | --- |
| Fuel distribution | `e91297cb3d4413ca1e39bb3dd10dfbdafd972213b6716d01beff0cafb70136e7` |
| Init | `faf89172a3aac77de4a03c1b458d8b7cc090b4901c7f191cec3e72cb6ffb384d` |
| Deposit | `3e230e30b0d3ded15323081a121e18413c3d44234a87a5782539a9f532401c79` |
| Fanout | `f8d0e09674b34211c93e0fe4e895e1937ad3548d35f028944e16b1d867641654` |

Local evidence was saved under `state/validation/preview-finalization/`:
`events.jsonl`, `tip.json`, `funds-utxo.json`, `fuel-utxo.json` and `result.json`.
These files are ignored by Git and are not bundled with this record. The
instructions in [Using a head](../README.md#using-a-head) and the
[cardano-node guide](../recipes/cardano-node/README.md#verify-returned-funds)
describe the workflow and balance checks. Event timestamps above are
observations, not completion-time guarantees.

This run validates the single-party Preview lifecycle through funds returned on
macOS  on Apple M1. It does not validate multi-party public-network operation, Preprod,
live Blockfrost, Docker or recovery of deposited funds across a restart. The
