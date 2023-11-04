// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import {MyHook} from "./MyHook.sol";

import {BaseHook} from "periphery-next/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

contract MyHookStub is MyHook {
    constructor(
        IPoolManager _poolManager,
        MyHook addressToEtch
    ) MyHook(_poolManager) {}

    // make this a no-op in testing
    function validateHookAddress(BaseHook _this) internal pure override {}
}