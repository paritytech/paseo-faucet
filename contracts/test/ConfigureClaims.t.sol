// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ClaimAsset, PaseoFaucet, Tier} from "../src/PaseoFaucet.sol";
import {ConfigureClaims} from "../script/ConfigureClaims.s.sol";

contract ConfigureClaimsTest is Test {
    function test_parse_readsEveryEntry() public {
        ConfigureClaims script = new ConfigureClaims();
        ConfigureClaims.Entry[] memory entries =
            script.parse("0:60000000000000:60000000000000:120000000000000, 1984:5000000000:5000000000:0");
        assertEq(entries.length, 2);
        assertEq(abi.encode(entries[0]), abi.encode(ConfigureClaims.Entry(0, 60e12, 60e12, 120e12)));
        assertEq(abi.encode(entries[1]), abi.encode(ConfigureClaims.Entry(1984, 5e9, 5e9, 0)));
    }

    function test_parse_rejectsMalformedEntries() public {
        ConfigureClaims script = new ConfigureClaims();
        vm.expectRevert("a CLAIM_ASSETS entry is not asset:maxClaim:lite:full");
        script.parse("0:1:2");
        vm.expectRevert();
        script.parse("4294967296:1:1:1");
        vm.expectRevert();
        script.parse("0:x:1:1");
    }

    function test_configure_setsOnlyWhatDiffers() public {
        vm.prank(DEFAULT_SENDER);
        PaseoFaucet faucet = new PaseoFaucet("getcash.dot", 1 days);
        vm.startPrank(DEFAULT_SENDER);
        faucet.setClaimAsset(1984, ClaimAsset(true, 5e9));
        faucet.setClaimAllowance(Tier.Lite, 1984, 5e9);
        vm.stopPrank();
        ConfigureClaims script = new ConfigureClaims();
        ConfigureClaims.Entry[] memory entries = new ConfigureClaims.Entry[](2);
        entries[0] = ConfigureClaims.Entry(0, 60e12, 60e12, 120e12);
        entries[1] = ConfigureClaims.Entry(1984, 5e9, 5e9, 1e10);

        assertEq(script.configure(faucet, 500, entries), 5);
        assertEq(faucet.maxClaimsPerEpoch(), 500);
        (bool enabled, uint128 maxClaim) = faucet.claimAsset(0);
        assertTrue(enabled);
        assertEq(maxClaim, 60e12);
        assertEq(faucet.claimAllowance(Tier.Lite, 0), 60e12);
        assertEq(faucet.claimAllowance(Tier.Full, 0), 120e12);
        assertEq(faucet.claimAllowance(Tier.Full, 1984), 1e10);
        assertEq(script.configure(faucet, 500, entries), 0);
    }

    function test_configure_needsTheOwner() public {
        PaseoFaucet faucet = new PaseoFaucet("getcash.dot", 1 days);
        ConfigureClaims script = new ConfigureClaims();
        // A broadcast call's revert reaches the test without its data.
        vm.expectRevert();
        script.configure(faucet, 1, new ConfigureClaims.Entry[](0));
    }
}
