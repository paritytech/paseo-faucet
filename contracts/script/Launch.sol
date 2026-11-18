// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Destination} from "../src/PaseoFaucet.sol";
import {Transfer} from "../src/XcmProgram.sol";

/// @notice The destinations the faucet launches with, apart from the deploy so that fork/check.ts can read them
///         from a contract that does not embed the faucet's creation code.
/// @dev PAS amounts are plancks, pUSD amounts are base units. fork/check.ts measures each launch entry against its
///      destination. Bulletin, Asset Hub Next, Bulletin Next and People Next take PAS only: none of them holds
///      Asset Hub's pUSD. Other chains are added with `setDestination` once a transfer to the live chain has arrived.
contract Launch {
    uint32 constant ASSET_HUB = 1000;
    uint32 constant PEOPLE = 1004;
    uint32 constant BULLETIN = 1010;
    uint32 constant ASSET_HUB_NEXT = 1500;
    uint32 constant BULLETIN_NEXT = 1501;
    uint32 constant PEOPLE_NEXT = 1502;

    uint128 constant ASSET_HUB_ED = 1e8;
    uint128 constant PEOPLE_ED = 1e9;
    uint128 constant BULLETIN_ED = 1e9;
    uint128 constant ASSET_HUB_NEXT_ED = 1e8;
    uint128 constant REMOTE_FEE = 1e8;
    uint128 constant BULLETIN_REMOTE_FEE = 1e9;
    uint128 constant MAX_DELIVERY_FEE = 5e9;
    uint128 constant ASSET_HUB_MIN_PUSD = 10;
    uint128 constant PEOPLE_MIN_PUSD = 10_000;

    /// @notice The destinations the faucet launches with.
    function launch() public pure returns (Destination[6] memory) {
        return [
            Destination(ASSET_HUB, true, Transfer.Local, Transfer.Local, 0, 0, ASSET_HUB_ED, ASSET_HUB_MIN_PUSD),
            Destination(
                PEOPLE,
                true,
                Transfer.Teleport,
                Transfer.Teleport,
                REMOTE_FEE,
                MAX_DELIVERY_FEE,
                PEOPLE_ED + REMOTE_FEE,
                PEOPLE_MIN_PUSD
            ),
            _pasOnly(BULLETIN, BULLETIN_REMOTE_FEE, BULLETIN_ED),
            _pasOnly(ASSET_HUB_NEXT, REMOTE_FEE, ASSET_HUB_NEXT_ED),
            _pasOnly(BULLETIN_NEXT, BULLETIN_REMOTE_FEE, BULLETIN_ED),
            _pasOnly(PEOPLE_NEXT, REMOTE_FEE, PEOPLE_ED)
        ];
    }

    /// @notice A system chain that takes teleported PAS and no pUSD.
    function _pasOnly(uint32 id, uint128 remoteFee, uint128 existentialDeposit)
        private
        pure
        returns (Destination memory)
    {
        return Destination(
            id, true, Transfer.Teleport, Transfer.None, remoteFee, MAX_DELIVERY_FEE, existentialDeposit + remoteFee, 0
        );
    }
}
