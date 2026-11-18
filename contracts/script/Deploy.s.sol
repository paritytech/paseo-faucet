// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {Destination, PaseoFaucet, Tier, TierConfig} from "../src/PaseoFaucet.sol";
import {Launch} from "./Launch.sol";

/// @notice Deploys and configures the faucet. When `OWNER` is not the deployer, it then proposes `OWNER`, who
///         completes the handover with `acceptOwnership()`. Every setting comes from the environment; a missing or
///         out-of-range value aborts. The deployer is the CLI's sender: a wallet option, or `--sender` to simulate.
/// @dev PAS amounts are plancks, pUSD amounts are base units. The destinations are `launch()`, from `Launch`.
contract Deploy is Script, Launch {
    function run() external returns (PaseoFaucet faucet) {
        string memory productId = vm.envString("PRODUCT_ID");
        uint64 epochSeconds = uint64(_envUint("EPOCH_SECONDS", type(uint64).max));
        uint32 maxDrips = uint32(_envUint("MAX_DRIPS_PER_EPOCH", type(uint32).max));
        TierConfig memory lite = TierConfig(true, _envAmount("LITE_PAS"), _envAmount("LITE_PUSD"));
        TierConfig memory full = TierConfig(true, _envAmount("FULL_PAS"), _envAmount("FULL_PUSD"));
        address pauser = vm.envAddress("PAUSER");
        address owner = vm.envAddress("OWNER");
        Destination[6] memory destinations = launch();

        vm.startBroadcast();
        faucet = new PaseoFaucet(productId, epochSeconds);
        faucet.setTier(Tier.Lite, lite);
        faucet.setTier(Tier.Full, full);
        faucet.setMaxDripsPerEpoch(maxDrips);
        faucet.setPauser(pauser);
        for (uint256 i; i < destinations.length; ++i) {
            faucet.setDestination(destinations[i]);
        }
        if (owner != faucet.owner()) faucet.transferOwnership(owner);
        vm.stopBroadcast();
    }

    function _envAmount(string memory name) private view returns (uint128) {
        return uint128(_envUint(name, type(uint128).max));
    }

    function _envUint(string memory name, uint256 max) private view returns (uint256 value) {
        value = vm.envUint(name);
        require(value <= max, string.concat(name, " is out of range"));
    }
}
