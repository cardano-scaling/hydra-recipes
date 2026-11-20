#!/usr/bin/env bash
# Fixture commands for status.sh; reject every non-query Cardano operation.
set -euo pipefail
tool=$1
shift
case "$tool" in
cardano-cli)
  [ "${STATUS_CLI_TIMEOUT:-}" != true ] || exit 124
  [ "$1" = query ]
  kind=$2
  shift 2
  address='' socket=''
  while [ $# -gt 0 ]; do
    case "$1" in
    --address)
      address=$2
      shift 2
      ;;
    --socket-path)
      socket=$2
      shift 2
      ;;
    *) shift ;;
    esac
  done
  if [ -n "${STATUS_EXPECT_SOCKET:-}" ]; then
    [ "$socket" = "$STATUS_EXPECT_SOCKET" ]
  fi
  case "$kind" in
  tip) cat "$STATUS_FIXTURES/tip.json" ;;
  utxo)
    case "$address" in
    addr_test1funds) cat "$STATUS_FIXTURES/funds.json" ;;
    addr_test1fuel) cat "$STATUS_FIXTURES/fuel.json" ;;
    *) exit 1 ;;
    esac
    ;;
  *)
    echo "unexpected Cardano command: $kind" >&2
    exit 1
    ;;
  esac
  ;;
websocat)
  if [ "${STATUS_API_STALL:-}" = true ]; then
    trap '' TERM
    sleep 6
    exit 124
  fi
  if [ "${STATUS_API_ERROR_CONTROL:-}" = true ]; then
    printf '\033[31muntrusted error\033[0m\n' >&2
    exit 1
  fi
  [ "${STATUS_API_TIMEOUT:-}" != true ] || exit 124
  [ "${STATUS_API_DOWN:-}" != true ] || {
    echo 'connection refused' >&2
    exit 1
  }
  [ "$*" = "-t -U -1 ${STATUS_EXPECT_WS:-ws://127.0.0.1:4001/?history=no&snapshot-utxo=no}" ]
  cat "$STATUS_FIXTURES/greeting.json"
  ;;
curl)
  output='' url=''
  while [ $# -gt 0 ]; do
    case "$1" in
    -o)
      output=$2
      shift 2
      ;;
    -w | -H | --max-time) shift 2 ;;
    http*)
      url=$1
      shift
      ;;
    *) shift ;;
    esac
  done
  case "$url" in
  */commits | */config)
    [ "${STATUS_API_DOWN:-}" != true ] || {
      echo 'connection refused' >&2
      exit 1
    }
    case "$url" in
    */config) cat "$STATUS_FIXTURES/api-config.json" ;;
    *) cat "$STATUS_FIXTURES/deposits.json" ;;
    esac
    ;;
  *)
    [ -n "$output" ]
    code=${STATUS_BF_CODE:-200}
    case "$url" in
    */blocks/latest)
      code=${STATUS_BF_TIP_CODE:-$code}
      echo '{"height":123}' >"$output"
      ;;
    */addresses/addr_test1funds/utxos\?*)
      code=${STATUS_BF_FUNDS_CODE:-$code}
      cat "$STATUS_FIXTURES/bf-funds-${url##*page=}.json" >"$output"
      ;;
    */addresses/addr_test1fuel/utxos\?*) cat "$STATUS_FIXTURES/bf-fuel.json" >"$output" ;;
    *)
      echo "unexpected URL" >&2
      exit 1
      ;;
    esac
    printf '%s' "$code"
    ;;
  esac
  ;;
docker)
  [ "$1" = compose ]
  no_tty=false
  until [ "$1" = cardano-cli ]; do
    [ "$1" != -T ] || no_tty=true
    shift
  done
  "$no_tty" || {
    echo 'status Docker queries must disable TTY allocation' >&2
    exit 1
  }
  [ ! -t 0 ]
  shift
  exec bash "${BASH_SOURCE[0]}" cardano-cli "$@"
  ;;
nix) printf '%s\n' "$@" >"$STATUS_FIXTURES/nix-args" ;;
*)
  echo "unexpected fixture tool: $tool" >&2
  exit 1
  ;;
esac
