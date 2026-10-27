# Recorded validation

Recorded on 2026-10-26 on x86_64 Linux. Re-run the checks after changing versions
or recipe behavior; this record is not a claim about other platforms or networks.

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
