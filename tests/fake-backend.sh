#!/usr/bin/env bash
# Network boundary fixture. Real funding.sh runs unchanged against this ledger.
set -euo pipefail
cd "$TEST_BACKEND_DIR"

utxos() {
  jq --arg address "$1" '.[$address] // []' ledger.json
}

submit() {
  # Check conservation independently of the funding implementation.
  jq -e --slurpfile ledger ledger.json '
    . as $tx |
    ([$ledger[0].funds[] | select(.txin as $id | $tx.inputs | index($id)) | .lovelace] | add) ==
      (([.outputs[].lovelace] | add) + .fee) and
    (.outputs | length == 2) and (.outputs | all(.lovelace >= 2000000))
  ' tx.json >/dev/null
  jq --slurpfile tx tx.json '
    .funds |= map(select(.txin as $id | $tx[0].inputs | index($id) | not)) |
    .fuel += [{txin: "abcdef#0", lovelace: $tx[0].outputs[0].lovelace, assets: 0}] |
    .funds += [{txin: "abcdef#1", lovelace: $tx[0].outputs[1].lovelace, assets: 0}]
  ' ledger.json >next.json
  mv next.json ledger.json
  touch submitted
}

if [ "$1" = cardano-cli ]; then
  shift
  [ "$1" != latest ] || shift
  case "$1 $2" in
  "query utxo")
    shift 2
    while [ "$1" != --address ]; do shift; done
    utxos "$2" | jq 'map({key: .txin, value: {value:
      ({lovelace: .lovelace} + if .assets > 0 then {policy: {token: 1}} else {} end)}}) | from_entries'
    ;;
  "query protocol-parameters") echo '{"txFeePerByte":44,"txFeeFixed":155381}' ;;
  "transaction build-raw")
    shift 2
    inputs='[]'
    outputs='[]'
    fee=0
    out=
    while [ $# -gt 0 ]; do
      case "$1" in
      --tx-in) inputs=$(jq --arg txin "$2" '. + [$txin]' <<<"$inputs") ;;
      --tx-out) outputs=$(jq --arg address "${2%+*}" --argjson amount "${2##*+}" '. + [{address:$address,lovelace:$amount}]' <<<"$outputs") ;;
      --fee) fee=$2 ;;
      --out-file) out=$2 ;;
      *)
        echo "unexpected build flag: $1" >&2
        exit 1
        ;;
      esac
      shift 2
    done
    jq -n --argjson inputs "$inputs" --argjson outputs "$outputs" --argjson fee "$fee" \
      '{inputs:$inputs,outputs:$outputs,fee:$fee}' >"$out"
    cp "$out" tx.json
    ;;
  "transaction sign")
    while [ "$1" != --out-file ]; do shift; done
    jq -n --argjson size "${TEST_TX_SIZE:-300}" '{cborHex: ("ab" * $size)}' >"$2"
    ;;
  "transaction txid") echo abcdef ;;
  "transaction submit") submit ;;
  *)
    echo "unexpected cardano-cli invocation: $*" >&2
    exit 1
    ;;
  esac
elif [ "$1" = sleep ]; then
  [ "${TEST_REFUEL_ON_SLEEP:-false}" = true ] || {
    echo "unexpected wait in a fixture test" >&2
    exit 1
  }
  touch waited
  jq '.fuel = [{txin:"newfuel#0",lovelace:10000000,assets:0}]' ledger.json >next.json
  mv next.json ledger.json
elif [ "$1" = curl ]; then
  shift
  body=
  url=
  for arg in "$@"; do
    if [ "$arg" = -o ]; then
      next_body=true
    elif [ "${next_body:-false}" = true ]; then
      body=$arg
      next_body=false
    elif [[ $arg == https://* ]]; then
      url=$arg
    fi
  done
  if [ -n "${TEST_HTTP_STATUS:-}" ]; then
    echo '{"message":"fixture backend error"}' >"$body"
    printf '%s' "$TEST_HTTP_STATUS"
    exit
  fi
  case "$url" in
  */addresses/*)
    address=${url#*/addresses/}
    address=${address%%/*}
    page=${url##*page=}
    utxos "$address" | jq --argjson page "$page" '
      .[100 * ($page - 1):100 * $page] | map({tx_hash:(.txin | split("#")[0]),
        output_index:(.txin | split("#")[1] | tonumber), amount:
        ([{unit:"lovelace",quantity:(.lovelace|tostring)}] +
          if .assets > 0 then [{unit:"policytoken",quantity:"1"}] else [] end)})' >"$body"
    ;;
  */epochs/latest/parameters) echo '{"min_fee_a":44,"min_fee_b":155381}' >"$body" ;;
  */tx/submit)
    submit
    echo '"abcdef"' >"$body"
    ;;
  *)
    echo "unexpected URL: $url" >&2
    exit 1
    ;;
  esac
  printf 200
fi
