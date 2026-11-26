// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {IXcm, XCM_PRECOMPILE_ADDRESS} from "../../src/interfaces/IXcm.sol";

/// @notice Test-only contract that runs any XCM program with its own origin. Never deploy it with real funds.
contract XcmForwarder {
    IXcm constant XCM = IXcm(XCM_PRECOMPILE_ADDRESS);

    function run(bytes calldata message) external {
        XCM.execute(message, XCM.weighMessage(message));
    }

    receive() external payable {}
}
