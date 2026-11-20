#!/usr/bin/env bash
# Exercise status with a restricted PATH and no running services or signing keys.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/config" "$tmp/credentials" "$tmp/recipes/docker"
cp "$root/recipes/docker/run.sh" "$tmp/recipes/docker/run.sh"
for tool in bash cat chmod cp dirname head id jq just mktemp realpath rm sh sleep timeout tr; do
  ln -s "$(command -v "$tool")" "$tmp/bin/$tool"
done
for tool in cardano-cli curl websocat docker nix; do
  printf '#!%s\nexec bash %q %q "$@"\n' "$(command -v bash)" "$root/tests/fake-status-backend.sh" "$tool" >"$tmp/bin/$tool"
  chmod +x "$tmp/bin/$tool"
done
export PATH="$tmp/bin"
export STATUS_FIXTURES="$tmp"
cd "$tmp"
printf 'NETWORK=preview\nNETWORK_MAGIC=2\n' >config/env
printf 'addr_test1funds\n' >credentials/funds.addr
printf 'addr_test1fuel\n' >credentials/cardano.addr
printf 'secret-project\n' >credentials/blockfrost-project.txt
echo '{"syncProgress":"100.00","slot":123}' >tip.json
head_id=$(printf 'a%.0s' {1..56})
deposit_id=$(printf 'b%.0s' {1..64})
jq -n --arg head "$head_id" '{tag:"Greetings",headStatus:"Open",hydraHeadId:$head,chainSyncedStatus:"InSync"}' >greeting.json
echo '{"chain":{"mode":"cardano","backend":{"mode":"direct","testnet-magic":2,"node-socket":"state/cardano-node/node.socket"}}}' >api-config.json
echo '{"tx#0":{"value":{"lovelace":3000001}}}' >funds.json
echo '{"tx#1":{"value":{"lovelace":4000002}}}' >fuel.json
jq -n --arg deposit "$deposit_id" '[$deposit]' >deposits.json

status() { bash "$root/scripts/status.sh" "$@" >output.log 2>&1; }
contains() { [[ $(<output.log) == *"$1"* ]]; }
absent() { [[ $(<output.log) != *"$1"* ]]; }
expect_failure() {
  if status "$@"; then
    echo "unexpected status success: $*" >&2
    cat output.log >&2
    exit 1
  fi
}

status
contains 'Layer 1: 100.00% synced'
contains 'Hydra sync: InSync'
contains 'Head: Open'
contains "Head ID: $head_id"
contains 'Funds: 3.000001 ada (1 UTxOs)'
contains 'Fuel: 4.000002 ada (1 UTxOs)'
contains 'Pending deposits: 1'
contains "  $deposit_id"
echo 'PASS: status reports live sync, head, exact balances and pending IDs'

cp funds.json saved-funds.json
echo '{"large":{"value":{"lovelace":9007199254740992}},"small":{"value":{"lovelace":1000001}}}' >funds.json
status
contains 'Funds: 9007199255.740993 ada (2 UTxOs)'
echo '{"large":{"value":{"lovelace":9007199254740993}}}' >funds.json
status
contains 'Funds: 9007199254.740993 ada (1 UTxOs)'
for invalid in '{"a":{"value":{"lovelace":100000000000000000000}}}' \
  '{"a":{"value":{"lovelace":9223372036854775807}},"b":{"value":{"lovelace":1}}}'; do
  printf '%s' "$invalid" >funds.json
  expect_failure
  contains 'Funds: unavailable'
  absent 'Funds: 0.000000'
done
cp saved-funds.json funds.json
echo 'PASS: large balances retain every lovelace and integer overflow fails explicitly'

export STATUS_API_DOWN=true
expect_failure
contains 'Hydra: unavailable'
contains 'Pending deposits: unavailable'
absent 'Pending deposits: 0'
contains 'Funds: 3.000001 ada'
unset STATUS_API_DOWN
echo 'PASS: an unavailable Hydra API does not hide wallet balances'

