#!/bin/sh
set -eu

[ -d /data/db ] && exit 0

case "${SKIP_MITHRIL:-false}" in
true)
  echo "Skipping Mithril; cardano-node will sync from genesis."
  exit 0
  ;;
false) ;;
*)
  echo "SKIP_MITHRIL must be true or false" >&2
  exit 1
  ;;
esac

case "$NETWORK" in
preview) dir=pre-release-preview ;;
preprod) dir=release-preprod ;;
*)
  echo "unsupported NETWORK: $NETWORK" >&2
  exit 1
  ;;
esac

keys="https://raw.githubusercontent.com/IntersectMBO/mithril/3f6cb73f491eb3195d02318643e40836fb093acc/mithril-infra/configuration/$dir"
AGGREGATOR_ENDPOINT="https://aggregator.$dir.api.mithril.network/aggregator"
GENESIS_VERIFICATION_KEY=$(wget -qO- "$keys/genesis.vkey")
ANCILLARY_VERIFICATION_KEY=$(wget -qO- "$keys/ancillary.vkey")
export AGGREGATOR_ENDPOINT GENESIS_VERIFICATION_KEY ANCILLARY_VERIFICATION_KEY

rm -rf /data/download
/app/bin/mithril-client --origin-tag HYDRA \
  cardano-db download latest --backend v2 --include-ancillary --download-dir /data/download
mv /data/download/db /data/db
rmdir /data/download
