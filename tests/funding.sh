#!/usr/bin/env bash
# Runs on Nix and inside the unmodified Cardano image. No awk, grep or Python.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/config" "$tmp/credentials"

# Restrict PATH to the actual declared runtime: catch accidental host tools.
for tool in bash basenc cat chmod cp jq mkdir mktemp mv rm touch tr; do
  ln -s "$(command -v "$tool")" "$tmp/bin/$tool"
done
for tool in cardano-cli curl sleep; do
  printf '#!%s\nexec bash %q %q "$@"\n' "$(command -v bash)" "$root/tests/fake-backend.sh" "$tool" >"$tmp/bin/$tool"
  chmod +x "$tmp/bin/$tool"
done
export PATH="$tmp/bin"
export TEST_BACKEND_DIR="$tmp"
cd "$tmp"
printf 'NETWORK=preview\nNETWORK_MAGIC=2\n' >config/env
printf 'fuel\n' >credentials/cardano.addr
printf 'funds\n' >credentials/funds.addr
printf 'fixture-project\n' >credentials/blockfrost-project.txt

reset_ledger() {
  rm -f submitted tx.json waited
  jq -n '{funds:[{txin:"faucet#0",lovelace:10000000001,assets:0},
    {txin:"tokens#0",lovelace:3000000,assets:1}],fuel:[]}' >ledger.json
}
funding() { bash "$root/scripts/funding.sh" "$@"; }
expect_failure() {
  if funding "$@" >failure.log 2>&1; then
    echo "expected failure: $*" >&2
    exit 1
  fi
  [ ! -e submitted ]
}

for backend in node blockfrost; do
  if [ "$backend" = node ]; then
    args=(--node-socket fixture.socket)
  else args=(--blockfrost credentials/blockfrost-project.txt); fi
  reset_ledger
  export TEST_REFUEL_ON_SLEEP=true
  funding wait-for-fuel "${args[@]}"
  [ -e waited ]
  unset TEST_REFUEL_ON_SLEEP
  printf 'PASS: %s keeps the fuel gate closed until funding arrives\n' "$backend"
  reset_ledger
  funding distribute "${args[@]}"
  [ -e submitted ]
  jq -e '.inputs == ["faucet#0"] and
    (.outputs[1].lovelace - .outputs[0].lovelace | . >= 0 and . <= 1)' tx.json >/dev/null
  jq -e 'any(.funds[]; .txin == "tokens#0")' ledger.json >/dev/null
  funding wait-for-fuel "${args[@]}"
  printf 'PASS: %s distribution conserves lovelace, preserves tokens and releases the fuel gate\n' "$backend"

  reset_ledger
  echo '{"funds":[],"fuel":[]}' >ledger.json
  expect_failure distribute "${args[@]}"
  reset_ledger
  echo '{"funds":[{"txin":"small#0","lovelace":4000000,"assets":0}],"fuel":[]}' >ledger.json
  expect_failure distribute "${args[@]}"
  reset_ledger
  echo '{"funds":[{"txin":"small#0","lovelace":5000000,"assets":0}],"fuel":[]}' >ledger.json
  export TEST_TX_SIZE=30000
  expect_failure distribute "${args[@]}"
  unset TEST_TX_SIZE
  printf 'PASS: %s rejects empty balances and insufficient ada before and after fee estimation\n' "$backend"
done

reset_ledger
jq -n '{funds:[range(101) | {txin:("faucet\(.)#0"),lovelace:100000000,assets:0}],fuel:[]}' >ledger.json
funding distribute --blockfrost credentials/blockfrost-project.txt
jq -e '.inputs | length == 101' tx.json >/dev/null
printf 'PASS: Blockfrost consumes all pages of ada-only inputs\n'

reset_ledger
export TEST_HTTP_STATUS=403
expect_failure distribute --blockfrost credentials/blockfrost-project.txt
unset TEST_HTTP_STATUS
expect_failure distribute --node-socket fixture.socket --blockfrost credentials/blockfrost-project.txt
printf 'PASS: backend errors and ambiguous backend selection fail without submission\n'
