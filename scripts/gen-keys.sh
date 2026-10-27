#!/usr/bin/env bash
# shellcheck disable=SC2086
set -euo pipefail

[ -f config/env ] || {
  echo "run from the repository root" >&2
  exit 1
}
# shellcheck disable=SC1091
. config/env
hydra_node=${HYDRA_NODE:-hydra-node}
cardano_cli=${CARDANO_CLI:-cardano-cli}

mkdir -p credentials
[ -e credentials/hydra.sk ] && {
  echo "credentials/ already has keys" >&2
  exit 1
}

$hydra_node gen-hydra-key --output-file credentials/hydra
for k in cardano funds; do
  $cardano_cli address key-gen \
    --verification-key-file "credentials/$k.vk" \
    --signing-key-file "credentials/$k.sk"
  $cardano_cli address build \
    --payment-verification-key-file "credentials/$k.vk" \
    --testnet-magic "$NETWORK_MAGIC" \
    --out-file "credentials/$k.addr"
done
chmod 600 credentials/*.sk

echo "funds (credentials/funds.addr):   $(cat credentials/funds.addr)"
echo "fuel  (credentials/cardano.addr): $(cat credentials/cardano.addr)"
echo "Fund the funds address once at https://docs.cardano.org/cardano-testnets/tools/faucet,"
echo "then run the distribute step to split it with the fuel address, see README."
