// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IPersonhood} from "../src/interfaces/IPersonhood.sol";
import {IXcm} from "../src/interfaces/IXcm.sol";
import {ClaimAsset, PaseoFaucet, Tier} from "../src/PaseoFaucet.sol";
import {XcmProgram} from "../src/XcmProgram.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPersonhood} from "./mocks/MockPersonhood.sol";
import {MockSystem} from "./mocks/MockSystem.sol";
import {MockXcm} from "./mocks/MockXcm.sol";

contract PaseoFaucetClaimTest is Test {
    uint64 constant EPOCH_SECONDS = 1 days;
    uint64 constant START_EPOCH = 20_000;
    uint32 constant PAS = 0;
    uint32 constant PUSD_ID = 50_000_413;
    uint32 constant USDT_ID = 1984;
    uint128 constant MAX_PAS = 6_000e10;
    uint128 constant MAX_STABLE = 5_000e6;
    uint128 constant LITE_PAS_ALLOWANCE = 6_000e10;
    uint128 constant LITE_STABLE_ALLOWANCE = 5_000e6;
    uint128 constant FULL_PAS_ALLOWANCE = 12_000e10;
    bytes32 constant RECIPIENT = 0xd43593c715fdd31c61141abd04a99fd6822c8558854ccde39a5684e7a56da27d;
    bytes32 constant ALIAS = keccak256("alias");
    bytes constant PROOF = hex"0102030405";
    uint32 constant RING = 3;
    uint32 constant REVISION = 57;

    PaseoFaucet faucet;
    MockPersonhood personhood;
    MockXcm xcm;
    MockERC20 pusd;
    MockERC20 usdt;
    address stranger = makeAddr("stranger");

    function setUp() public {
        vm.chainId(420_420_417);
        vm.warp(START_EPOCH * EPOCH_SECONDS + 123);
        faucet = new PaseoFaucet("getcash.dot", EPOCH_SECONDS);

        vm.etch(address(faucet.PERSONHOOD()), address(new MockPersonhood()).code);
        vm.etch(address(faucet.SYSTEM()), address(new MockSystem()).code);
        vm.etch(address(faucet.XCM()), address(new MockXcm()).code);
        vm.etch(address(faucet.PUSD()), address(new MockERC20()).code);
        vm.etch(address(faucet.assetToken(USDT_ID)), address(new MockERC20()).code);
        personhood = MockPersonhood(address(faucet.PERSONHOOD()));
        xcm = MockXcm(address(faucet.XCM()));
        pusd = MockERC20(address(faucet.PUSD()));
        usdt = MockERC20(address(faucet.assetToken(USDT_ID)));

        faucet.setMaxClaimsPerEpoch(500);
        faucet.setClaimAsset(PAS, ClaimAsset(true, MAX_PAS));
        faucet.setClaimAsset(PUSD_ID, ClaimAsset(true, MAX_STABLE));
        faucet.setClaimAsset(USDT_ID, ClaimAsset(true, MAX_STABLE));
        faucet.setClaimAllowance(Tier.Lite, PAS, LITE_PAS_ALLOWANCE);
        faucet.setClaimAllowance(Tier.Lite, PUSD_ID, LITE_STABLE_ALLOWANCE);
        faucet.setClaimAllowance(Tier.Lite, USDT_ID, LITE_STABLE_ALLOWANCE);
        faucet.setClaimAllowance(Tier.Full, PAS, FULL_PAS_ALLOWANCE);

        vm.deal(address(faucet), 1e6 * 1e18);
        pusd.mint(address(faucet), 1e6 * 1e6);
        usdt.mint(address(faucet), 1e6 * 1e6);
    }

    // Formats

    function test_claimMessageFor_layout() public view {
        bytes memory message = faucet.claimMessageFor(START_EPOCH, RECIPIENT, USDT_ID, 5e6);
        bytes memory expected = bytes.concat(
            hex"706173656f2d6661756365743a636c61696d3a7631",
            bytes20(address(faucet)),
            hex"00000000190f1b41",
            hex"0000000000004e20",
            RECIPIENT,
            hex"000007c0",
            hex"000000000000000000000000004c4b40"
        );
        assertEq(message.length, 109);
        assertEq(message, expected);
    }

    function test_claimDomain_differsFromTheDripDomain() public view {
        assertTrue(bytes32(faucet.CLAIM_DOMAIN()) != bytes32(faucet.DOMAIN()));
    }

    function test_assetToken_isThePalletAssetsPrecompile() public view {
        assertEq(address(faucet.assetToken(PUSD_ID)), address(faucet.PUSD()));
        assertEq(address(faucet.assetToken(USDT_ID)), address(bytes20(hex"000007c000000000000000000000000001200000")));
    }

    // Claim

    function test_claim_paysPas() public {
        _prove(Tier.Lite, PAS, 1_000e10);
        _expectClaimed(Tier.Lite, PAS, 1_000e10);
        _claim(Tier.Lite, PAS, 1_000e10);

        _assertExecuted(XcmProgram.depositOne(RECIPIENT, PAS, 1_000e10));
        assertEq(faucet.claimed(START_EPOCH, Tier.Lite, ALIAS, PAS), 1_000e10);
        assertTrue(_paid(Tier.Lite, PAS, 1_000e10));
        assertEq(faucet.claimsInEpoch(START_EPOCH), 1);
    }

    function test_claim_paysAPalletAsset() public {
        _prove(Tier.Lite, USDT_ID, 70_000);
        _expectClaimed(Tier.Lite, USDT_ID, 70_000);
        _claim(Tier.Lite, USDT_ID, 70_000);

        _assertExecuted(XcmProgram.depositOne(RECIPIENT, USDT_ID, 70_000));
        assertEq(faucet.claimed(START_EPOCH, Tier.Lite, ALIAS, USDT_ID), 70_000);
    }

    function test_claim_aClaimPaysOnce() public {
        _prove(Tier.Lite, PUSD_ID, 10e6);
        _claim(Tier.Lite, PUSD_ID, 10e6);
        _expectClaimRevert(Tier.Lite, PUSD_ID, 10e6, PaseoFaucet.AlreadyClaimed.selector);

        _prove(Tier.Lite, PUSD_ID, 11e6);
        _claim(Tier.Lite, PUSD_ID, 11e6);
        assertEq(faucet.claimed(START_EPOCH, Tier.Lite, ALIAS, PUSD_ID), 21e6);
        assertEq(faucet.claimsInEpoch(START_EPOCH), 2);
    }

    function test_claimKey_bindsRecipientAssetAndAmount() public view {
        bytes32 key = faucet.claimKey(RECIPIENT, PUSD_ID, 10e6);
        assertEq(key, keccak256(abi.encode(RECIPIENT, PUSD_ID, uint128(10e6))));
        assertTrue(key != faucet.claimKey(bytes32(uint256(1)), PUSD_ID, 10e6));
        assertTrue(key != faucet.claimKey(RECIPIENT, USDT_ID, 10e6));
        assertTrue(key != faucet.claimKey(RECIPIENT, PUSD_ID, 10e6 + 1));
    }

    function test_claim_theProofBindsRecipientAssetAmountAndTier() public {
        faucet.setClaimAllowance(Tier.Full, PUSD_ID, LITE_STABLE_ALLOWANCE);
        _prove(Tier.Lite, PUSD_ID, 10e6);
        vm.expectRevert(PaseoFaucet.InvalidProof.selector);
        faucet.claim(Tier.Lite, bytes32(uint256(1)), PUSD_ID, 10e6, PROOF, ALIAS, RING, REVISION);
        vm.expectRevert(PaseoFaucet.InvalidProof.selector);
        _claim(Tier.Lite, USDT_ID, 10e6);
        vm.expectRevert(PaseoFaucet.InvalidProof.selector);
        _claim(Tier.Lite, PUSD_ID, 10e6 + 1);
        vm.expectRevert(PaseoFaucet.InvalidProof.selector);
        _claim(Tier.Full, PUSD_ID, 10e6);
    }

    function test_claim_allowanceIsPerTierAssetAndEpoch() public {
        _prove(Tier.Lite, PAS, MAX_PAS);
        _claim(Tier.Lite, PAS, MAX_PAS);
        _expectClaimRevert(Tier.Lite, PAS, 1, PaseoFaucet.AllowanceExceeded.selector);

        _prove(Tier.Lite, USDT_ID, 1e6);
        _claim(Tier.Lite, USDT_ID, 1e6);
        _prove(Tier.Full, PAS, MAX_PAS);
        _claim(Tier.Full, PAS, MAX_PAS);

        vm.warp((START_EPOCH + 1) * EPOCH_SECONDS);
        uint64 next = START_EPOCH + 1;
        personhood.accept(_request(Tier.Lite, next, PAS, MAX_PAS));
        _claim(Tier.Lite, PAS, MAX_PAS);
        assertEq(faucet.claimed(next, Tier.Lite, ALIAS, PAS), MAX_PAS);
        assertEq(faucet.claimed(START_EPOCH, Tier.Lite, ALIAS, PAS), MAX_PAS);
    }

    function test_claim_tierWithoutAllowanceIsRefused() public {
        _expectClaimRevert(Tier.Full, USDT_ID, 1e6, PaseoFaucet.AllowanceExceeded.selector);
        _expectClaimRevert(Tier.None, PAS, 1e10, PaseoFaucet.AllowanceExceeded.selector);
    }

    function test_claim_checksBeforeTheProof() public {
        faucet.pause();
        _expectClaimRevert(Tier.Lite, PAS, 1e10, PaseoFaucet.FaucetPaused.selector);
        faucet.unpause();

        _expectClaimRevert(Tier.Lite, 1337, 1e6, PaseoFaucet.UnknownAsset.selector);
        faucet.setClaimAsset(USDT_ID, ClaimAsset(false, MAX_STABLE));
        _expectClaimRevert(Tier.Lite, USDT_ID, 1e6, PaseoFaucet.UnknownAsset.selector);

        _expectClaimRevert(Tier.Lite, PAS, 0, PaseoFaucet.ClaimTooLarge.selector);
        _expectClaimRevert(Tier.Lite, PAS, MAX_PAS + 1, PaseoFaucet.ClaimTooLarge.selector);

        vm.deal(address(faucet), 1e10 * 1e8 - 1);
        _expectClaimRevert(Tier.Lite, PAS, 1e10, PaseoFaucet.InsufficientFunds.selector);
        deal(address(pusd), address(faucet), 1e6 - 1);
        _expectClaimRevert(Tier.Lite, PUSD_ID, 1e6, PaseoFaucet.InsufficientFunds.selector);

        _expectClaimRevert(Tier.Lite, USDT_ID, 1e6, PaseoFaucet.UnknownAsset.selector);
        _assertNothingRecorded();
    }

    function test_claim_epochCapCountsEveryClaim() public {
        faucet.setMaxClaimsPerEpoch(2);
        _prove(Tier.Lite, PAS, 1e10);
        _claim(Tier.Lite, PAS, 1e10);
        _prove(Tier.Lite, PAS, 2e10);
        _claim(Tier.Lite, PAS, 2e10);
        _prove(Tier.Lite, PAS, 3e10);
        _expectClaimRevert(Tier.Lite, PAS, 3e10, PaseoFaucet.EpochCapReached.selector);
        assertEq(faucet.claimsInEpoch(START_EPOCH), 2);
    }

    function test_claim_failedPayoutRecordsNothing() public {
        xcm.setFails(XcmProgram.depositOne(RECIPIENT, PUSD_ID, 1e6), true);
        _prove(Tier.Lite, PUSD_ID, 1e6);
        _expectClaimRevert(Tier.Lite, PUSD_ID, 1e6, PaseoFaucet.PayoutFailed.selector);
        _assertNothingRecorded();
    }

    function test_claim_revertsWhenThePayoutTakesMorePasThanClaimed() public {
        xcm.setOutflow(1);
        _prove(Tier.Lite, USDT_ID, 1e6);
        _expectClaimRevert(Tier.Lite, USDT_ID, 1e6, PaseoFaucet.PayoutFailed.selector);

        xcm.setOutflow(1e10 * 1e8 + 1);
        _prove(Tier.Lite, PAS, 1e10);
        _expectClaimRevert(Tier.Lite, PAS, 1e10, PaseoFaucet.PayoutFailed.selector);

        xcm.setOutflow(1e10 * 1e8);
        _claim(Tier.Lite, PAS, 1e10);
        assertTrue(_paid(Tier.Lite, PAS, 1e10));
    }

    function test_claim_anyoneCanSubmitAProof() public {
        _prove(Tier.Lite, PAS, 1e10);
        vm.prank(stranger);
        _claim(Tier.Lite, PAS, 1e10);
        assertTrue(_paid(Tier.Lite, PAS, 1e10));
    }

    // Owner

    function test_claimSettings_onlyOwner() public {
        vm.startPrank(stranger);
        vm.expectRevert(PaseoFaucet.NotOwner.selector);
        faucet.setClaimAsset(PAS, ClaimAsset(true, 1));
        vm.expectRevert(PaseoFaucet.NotOwner.selector);
        faucet.setClaimAllowance(Tier.Lite, PAS, 1);
        vm.expectRevert(PaseoFaucet.NotOwner.selector);
        faucet.setMaxClaimsPerEpoch(1);
        vm.expectRevert(PaseoFaucet.NotOwner.selector);
        faucet.withdrawAsset(USDT_ID, 1);
        vm.stopPrank();
    }

    function test_claimSettings_validateAndEmit() public {
        vm.expectRevert(PaseoFaucet.InvalidConfig.selector);
        faucet.setClaimAsset(PAS, ClaimAsset(true, 0));
        vm.expectRevert(PaseoFaucet.InvalidConfig.selector);
        faucet.setClaimAllowance(Tier.None, PAS, 1);

        vm.expectEmit(address(faucet));
        emit PaseoFaucet.ClaimAssetSet(1337, ClaimAsset(true, 7));
        faucet.setClaimAsset(1337, ClaimAsset(true, 7));
        (bool enabled, uint128 maxClaim) = faucet.claimAsset(1337);
        assertTrue(enabled);
        assertEq(maxClaim, 7);

        vm.expectEmit(address(faucet));
        emit PaseoFaucet.ClaimAllowanceSet(Tier.Full, 1337, 9);
        faucet.setClaimAllowance(Tier.Full, 1337, 9);
        assertEq(faucet.claimAllowance(Tier.Full, 1337), 9);

        vm.expectEmit(address(faucet));
        emit PaseoFaucet.ClaimCapUpdated(3);
        faucet.setMaxClaimsPerEpoch(3);
        assertEq(faucet.maxClaimsPerEpoch(), 3);

        faucet.setClaimAsset(1337, ClaimAsset(false, 0));
        (enabled,) = faucet.claimAsset(1337);
        assertFalse(enabled);
    }

    function test_withdrawAsset_paysTheOwner() public {
        vm.expectEmit(address(faucet));
        emit PaseoFaucet.AssetWithdrawn(address(this), USDT_ID, 4e6);
        faucet.withdrawAsset(USDT_ID, 4e6);
        assertEq(usdt.balanceOf(address(this)), 4e6);
    }

    function test_withdrawAsset_failuresRevert() public {
        vm.expectRevert(PaseoFaucet.PayoutFailed.selector);
        faucet.withdrawAsset(PAS, 1);
        vm.expectRevert(PaseoFaucet.PayoutFailed.selector);
        faucet.withdrawAsset(USDT_ID, 1e6 * 1e6 + 1);
    }

    // Helpers

    function _request(Tier tier, uint64 epoch, uint32 asset, uint128 amount)
        internal
        view
        returns (IPersonhood.ProofVerificationRequest memory)
    {
        return IPersonhood.ProofVerificationRequest({
            expectedStatus: uint8(tier),
            proof: PROOF,
            expectedAlias: ALIAS,
            ringIndex: RING,
            context: faucet.contextFor(epoch),
            revision: REVISION,
            message: faucet.claimMessageFor(epoch, RECIPIENT, asset, amount)
        });
    }

    function _prove(Tier tier, uint32 asset, uint128 amount) internal {
        personhood.accept(_request(tier, START_EPOCH, asset, amount));
    }

    function _claim(Tier tier, uint32 asset, uint128 amount) internal {
        faucet.claim(tier, RECIPIENT, asset, amount, PROOF, ALIAS, RING, REVISION);
    }

    function _expectClaimRevert(Tier tier, uint32 asset, uint128 amount, bytes4 selector) internal {
        vm.expectRevert(selector);
        _claim(tier, asset, amount);
    }

    function _expectClaimed(Tier tier, uint32 asset, uint128 amount) internal {
        vm.expectEmit(address(faucet));
        emit PaseoFaucet.Claimed(START_EPOCH, tier, ALIAS, RECIPIENT, asset, amount);
    }

    function _assertExecuted(bytes memory program) internal view {
        (bytes[] memory messages, IXcm.Weight[] memory weights) = xcm.executed();
        assertEq(messages.length, 1);
        assertEq(messages[0], program);
        assertEq(weights[0].refTime, program.length * 1000);
    }

    function _paid(Tier tier, uint32 asset, uint128 amount) internal view returns (bool) {
        return faucet.claimPaid(START_EPOCH, tier, ALIAS, faucet.claimKey(RECIPIENT, asset, amount));
    }

    function _assertNothingRecorded() internal view {
        assertEq(faucet.claimsInEpoch(START_EPOCH), 0);
        assertEq(faucet.claimed(START_EPOCH, Tier.Lite, ALIAS, PUSD_ID), 0);
        (bytes[] memory messages,) = xcm.executed();
        assertEq(messages.length, 0);
    }
}
