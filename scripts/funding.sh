#!/usr/bin/env bash
# Ada for the two addresses a hydra-node needs. credentials/funds.addr is the
# one address to fund by hand; `distribute` splits it evenly with the fuel
# address credentials/cardano.addr, which hydra-node's own wallet spends on
# Init and the other layer 1 transactions. `wait-for-fuel` blocks until the
# fuel address has a UTxO. Works over a node socket or Blockfrost.
set -euo pipefail

usage() {
  echo "usage: $0 (wait-for-fuel | distribute) (--node-socket PATH | --blockfrost FILE)" >&2
  exit 1
}

[ -f config/env ] || {
  echo "run from the repository root" >&2
  exit 1
}
# shellcheck disable=SC1091
. config/env

[ $# -eq 3 ] && [ -n "$3" ] || usage
cmd=$1
case "$cmd" in wait-for-fuel | distribute) ;; *) usage ;; esac

fuel_addr=$(cat credentials/cardano.addr)
funds_addr=$(cat credentials/funds.addr)
faucet=https://docs.cardano.org/cardano-testnets/tools/faucet
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# A backend provides utxos ADDR as an array of {txin, lovelace, assets},
# fee_params printing "per-byte fixed", and submit SIGNED-TX-FILE.
case "$2" in
--node-socket)
  socket=$3
  ccli() {
    cardano-cli latest "$@" --testnet-magic "$NETWORK_MAGIC" --socket-path "$socket"
  }
  utxos() {
    ccli query utxo --address "$1" --out-file /dev/stdout |
      jq '[to_entries[] | {txin: .key, lovelace: .value.value.lovelace,
        assets: ((.value.value | keys) - ["lovelace"] | length)}]'
  }
  fee_params() {
    ccli query protocol-parameters --out-file /dev/stdout | jq -r '"\(.txFeePerByte) \(.txFeeFixed)"'
  }
  submit() {
    ccli transaction submit --tx-file "$1"
  }
  ;;
--blockfrost)
  project=$(tr -d '[:space:]' <"$3")
  url=https://cardano-$NETWORK.blockfrost.io/api/v0
  # Prints the HTTP status, the body goes to $tmp/body.
  bf() {
    curl -sS --max-time 60 -o "$tmp/body" -w '%{http_code}' -H "project_id: $project" "$@"
  }
  bf_fail() {
    echo "blockfrost: HTTP $1: $(cat "$tmp/body")" >&2
    return 1
  }
  utxos() {
    local code page=1
    : >"$tmp/utxos"
    while :; do
      code=$(bf "$url/addresses/$1/utxos?count=100&page=$page") || return
      case "$code" in
      200)
        jq -c '.[] | {txin: "\(.tx_hash)#\(.output_index)",
          lovelace: (.amount | map(select(.unit == "lovelace")) | .[0].quantity | tonumber),
          assets: ((.amount | length) - 1)}' "$tmp/body" >>"$tmp/utxos" || return
        [ "$(jq length "$tmp/body")" -eq 100 ] || break
        page=$((page + 1))
        ;;
      404) break ;; # an address never seen on chain
      *)
        bf_fail "$code"
        return 1
        ;;
      esac
    done
    jq -s . "$tmp/utxos"
  }
  fee_params() {
    local code
    code=$(bf "$url/epochs/latest/parameters")
    [ "$code" = 200 ] || bf_fail "$code"
    jq -r '"\(.min_fee_a) \(.min_fee_b)"' "$tmp/body"
  }
  submit() {
    local code
    jq -r .cborHex "$1" | tr -d '\n' | basenc -d --base16 >"$1.cbor"
    code=$(bf -X POST -H 'Content-Type: application/cbor' --data-binary "@$1.cbor" "$url/tx/submit")
    [ "$code" = 200 ] || bf_fail "$code"
  }
  ;;
*) usage ;;
esac

# Only Bash, jq and coreutils are needed, including in the Cardano Docker image.
ada() {
  local lovelace
  lovelace=$(jq '[.[].lovelace] | add // 0')
  printf '%d.%06d' "$((lovelace / 1000000))" "$((lovelace % 1000000))"
}

wait_for_fuel() {
  local lines explained=
  while :; do
    if lines=$(utxos "$fuel_addr") && [ "$(jq length <<<"$lines")" -gt 0 ]; then
      echo "fuel: $(jq length <<<"$lines") UTxO, $(ada <<<"$lines") ada at $fuel_addr"
      return
    fi
    [ -n "$explained" ] || {
      explained=1
      cat <<MSG
The fuel address credentials/cardano.addr has no UTxO, hydra-node cannot post transactions without one:
  $fuel_addr
Fund credentials/funds.addr once at $faucet:
  $funds_addr
then split it with the fuel address: ${DISTRIBUTE:-the distribute step, see README}
MSG
    }
    echo "waiting for fuel..."
    sleep 10
  done
}

build_tx() { # FEE FUEL-AMOUNT FUNDS-AMOUNT
  cardano-cli latest transaction build-raw "${txins[@]}" \
    --tx-out "$fuel_addr+$2" --tx-out "$funds_addr+$3" --fee "$1" --out-file "$tmp/tx.raw"
  cardano-cli latest transaction sign --tx-body-file "$tmp/tx.raw" \
    --signing-key-file credentials/funds.sk --out-file "$tmp/tx.signed"
}

distribute() {
  local lines total params per_byte fixed fee share change size txid
  # Only ada-only inputs, so there are no other assets to pass through.
  lines=$(utxos "$funds_addr" | jq 'map(select(.assets == 0))')
  [ "$(jq length <<<"$lines")" -gt 0 ] || {
    echo "credentials/funds.addr has no ada-only UTxO. Fund it at $faucet: $funds_addr" >&2
    exit 1
  }
  total=$(jq '[.[].lovelace] | add' <<<"$lines")
  mapfile -t txins < <(jq -r '.[] | "--tx-in", .txin' <<<"$lines")
  params=$(fee_params)
  read -r per_byte fixed <<<"$params"
  # Build once with a guessed fee to measure the transaction, then with the
  # fee for that size plus a margin for the bytes the final amounts may add.
  fee=$((fixed + per_byte * 300))
  share=$(((total - fee) / 2))
  [ "$share" -ge 2000000 ] || {
    echo "not enough at credentials/funds.addr to split: $(echo "$lines" | ada) ada" >&2
    exit 1
  }
  build_tx "$fee" "$share" "$share"
  size=$(jq '.cborHex | length / 2' "$tmp/tx.signed")
  fee=$((fixed + per_byte * (size + 16)))
  share=$(((total - fee) / 2))
  change=$((total - fee - share))
  [ "$share" -ge 2000000 ] || {
    echo "not enough ada to split after the final transaction fee" >&2
    exit 1
  }
  build_tx "$fee" "$share" "$change"
  txid=$(cardano-cli latest transaction txid --tx-file "$tmp/tx.signed" --output-text)
  submit "$tmp/tx.signed"
  echo "submitted $txid, waiting for it..."
  until utxos "$fuel_addr" | jq -e --arg txin "$txid#0" 'any(.[]; .txin == $txin)' >/dev/null; do
    sleep 5
  done
  echo "fuel:  $(utxos "$fuel_addr" | ada) ada at $fuel_addr"
  echo "funds: $(utxos "$funds_addr" | ada) ada at $funds_addr"
}

case "$cmd" in
wait-for-fuel) wait_for_fuel ;;
distribute) distribute ;;
esac
