// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {ClaimAsset, PaseoFaucet, Tier} from "../src/PaseoFaucet.sol";

/// @notice Brings the claim settings of the deployed faucet at `FAUCET_ADDRESS` in line with the environment:
///         `MAX_CLAIMS_PER_EPOCH`, and `CLAIM_ASSETS` as comma-separated `asset:maxClaim:lite:full` entries, where
///         `lite` and `full` are the allowances per epoch of each tier. Amounts are base units, plancks for PAS
///         (asset 0). Only the settings that differ get a transaction, so a faucet already in line gets none; listed
///         assets the environment leaves out keep their settings. The sender must be the owner: a wallet option, or
///         `--sender` to simulate.
contract ConfigureClaims is Script {
    struct Entry {
        uint32 asset;
        uint128 maxClaim;
        uint128 lite;
        uint128 full;
    }

    function run() external returns (uint256 changed) {
        PaseoFaucet faucet = PaseoFaucet(payable(vm.envAddress("FAUCET_ADDRESS")));
        uint32 cap = _u32(vm.envString("MAX_CLAIMS_PER_EPOCH"));
        changed = configure(faucet, cap, parse(vm.envString("CLAIM_ASSETS")));
    }

    /// @notice The same for `faucet`, without the environment; answers how many settings it changed.
    function configure(PaseoFaucet faucet, uint32 cap, Entry[] memory entries) public returns (uint256 changed) {
        vm.startBroadcast();
        if (faucet.maxClaimsPerEpoch() != cap) {
            faucet.setMaxClaimsPerEpoch(cap);
            ++changed;
        }
        for (uint256 i; i < entries.length; ++i) {
            Entry memory e = entries[i];
            (bool enabled, uint128 maxClaim) = faucet.claimAsset(e.asset);
            if (!enabled || maxClaim != e.maxClaim) {
                faucet.setClaimAsset(e.asset, ClaimAsset(true, e.maxClaim));
                ++changed;
            }
            if (faucet.claimAllowance(Tier.Lite, e.asset) != e.lite) {
                faucet.setClaimAllowance(Tier.Lite, e.asset, e.lite);
                ++changed;
            }
            if (faucet.claimAllowance(Tier.Full, e.asset) != e.full) {
                faucet.setClaimAllowance(Tier.Full, e.asset, e.full);
                ++changed;
            }
        }
        vm.stopBroadcast();
    }

    /// @notice Parses `CLAIM_ASSETS`; an entry without four fields or with an out-of-range value aborts.
    function parse(string memory list) public pure returns (Entry[] memory entries) {
        string[] memory items = vm.split(list, ",");
        entries = new Entry[](items.length);
        for (uint256 i; i < items.length; ++i) {
            string[] memory fields = vm.split(vm.trim(items[i]), ":");
            require(fields.length == 4, "a CLAIM_ASSETS entry is not asset:maxClaim:lite:full");
            entries[i] = Entry(_u32(fields[0]), _u128(fields[1]), _u128(fields[2]), _u128(fields[3]));
        }
    }

    function _u32(string memory value) private pure returns (uint32) {
        uint256 parsed = vm.parseUint(vm.trim(value));
        require(parsed <= type(uint32).max, string.concat(value, " is out of range"));
        // casting to 'uint32' is safe because the require above bounds it
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(parsed);
    }

    function _u128(string memory value) private pure returns (uint128) {
        uint256 parsed = vm.parseUint(vm.trim(value));
        require(parsed <= type(uint128).max, string.concat(value, " is out of range"));
        // casting to 'uint128' is safe because the require above bounds it
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(parsed);
    }
}
