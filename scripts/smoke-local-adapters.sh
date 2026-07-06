#!/usr/bin/env bash
set -euo pipefail

RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
PRIVATE_KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
DEPLOYER="${DEPLOYER:-0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266}"

require_cmd() {
  command -v "$1" >/dev/null || { echo "missing command: $1" >&2; exit 1; }
}

create_contract() {
  local contract="$1"
  shift
  forge create --broadcast --json --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" "$contract" "$@" | jq -r .deployedTo
}

send_tx() {
  cast send --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" "$@" >/dev/null
}

read_position() {
  cast call --rpc-url "$RPC_URL" "$1" 'position(address)(uint256,uint256,uint256,uint256)' "$DEPLOYER"
}

assert_position() {
  local label="$1"
  local vault="$2"
  local expected="$3"
  local got
  got="$(read_position "$vault" | sed -E 's/ \[[^]]+\]//g' | tr '\n' ' ' | tr -s ' ' | sed 's/^ //; s/ $//')"
  if [[ "$got" != "$expected" ]]; then
    echo "[$label] unexpected position" >&2
    echo "expected: $expected" >&2
    echo "got:      $got" >&2
    exit 1
  fi
}

run_stack() {
  local label="$1"
  local backend_kind="$2"

  echo "== $label =="
  local stock usdc router backend adapter vault
  stock="$(create_contract src/mocks/MockStock.sol:MockStock --constructor-args "Mock Stock" "mSTOCK")"
  usdc="$(create_contract src/mocks/MockERC20.sol:MockERC20 --constructor-args "Mock USDC" "USDC" 18)"
  router="$(create_contract src/mocks/MockRouter.sol:MockRouter --constructor-args "$stock" "$usdc")"

  if [[ "$backend_kind" == "morpho" ]]; then
    backend="$(create_contract src/mocks/MockMorpho.sol:MockMorpho --constructor-args "$stock" "$usdc" 7500)"
    adapter="$(create_contract src/adapters/MockMorphoAdapter.sol:MockMorphoAdapter --constructor-args "$stock" "$usdc" "$backend")"
    send_tx "$usdc" 'mint(address,uint256)' "$backend" 1000000000000000000000000
  elif [[ "$backend_kind" == "everst" ]]; then
    backend="$(create_contract src/mocks/MockEverst.sol:MockEverst --constructor-args "$stock" "$usdc" 7500)"
    adapter="$(create_contract src/adapters/MockEverstAdapter.sol:MockEverstAdapter --constructor-args "$stock" "$usdc" "$backend")"
    send_tx "$usdc" 'mint(address,uint256)' "$backend" 1000000000000000000000000
  else
    echo "unknown backend kind: $backend_kind" >&2
    exit 1
  fi

  vault="$(create_contract src/BoostVault.sol:BoostVault --constructor-args "$stock" "$usdc" "$adapter" "$router" 6000)"
  send_tx "$adapter" 'setVault(address)' "$vault"

  send_tx "$stock" 'mint(address,uint256)' "$DEPLOYER" 100000000000000000000
  send_tx "$stock" 'mint(address,uint256)' "$router" 1000000000000000000000000
  send_tx "$usdc" 'mint(address,uint256)' "$router" 1000000000000000000000000
  send_tx "$stock" 'approve(address,uint256)' "$vault" 100000000000000000000

  send_tx "$vault" 'depositAndBoostFor(address,uint256,uint256,uint256)' "$DEPLOYER" 100000000000000000000 25000 1
  assert_position "$label boost" "$vault" "250000000000000000000 150000000000000000000 100000000000000000000 25000"

  send_tx "$vault" 'unwindAllFor(address)' "$DEPLOYER"
  assert_position "$label unwind" "$vault" "0 0 0 0"

  local balance
  balance="$(cast call --rpc-url "$RPC_URL" "$stock" 'balanceOf(address)(uint256)' "$DEPLOYER" | sed -E 's/ \[[^]]+\]//g')"
  if [[ "$balance" != "100000000000000000000" ]]; then
    echo "[$label] expected deployer to recover 100 mock stock, got $balance" >&2
    exit 1
  fi

  echo "$label ok: vault=$vault adapter=$adapter backend=$backend"
}

require_cmd forge
require_cmd cast
require_cmd jq
cast chain-id --rpc-url "$RPC_URL" >/dev/null

if [[ "$PRIVATE_KEY" == "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" ]]; then
  echo "WARNING: using the default Anvil private key. Only run this script against local Anvil or fork RPCs you control." >&2
fi

run_stack "Morpho adapter local smoke" "morpho"
run_stack "Everst adapter local smoke" "everst"

echo "local adapter smoke passed"