for progress in '"99.99"' null; do
  printf '{"syncProgress":%s,"slot":123}' "$progress" >tip.json
  expect_failure
done
echo '{"syncProgress":"100.00","slot":123}' >tip.json
jq '.chainSyncedStatus = "CatchingUp"' greeting.json >next.json
cp next.json greeting.json
expect_failure
jq '.chainSyncedStatus = "InSync" | .headStatus = "Idle" | del(.hydraHeadId)' greeting.json >next.json
cp next.json greeting.json
echo '{}' >funds.json
status
contains 'Head: Idle'
contains 'Funds: 0.000000 ada (0 UTxOs)'
echo '{}' >fuel.json
expect_failure
contains 'just distribute cardano-node'
echo '{"tx#1":{"value":{"lovelace":4000002}}}' >fuel.json
echo 'PASS: sync lag and empty fuel fail; idle heads and empty funds are valid'

for invalid in 'not JSON' '[]' '{"error":"backend failed"}' '{"tx#0":{"value":{"lovelace":-1}}}'; do
  printf '%s' "$invalid" >funds.json
  expect_failure
  contains 'Funds: unavailable'
  absent 'Funds: 0.000000'
done
echo '{"tx#0":{"value":{"lovelace":3000001}}}' >funds.json
echo '{}' >deposits.json
expect_failure
contains 'Pending deposits: unavailable'
echo '[]' >deposits.json
cp greeting.json next.json
echo '{}' >greeting.json
expect_failure
contains 'Hydra: unavailable'
cp next.json greeting.json
rm credentials/funds.addr
expect_failure
contains 'Funds: unavailable'
contains 'Fuel: 4.000002 ada'
printf 'addr_test1funds\n' >credentials/funds.addr
echo 'PASS: malformed and missing data is never reported as a zero balance'

export STATUS_API_TIMEOUT=true STATUS_CLI_TIMEOUT=true
expect_failure --timeout 1
contains 'timed out after 1s'
unset STATUS_API_TIMEOUT STATUS_CLI_TIMEOUT
expect_failure --timeout 0
expect_failure unknown-recipe
echo 'PASS: timeouts and invalid arguments fail'

export CARDANO_NODE_SOCKET_PATH='' STATUS_EXPECT_SOCKET=''
expect_failure existing-node
contains 'set CARDANO_NODE_SOCKET_PATH'
export CARDANO_NODE_SOCKET_PATH='/node with spaces/socket'
export STATUS_EXPECT_SOCKET="$CARDANO_NODE_SOCKET_PATH"
jq --arg socket "$CARDANO_NODE_SOCKET_PATH" '.chain.backend."node-socket" = $socket' api-config.json >next.json
cp next.json api-config.json
status existing-node
unset STATUS_EXPECT_SOCKET CARDANO_NODE_SOCKET_PATH
jq '.chain.backend."node-socket" = "/ipc/node.socket"' api-config.json >next.json
cp next.json api-config.json
status docker </dev/null
echo 'PASS: existing-node preserves socket paths; Docker queries its running container'

echo '{"chain":{"mode":"cardano","backend":{"mode":"blockfrost","project-path":"credentials/blockfrost-project.txt"}}}' >api-config.json
jq -n '[range(100) | {tx_hash:("tx-" + tostring),output_index:0,
  amount:[{unit:"lovelace",quantity:"1000001"},{unit:"token",quantity:"5"}]}]' >bf-funds-1.json
