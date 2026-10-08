#!/usr/bin/env bash
# Checks that the contracts in this repo are the code running on Arc mainnet.
#
# Builds each contract with the settings it was deployed with (the `mainnet`
# profile), reads the live bytecode, strips the trailing compiler metadata from
# both, and compares. The metadata hash differs between repos because it
# fingerprints the build environment, not the code; everything the EVM
# executes must match byte for byte.
#
#   bash script/verify-mainnet.sh
#   ARC_MAINNET_RPC_URL=https://... bash script/verify-mainnet.sh

set -euo pipefail

RPC="${ARC_MAINNET_RPC_URL:-https://rpc.mainnet.arc.io}"
DEPLOYMENTS="deployments/arc-mainnet.json"

# Drop the CBOR metadata: its length sits in the last two bytes.
strip_metadata() {
  local hex="${1#0x}"
  local len=$((16#${hex: -4}))
  echo "${hex:0:${#hex}-$((len * 2 + 4))}"
}

chain_id="$(cast chain-id --rpc-url "$RPC")"
if [ "$chain_id" != "5042" ]; then
  echo "Expected Arc mainnet (5042), got chain $chain_id" >&2
  exit 1
fi

FOUNDRY_PROFILE=mainnet forge build --skip test --skip script >/dev/null

failed=0
for name in $(jq -r '.contracts | keys[]' "$DEPLOYMENTS"); do
  address="$(jq -r ".contracts.\"$name\".address" "$DEPLOYMENTS")"
  local_code="$(FOUNDRY_PROFILE=mainnet forge inspect "$name" deployedBytecode)"
  live_code="$(cast code "$address" --rpc-url "$RPC")"
  if [ "$live_code" = "0x" ]; then
    echo "FAIL $name: no code at $address"
    failed=1
  elif [ "$(strip_metadata "$local_code")" = "$(strip_metadata "$live_code")" ]; then
    echo "OK   $name at $address ($(( (${#live_code} - 2) / 2 )) bytes)"
  else
    echo "FAIL $name: code at $address differs from this repo"
    failed=1
  fi
done
exit "$failed"
