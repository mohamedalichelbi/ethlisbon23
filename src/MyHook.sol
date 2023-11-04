// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {BaseHook} from "periphery-next/BaseHook.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {LiquidityAmounts} from "periphery-next/libraries/LiquidityAmounts.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {ILockCallback} from "v4-core/interfaces/callback/ILockCallback.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {UniswapV4ERC20} from "periphery-next/libraries/UniswapV4ERC20.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IChronicle} from "chronicle-std/src/IChronicle.sol";
import "forge-std/console.sol";

interface ISelfKisser {
    function selfKiss(address oracle, address who) external;
}   

contract MyHook is BaseHook, ILockCallback {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using SafeCast for uint128;
    
    bytes internal constant ZERO_BYTES = bytes("");
    /// @dev Min tick for full range with tick spacing of 60
    int24 internal constant MIN_TICK = -887220;
    /// @dev Max tick for full range with tick spacing of 60
    int24 internal constant MAX_TICK = -MIN_TICK;

    int256 internal constant MAX_INT = type(int256).max;

    IChronicle constant oracle = IChronicle(address(0xc8A1F9461115EF3C1E84Da6515A88Ea49CA97660));
    ISelfKisser constant selfKisser = ISelfKisser(address(0x0Dcc19657007713483A5cA76e6A7bbe5f56EA37d));

    struct CallbackData {
        uint8 reason;
        bytes raw;
    }

    struct ModifyPositionData {
        address sender;
        PoolKey poolKey;
        IPoolManager.ModifyPositionParams params;
    }

    struct SwapData {
        address sender;
        PoolKey poolKey;
        IPoolManager.SwapParams params;
    }

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    // Required override function for BaseHook to let the PoolManager know which hooks are implemented
    function getHooksCalls() public pure override returns (Hooks.Calls memory) {
        return Hooks.Calls({
                beforeInitialize: false,
                afterInitialize: false,
                beforeModifyPosition: false,
                afterModifyPosition: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false
        });
    }

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) external override returns (bytes4) {

        // prevent infinite loops
        if (sender == address(this)) { 
            console.logString("Self invokation mitigated");
            return MyHook.beforeSwap.selector;
        }

        console.logString("beforeSwap hook triggered, rebalancing...");

        // TODO only rebalance if oracle balance moved by x%

        // three ticks, each 60 spacing
        int24 tickRadius = 3 * 60;

        uint oraclePrice = oracle.read();
        uint160 newSqrtPriceX96 = sqrtX96ify(oraclePrice);

        int24 centerTick = TickMath.getTickAtSqrtRatio(newSqrtPriceX96);
        int24 lowerTick = centerTick - tickRadius;
        int24 upperTick = centerTick + tickRadius;

        // (1) withdraw all liquidity

        console.logString("(1) withdrawing all liquidity...");
        PoolId poolId = key.toId();
        BalanceDelta balanceDelta = _modifyPosition(
            address(this),
            key,
            IPoolManager.ModifyPositionParams({
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                liquidityDelta: -(poolManager.getLiquidity(poolId).toInt256())
            })
        );

        // (2)

        return MyHook.beforeSwap.selector;
    }

    function modifyPosition(
        address sender,
        PoolKey calldata poolKey,
        IPoolManager.ModifyPositionParams calldata params
    ) external {
        _modifyPosition(sender, poolKey, params);
    }

    function _modifyPosition(
        address sender,
        PoolKey memory poolKey,
        IPoolManager.ModifyPositionParams memory params
    ) internal returns (BalanceDelta) {
        return abi.decode(poolManager.lock(abi.encode(
            CallbackData(0, abi.encode(ModifyPositionData(sender, poolKey, params)))
        )), (BalanceDelta));
    }

    function swap(
        address sender,
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata params
    ) external {
        poolManager.lock(abi.encode(
            CallbackData(1, abi.encode(SwapData(sender, poolKey, params)))
        ));
    }

    function lockAcquired(bytes calldata rawData)
        external
        override(ILockCallback, BaseHook)
        poolManagerOnly
        returns (bytes memory)
    {
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        BalanceDelta delta;

        // Reason 0: modifyPosition
        if (data.reason == 0) {
            console.logString("LockAcquired: REASON 0");
            ModifyPositionData memory modifyPositionData = abi.decode(data.raw, (ModifyPositionData));
            _handleModifyPosition(modifyPositionData.sender, modifyPositionData.poolKey, modifyPositionData.params);
        }
        else if (data.reason == 1) {
            console.logString("LockAcquired: REASON 1");
            SwapData memory swapData = abi.decode(data.raw, (SwapData));
            _handleSwap(swapData.sender, swapData.poolKey, swapData.params);
        }


        return abi.encode(true);
    }

    function _handleModifyPosition(
        address sender,
        PoolKey memory key,
        IPoolManager.ModifyPositionParams memory params
    ) internal {
        BalanceDelta delta = poolManager.modifyPosition(key, params, ZERO_BYTES);

        if (delta.amount0() > 0) {
            if (key.currency0.isNative()) {
                poolManager.settle{value: uint128(delta.amount0())}(key.currency0);
            } else {
                IERC20Minimal(Currency.unwrap(key.currency0)).transferFrom(
                    sender, address(poolManager), uint128(delta.amount0())
                );
                poolManager.settle(key.currency0);
            }
        }
        if (delta.amount1() > 0) {
            if (key.currency1.isNative()) {
                poolManager.settle{value: uint128(delta.amount1())}(key.currency1);
            } else {
                IERC20Minimal(Currency.unwrap(key.currency1)).transferFrom(
                    sender, address(poolManager), uint128(delta.amount1())
                );
                poolManager.settle(key.currency1);
            }
        }

        if (delta.amount0() < 0) {
            poolManager.take(key.currency0, sender, uint128(-delta.amount0()));
        }
        if (delta.amount1() < 0) {
            poolManager.take(key.currency1, sender, uint128(-delta.amount1()));
        }
    }

    // function sqrtX96ify_funky(uint price) internal returns (uint160) {
    //     return (
    //         FixedPointMathLib.sqrt(
    //             price * FixedPoint96.Q96
    //         ) * FixedPointMathLib.sqrt(FixedPoint96.Q96)
    //     ).toUint160();
    // }

    function sqrtX96ify(uint price) internal returns (uint160) {
        return (
            FixedPointMathLib.sqrt(price) * FixedPoint96.Q96
        ).toUint160();
    }

    function kissSelf() external {
        selfKisser.selfKiss(address(0xc8A1F9461115EF3C1E84Da6515A88Ea49CA97660), address(this));
    }

    function _handleSwap(
        address sender,
        PoolKey memory key,
        IPoolManager.SwapParams memory params
    ) internal {
        BalanceDelta delta = poolManager.swap(key, params, ZERO_BYTES);

        if (params.zeroForOne) {
            if (delta.amount0() > 0) {
                if (key.currency0.isNative()) {
                    poolManager.settle{value: uint128(delta.amount0())}(key.currency0);
                } else {
                    IERC20Minimal(Currency.unwrap(key.currency0)).transferFrom(
                        sender, address(poolManager), uint128(delta.amount0())
                    );
                    poolManager.settle(key.currency0);
                }
            }
            if (delta.amount1() < 0) {
                poolManager.take(key.currency1, sender, uint128(-delta.amount1()));
            }
        } else {
            if (delta.amount1() > 0) {
                if (key.currency1.isNative()) {
                    poolManager.settle{value: uint128(delta.amount1())}(key.currency1);
                } else {
                    IERC20Minimal(Currency.unwrap(key.currency1)).transferFrom(
                        sender, address(poolManager), uint128(delta.amount1())
                    );
                    poolManager.settle(key.currency1);
                }
            }
            if (delta.amount0() < 0) {
                poolManager.take(key.currency0, sender, uint128(-delta.amount0()));
            }
        }
    }

}