echo '[{"tx_hash":"last","output_index":0,"amount":[{"unit":"lovelace","quantity":"1000001"}]}]' >bf-funds-2.json
echo '[{"tx_hash":"fuel","output_index":0,"amount":[{"unit":"lovelace","quantity":"2000000"}]}]' >bf-fuel.json
status blockfrost
contains 'Layer 1: Blockfrost reachable (block 123)'
contains 'Funds: 101.000101 ada (101 UTxOs)'
absent 'secret-project'
cp bf-funds-1.json saved-bf-funds.json
echo '[{"tx_hash":"large","output_index":0,"amount":[{"unit":"lovelace","quantity":"9007199254740992"}]},{"tx_hash":"small","output_index":0,"amount":[{"unit":"lovelace","quantity":"1000001"}]}]' >bf-funds-1.json
status blockfrost
contains 'Funds: 9007199255.740993 ada (2 UTxOs)'
cp saved-bf-funds.json bf-funds-1.json
export STATUS_BF_FUNDS_CODE=404
status single-party
contains 'Funds: 0.000000 ada'
unset STATUS_BF_FUNDS_CODE
export STATUS_BF_TIP_CODE=404
expect_failure blockfrost
contains 'Layer 1: unavailable'
unset STATUS_BF_TIP_CODE
export STATUS_BF_CODE=403
expect_failure blockfrost
contains 'Funds: unavailable'
absent 'Funds: 0.000000'
absent 'secret-project'
unset STATUS_BF_CODE
echo 'PASS: Blockfrost handles pagination, unseen addresses and authentication errors'

echo '{"chain":{"mode":"cardano","backend":{"mode":"direct","testnet-magic":2,"node-socket":"state/cardano-node/node.socket"}}}' >api-config.json
cp api-config.json saved-config.json
for change in '.chain.backend."testnet-magic" = 1' '.chain.backend.mainnet = true' \
  '.chain.backend.mode = "blockfrost"' '.chain.backend."node-socket" = "another-node/socket"'; do
  jq "$change" saved-config.json >api-config.json
  expect_failure
  contains 'does not match'
  absent 'Head:'
  contains 'Funds: 3.000001 ada'
done
cp saved-config.json api-config.json
expect_failure blockfrost
contains 'backend does not match'
echo '{"chain":{"mode":"cardano","backend":{"mode":"blockfrost","project-path":"another-project.txt"}}}' >api-config.json
expect_failure blockfrost
contains 'connection path does not match'
cp saved-config.json api-config.json
echo 'PASS: mismatched Hydra networks, backends and connection paths are rejected'

cp greeting.json saved-greeting.json
for change in '.headStatus = "Open\u001b[31m"' '.hydraHeadId = "bad\u001b[31m"' \
  '.chainSyncedStatus = "InSync\u001b[31m"'; do
  jq "$change" saved-greeting.json >greeting.json
  expect_failure
  contains 'Hydra: unavailable'
  absent $'\033'
done
cp saved-greeting.json greeting.json
printf '%s\n%s\n' '{"tag":"Greetings","headStatus":"Open\u001b[31m"}' "$(<saved-greeting.json)" >greeting.json
expect_failure
absent $'\033'
cp saved-greeting.json greeting.json
echo '["bad\u001b[31m"]' >deposits.json
expect_failure
contains 'Pending deposits: unavailable'
absent $'\033'
echo '[]' >deposits.json
export STATUS_API_ERROR_CONTROL=true
expect_failure
contains 'untrusted error'
absent $'\033'
unset STATUS_API_ERROR_CONTROL
echo 'PASS: terminal controls, invalid IDs and multiple JSON documents are rejected or escaped'

export STATUS_API_STALL=true
SECONDS=0
expect_failure --timeout 1
[ "$SECONDS" -lt 5 ]
contains 'timed out after 1s'
unset STATUS_API_STALL
echo 'PASS: a real process ignoring SIGTERM is killed after the timeout grace period'

export STATUS_EXPECT_WS='wss://example.invalid/hydra/?history=no&snapshot-utxo=no'
status cardano-node --api-url https://example.invalid/hydra/ --timeout 1
unset STATUS_EXPECT_WS
# shellcheck disable=SC2016 # Deliberately pass shell syntax as literal data.
payload='http://127.0.0.1:4001/$(printf SHOULD_REMAIN_LITERAL)'
just --justfile "$root/justfile" status cardano-node --api-url "$payload" >just-output.log 2>&1
[ ! -s just-output.log ]
mapfile -t forwarded <nix-args
[ "${forwarded[5]}" = "$payload" ]
echo 'PASS: custom API URLs work and Just forwards shell syntax as literal arguments'
