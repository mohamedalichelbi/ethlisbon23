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

    
    int24 internal constant TICK_SPACING = 60;
    // three ticks, each 60 spacing
    int24 internal constant TICK_RADIUS = 3 * TICK_SPACING;

    int24 prevCenterTick;

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
                beforeInitialize: true,
                afterInitialize: false,
                beforeModifyPosition: false,
                afterModifyPosition: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false
        });
    }

    function beforeInitialize(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        bytes calldata hookData
    ) external override returns (bytes4) {
        console.logString("beforeInitialize hook triggered...");
        selfKisser.selfKiss(address(0xc8A1F9461115EF3C1E84Da6515A88Ea49CA97660), address(this));
        prevCenterTick = 0;
        return MyHook.beforeInitialize.selector;
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

        uint oraclePrice = oracle.read() / 10**18;
        console.logString("Oracle price:");
        console.logUint(oraclePrice);

        uint160 newSqrtPriceX96 = sqrtX96ify(oraclePrice);

        int24 targetTick = TickMath.getTickAtSqrtRatio(newSqrtPriceX96);
        int24 centerTick = (targetTick / TICK_SPACING) * TICK_SPACING;

        // (1) withdraw all liquidity
        BalanceDelta balanceDelta = _withdrawLiquidity(key);
        
        // (2) slip to oracle price
        _slipToOraclePrice(key, newSqrtPriceX96);

        // (3) redeposit all liquidity

        console.logString("(3) redeposit all liquidity...");

        console.logString("balanceDelta.amount0():");
        console.logInt(balanceDelta.amount0());
        console.logString("balanceDelta.amount1():");
        console.logInt(balanceDelta.amount1());

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            newSqrtPriceX96,
            TickMath.getSqrtRatioAtTick(centerTick - TICK_RADIUS),
            TickMath.getSqrtRatioAtTick(centerTick + TICK_RADIUS),
            uint256(uint128(-balanceDelta.amount0())),
            uint256(uint128(-balanceDelta.amount1()))
        );

        console.logString("liquidity:");
        console.logUint(liquidity);

        BalanceDelta balanceDeltaAfter = _modifyPosition(
            address(this),
            key,
            IPoolManager.ModifyPositionParams({
                tickLower: centerTick - TICK_RADIUS,
                tickUpper: centerTick + TICK_RADIUS,
                liquidityDelta: liquidity.toInt256()
            })
        );

        console.logString("balanceDeltaAfter.amount0():");
        console.logInt(balanceDeltaAfter.amount0());
        console.logString("balanceDeltaAfter.amount1():");
        console.logInt(balanceDeltaAfter.amount1());

        prevCenterTick = centerTick;
        return MyHook.beforeSwap.selector;
    }

    function _withdrawLiquidity(PoolKey memory key) internal returns (BalanceDelta) {

        console.logString("(1) withdrawing all liquidity...");

        PoolId poolId = key.toId();

        uint128 fullRangeLiquidity = poolManager.getLiquidity(
            poolId, 
            address(this),
            prevCenterTick - TICK_RADIUS,
            prevCenterTick + TICK_RADIUS
        );

        console.logString("fullRangeLiquidity:");
        console.logUint(fullRangeLiquidity);

        return _modifyPosition(
            address(this),
            key,
            IPoolManager.ModifyPositionParams({
                tickLower: prevCenterTick - TICK_RADIUS,
                tickUpper: prevCenterTick + TICK_RADIUS,
                liquidityDelta: -(fullRangeLiquidity.toInt256())
            })
        );

    }

    function _slipToOraclePrice(PoolKey memory key, uint160 newSqrtPriceX96) internal {

        console.logString("(2) splipping to oracle price...");

        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        
        console.logString("sqrtPriceX96:");
        console.logUint(sqrtPriceX96);
        console.logString("newSqrtPriceX96:");
        console.logUint(newSqrtPriceX96);

        console.logString("Swapping...");

        _swap(
            address(this),
            key,
            IPoolManager.SwapParams({
                zeroForOne: newSqrtPriceX96 < sqrtPriceX96,
                amountSpecified: MAX_INT,
                sqrtPriceLimitX96: newSqrtPriceX96
            })
        );

        (uint160 sqrtPriceX96AfterSwap,,,) = poolManager.getSlot0(poolId);
        console.logString("sqrtPriceX96AfterSwap:");
        console.logUint(sqrtPriceX96AfterSwap);

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
        _swap(sender, poolKey, params);
    }

    function _swap(
        address sender,
        PoolKey memory poolKey,
        IPoolManager.SwapParams memory params
    ) internal {
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
            delta = _handleModifyPosition(modifyPositionData.sender, modifyPositionData.poolKey, modifyPositionData.params);
            
        }
        else if (data.reason == 1) {
            console.logString("LockAcquired: REASON 1");
            SwapData memory swapData = abi.decode(data.raw, (SwapData));
            delta = _handleSwap(swapData.sender, swapData.poolKey, swapData.params);
        }

        return abi.encode(delta);
    }

    function _handleModifyPosition(
        address sender,
        PoolKey memory key,
        IPoolManager.ModifyPositionParams memory params
    ) internal returns (BalanceDelta) {
        BalanceDelta delta = poolManager.modifyPosition(key, params, ZERO_BYTES);

        console.logString("delta.amount0():");
        console.logInt(delta.amount0());
        console.logString("delta.amount1():");
        console.logInt(delta.amount1());

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

        return delta;
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

    function _handleSwap(
        address sender,
        PoolKey memory key,
        IPoolManager.SwapParams memory params
    ) internal returns (BalanceDelta) {
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

        return delta;
    }

}
