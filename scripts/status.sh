#!/usr/bin/env bash
# Read live state without signing or submitting transactions.
# Functions are also invoked by name through probe.
# shellcheck disable=SC2329
set -euo pipefail

usage() {
  echo "usage: $0 [cardano-node | existing-node | blockfrost | single-party | docker] [--api-url URL] [--timeout SECONDS]" >&2
  exit 2
}

recipe=cardano-node
api_url=http://127.0.0.1:4001
request_timeout=5
if [ $# -gt 0 ] && [[ $1 != --* ]]; then
  recipe=$1
  shift
fi
while [ $# -gt 0 ]; do
  case "$1" in
  --api-url)
    [ $# -ge 2 ] || usage
    api_url=${2%/}
    shift 2
    ;;
  --timeout)
    [ $# -ge 2 ] || usage
    request_timeout=$2
    shift 2
    ;;
  *) usage ;;
  esac
done
case "$recipe" in cardano-node | existing-node | blockfrost | single-party | docker) ;; *) usage ;; esac
[[ $request_timeout =~ ^[1-9][0-9]*$ ]] || usage
case "$api_url" in http://?* | https://?*) ;; *) usage ;; esac
[[ $api_url != *[\?\#\@[:space:]]* ]] || usage

[ -f config/env ] || {
  echo "run from the repository root" >&2
  exit 1
}
# shellcheck disable=SC1091
. config/env
case "${NETWORK:-}" in preview | preprod) ;; *)
  echo "unsupported NETWORK in config/env" >&2
  exit 1
  ;;
esac
[[ ${NETWORK_MAGIC:-} =~ ^[0-9]+$ ]] || {
  echo "invalid NETWORK_MAGIC in config/env" >&2
  exit 1
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failed=0
reply=

# Each probe can fail independently, so a stopped Hydra API does not hide
# wallet balances while the recipe is waiting for its initial fuel.
probe() {
  local label=$1 code
  shift
  if reply=$("$@" 2>"$tmp/error"); then
    return 0
  else
    code=$?
  fi
  failed=1
  printf '%s: unavailable' "$label"
  if [ "$code" -eq 124 ] || [ "$code" -eq 137 ]; then
    printf ' (timed out after %ss)' "$request_timeout"
  elif [ -s "$tmp/error" ]; then
    printf ' (%s)' "$(head -c 600 "$tmp/error" | jq -aRs .)"
  fi
  printf '\n'
  return 1
}

validate() {
  jq -se "length == 1 and (.[0] | ($1))" >/dev/null <<<"$2" || {
    echo "invalid response" >&2
    return 1
  }
}

run_timed() {
  # SIGTERM alone cannot bound commands that ignore it. Allow one second for
  # cleanup, then kill the process group. Status probes never need stdin.
  timeout --kill-after=1 "$request_timeout" "$@" </dev/null
}

http() {
  run_timed curl --fail --silent --show-error --max-time "$request_timeout" "$@"
}

hosted() { [[ $recipe == blockfrost || $recipe == single-party ]]; }

blockfrost() {
  local project code
  project=$(tr -d '[:space:]' <credentials/blockfrost-project.txt) || return
  [ -n "$project" ] || {
    echo "credentials/blockfrost-project.txt is empty" >&2
    return 1
  }
  code=$(run_timed curl --silent --show-error --max-time "$request_timeout" \
    -o "$tmp/body" -w '%{http_code}' -H "project_id: $project" \
    "https://cardano-$NETWORK.blockfrost.io/api/v0$1") || return
  case "$code" in
  200) cat "$tmp/body" ;;
  404)
    # Only a never-seen address is an empty balance, not a failed tip request.
    case "$1" in /addresses/*/utxos\?*) echo '[]' ;; *)
      echo "Blockfrost: HTTP $code" >&2
      return 1
      ;;
    esac
    ;;
  *)
    echo "Blockfrost: HTTP $code" >&2
    return 1
    ;;
  esac
}

socket_path() {
  case "$recipe" in
  docker) echo /ipc/node.socket ;;
  existing-node)
    [ -n "${CARDANO_NODE_SOCKET_PATH:-}" ] || {
      echo "set CARDANO_NODE_SOCKET_PATH for existing-node" >&2
      return 1
    }
    printf '%s\n' "$CARDANO_NODE_SOCKET_PATH"
    ;;
  *) echo state/cardano-node/node.socket ;;
  esac
}

query() {
  local socket
  local connection=() command=(cardano-cli query)
  if [ "$recipe" = docker ]; then
    command=(bash recipes/docker/run.sh cli query)
  else
    socket=$(socket_path) || return
    connection=(--socket-path "$socket")
  fi
  run_timed "${command[@]}" "$@" "${connection[@]}" \
    --testnet-magic "$NETWORK_MAGIC" --out-file /dev/stdout
}

configuration() {
  local result expected actual
  result=$(http "$api_url/config") || return
  if hosted; then
    validate '.chain.mode == "cardano" and .chain.backend.mode == "blockfrost" and
      (.chain.backend."project-path" | type == "string")' "$result" || {
      echo "Hydra backend does not match the selected recipe" >&2
      return 1
    }
    expected=credentials/blockfrost-project.txt
    actual=$(jq -r '.chain.backend."project-path"' <<<"$result")
  else
    validate '.chain.mode == "cardano" and .chain.backend.mode == "direct" and
      (.chain.backend."node-socket" | type == "string")' "$result" || {
      echo "Hydra backend does not match the selected recipe" >&2
      return 1
    }
    jq -e --arg magic "$NETWORK_MAGIC" '.chain.backend | .mainnet != true and
      ."testnet-magic" == ($magic | tonumber)' >/dev/null <<<"$result" || {
      echo "Hydra network does not match config/env" >&2
      return 1
    }
    expected=$(socket_path) || return
    actual=$(jq -r '.chain.backend."node-socket"' <<<"$result")
  fi
  actual=$(realpath -m -- "$actual") || return
  expected=$(realpath -m -- "$expected") || return
  [ "$actual" = "$expected" ] || {
    echo "Hydra connection path does not match the selected recipe" >&2
    return 1
  }
}

tip() {
  local result
  if hosted; then
    result=$(blockfrost /blocks/latest) || return
    validate 'type == "object" and (.height | type == "number")' "$result" || return
  else
    result=$(query tip) || return
    validate 'type == "object" and (.slot | type == "number") and
      (.syncProgress == null or (.syncProgress | tonumber | . >= 0 and . <= 100))' "$result" || return
  fi
  echo "$result"
}

utxos() {
  local address result entries page=1
  address=$(tr -d '[:space:]' <"credentials/$1.addr") || return
  [[ $address =~ ^addr_test1[[:alnum:]]+$ ]] || {
    echo "invalid credentials/$1.addr" >&2
    return 1
  }
  if hosted; then
    : >"$tmp/utxos"
    while :; do
      entries=$(blockfrost "/addresses/$address/utxos?count=100&page=$page") || return
      validate 'type == "array"' "$entries" || return
      jq -c '.[] | {key: "\(.tx_hash)#\(.output_index)", value: {value: {
        lovelace: (.amount | map(select(.unit == "lovelace")) | .[0].quantity | tonumber)}}}' \
        <<<"$entries" >>"$tmp/utxos" || return
      [ "$(jq length <<<"$entries")" -eq 100 ] || break
      page=$((page + 1))
    done
    result=$(jq -s from_entries "$tmp/utxos") || return
  else
    result=$(query utxo --address "$address") || return
  fi
  validate 'type == "object" and all(.[];
    (.value.lovelace | type == "number" and . >= 0 and floor == .))' "$result" || return
  echo "$result"
}

balance() {
  local values value amount=0 count=0 max=9223372036854775807
  # jq preserves individual integer literals, but adding them can round above
  # 2^53. Sum in Bash's signed 64-bit arithmetic, checking before each addition.
  values=$(jq -r '.[].value.lovelace | tostring' <<<"$1") || return
  while IFS= read -r value; do
    [ -n "$value" ] || continue
    if [[ ! $value =~ ^(0|[1-9][0-9]*)$ || ${#value} -gt 19 ||
      (${#value} -eq 19 && $value > $max) ]]; then
      echo "invalid or out-of-range lovelace amount" >&2
      return 1
    fi
    if ((value > max - amount)); then
      echo "balance exceeds the supported integer range" >&2
      return 1
    fi
    amount=$((amount + value))
    count=$((count + 1))
  done <<<"$values"
  printf '%d.%06d ada (%s UTxOs)' "$((amount / 1000000))" "$((amount % 1000000))" "$count"
}

greeting() {
  local result ws_url
  case "$api_url" in
  https://*) ws_url="wss://${api_url#https://}/?history=no&snapshot-utxo=no" ;;
  *) ws_url="ws://${api_url#http://}/?history=no&snapshot-utxo=no" ;;
  esac
  result=$(run_timed websocat -t -U -1 "$ws_url") || return
  validate '.tag == "Greetings" and
    (.headStatus | IN("Idle", "Open", "Closed", "FanoutPossible", "FanningOut")) and
    (.chainSyncedStatus | IN("InSync", "CatchingUp")) and
    (.hydraHeadId == null or (.hydraHeadId | type == "string" and test("^[0-9a-f]{56}$")))' "$result" || return
  echo "$result"
}

deposits() {
  local result
  result=$(http "$api_url/commits") || return
  validate 'type == "array" and all(.[]; type == "string" and test("^[0-9a-f]{64}$"))' "$result" || return
  echo "$result"
}

printf 'Network: %s (magic %s); recipe: %s\n' "$NETWORK" "$NETWORK_MAGIC" "$recipe"
if probe 'Layer 1' tip; then
  if hosted; then
    printf 'Layer 1: Blockfrost reachable (block %s)\n' "$(jq -r .height <<<"$reply")"
  else
    printf 'Layer 1: %s%% synced (slot %s)\n' "$(jq -r '.syncProgress // "unknown"' <<<"$reply")" "$(jq -r .slot <<<"$reply")"
    jq -e '.syncProgress != null and (.syncProgress | tonumber) == 100' >/dev/null <<<"$reply" || failed=1
  fi
fi
if probe Hydra configuration; then
  if probe Hydra greeting; then
    printf 'Hydra sync: %s\nHead: %s\n' "$(jq -r .chainSyncedStatus <<<"$reply")" "$(jq -r .headStatus <<<"$reply")"
    if [ "$(jq -r '.hydraHeadId // empty' <<<"$reply")" != "" ]; then
      printf 'Head ID: %s\n' "$(jq -r .hydraHeadId <<<"$reply")"
    fi
    jq -e '.chainSyncedStatus == "InSync"' >/dev/null <<<"$reply" || failed=1
  fi
  if probe 'Pending deposits' deposits; then
    printf 'Pending deposits: %s\n' "$(jq length <<<"$reply")"
    jq -r '.[] | "  " + .' <<<"$reply"
  fi
else
  echo 'Pending deposits: unavailable (Hydra configuration could not be verified)'
fi
for wallet in funds cardano; do
  label=Funds
  [ "$wallet" != cardano ] || label=Fuel
  if probe "$label" utxos "$wallet"; then
    wallet_utxos=$reply
    if probe "$label" balance "$wallet_utxos"; then
      printf '%s: %s\n' "$label" "$reply"
      if [ "$wallet" = cardano ] && [ "$(jq length <<<"$wallet_utxos")" -eq 0 ]; then
        failed=1
        printf '  No fuel UTxO; fund credentials/funds.addr, then just distribute %s.\n' "$recipe"
      fi
    fi
  fi
done
exit "$failed"
