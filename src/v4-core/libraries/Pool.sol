// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {SafeCast} from "./SafeCast.sol";
import {TickBitmap} from "./TickBitmap.sol";
import {Position} from "./Position.sol";
import {UnsafeMath} from "./UnsafeMath.sol";
import {FixedPoint128} from "./FixedPoint128.sol";
import {TickMath} from "./TickMath.sol";
import {SqrtPriceMath} from "./SqrtPriceMath.sol";
import {SwapMath} from "./SwapMath.sol";
import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "../types/BalanceDelta.sol";
import {Slot0} from "../types/Slot0.sol";
import {ProtocolFeeLibrary} from "./ProtocolFeeLibrary.sol";
import {LiquidityMath} from "./LiquidityMath.sol";
import {LPFeeLibrary} from "./LPFeeLibrary.sol";
import {CustomRevert} from "./CustomRevert.sol";

/// @notice 实现单个 Uniswap V4 池可执行的全部核心状态操作。
/// @dev PoolManager 负责统一保管资产和外部入口，本库专注于每个池的价格、流动性、tick、仓位与手续费会计。
library Pool {
    using SafeCast for *;
    using TickBitmap for mapping(int16 => uint256);
    using Position for mapping(bytes32 => Position.State);
    using Position for Position.State;
    using Pool for State;
    using ProtocolFeeLibrary for *;
    using LPFeeLibrary for uint24;
    using CustomRevert for bytes4;

    /// @notice tickLower 不小于 tickUpper 时抛出。
    /// @param tickLower 无效的下边界 tick。
    /// @param tickUpper 无效的上边界 tick。
    error TicksMisordered(int24 tickLower, int24 tickUpper);

    /// @notice tickLower 小于最小 tick 时抛出。
    /// @param tickLower 无效的下边界 tick。
    error TickLowerOutOfBounds(int24 tickLower);

    /// @notice tickUpper 超过最大 tick 时抛出。
    /// @param tickUpper 无效的上边界 tick。
    error TickUpperOutOfBounds(int24 tickUpper);

    /// @notice 在当前 tick spacing 下，某个 tick 引用的总流动性超过安全上限。
    error TickLiquidityOverflow(int24 tick);

    /// @notice 尝试重复初始化已初始化池时抛出。
    error PoolAlreadyInitialized();

    /// @notice 尝试与尚未初始化的池交互时抛出。
    error PoolNotInitialized();

    /// @notice swap 开始前当前价格已经越过指定 sqrtPriceLimitX96 时抛出。
    /// @param sqrtPriceCurrentX96 已越过限制的当前价格。
    /// @param sqrtPriceLimitX96 被越过的价格限制。
    error PriceLimitAlreadyExceeded(uint160 sqrtPriceCurrentX96, uint160 sqrtPriceLimitX96);

    /// @notice sqrtPriceLimitX96 位于有效 tick/价格范围之外时抛出。
    /// @param sqrtPriceLimitX96 越界的无效价格限制。
    error PriceLimitOutOfBounds(uint160 sqrtPriceLimitX96);

    /// @notice 当前活跃流动性为 0 时禁止 donate，因为没有 LP 可以接收这笔费用。
    error NoLiquidityToReceiveFees();

    /// @notice 费率为 100% 时尝试执行 exact output swap 会抛出。
    error InvalidFeeForExactOut();

    // 每个已初始化 tick 保存的信息。
    struct TickInfo {
        // 所有把该 tick 作为上/下边界的仓位流动性总和。
        uint128 liquidityGross;
        // 从左向右跨越该 tick 时净增加的流动性；从右向左跨越时使用相反符号。
        int128 liquidityNet;
        // 相对当前 tick，边界另一侧每单位流动性的手续费增长。
        // 该值只有相对意义而无绝对意义，因为其初值取决于 tick 在何时被初始化。
        uint256 feeGrowthOutside0X128;
        uint256 feeGrowthOutside1X128;
    }

    /// @notice 单个池的完整状态。
    /// @dev feeGrowthGlobal 可被人为放大。若池只有一个流动性仓位，参与者可以向自己所在池 donate，
    ///      再领取同一笔费用；在同一个 unlockCallback 中原子执行 donate 与 collect 会让数值膨胀更明显。
    ///      因此外部集成不应把全局手续费增长直接视为不可操纵的市场指标。
    struct State {
        Slot0 slot0;
        uint256 feeGrowthGlobal0X128;
        uint256 feeGrowthGlobal1X128;
        uint128 liquidity;
        mapping(int24 tick => TickInfo) ticks;
        mapping(int16 wordPos => uint256) tickBitmap;
        mapping(bytes32 positionKey => Position.State) positions;
    }

    /// @dev 对仓位上下边界执行公共有效性检查。
    function checkTicks(int24 tickLower, int24 tickUpper) private pure {
        if (tickLower >= tickUpper) TicksMisordered.selector.revertWith(tickLower, tickUpper);
        if (tickLower < TickMath.MIN_TICK) TickLowerOutOfBounds.selector.revertWith(tickLower);
        if (tickUpper > TickMath.MAX_TICK) TickUpperOutOfBounds.selector.revertWith(tickUpper);
    }

    function initialize(State storage self, uint160 sqrtPriceX96, uint24 lpFee) internal returns (int24 tick) {
        if (self.slot0.sqrtPriceX96() != 0) PoolAlreadyInitialized.selector.revertWith();

        tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        // 初始 protocolFee 为 0，因此无需单独写入。
        self.slot0 = Slot0.wrap(bytes32(0)).setSqrtPriceX96(sqrtPriceX96).setTick(tick).setLpFee(lpFee);
    }

    function setProtocolFee(State storage self, uint24 protocolFee) internal {
        self.checkPoolInitialized();
        self.slot0 = self.slot0.setProtocolFee(protocolFee);
    }

    /// @notice 更新池当前 LP fee；上层只允许动态费率池走到此逻辑。
    function setLPFee(State storage self, uint24 lpFee) internal {
        self.checkPoolInitialized();
        self.slot0 = self.slot0.setLpFee(lpFee);
    }

    struct ModifyLiquidityParams {
        // 仓位所有者地址。
        address owner;
        // 仓位的下边界与上边界 tick。
        int24 tickLower;
        int24 tickUpper;
        // 流动性变化量：正数增加，负数移除，0 表示只结算手续费。
        int128 liquidityDelta;
        // 可用 tick 之间的间距。
        int24 tickSpacing;
        // 区分同一 owner 在相同 tick 区间内的多个仓位。
        bytes32 salt;
    }

    struct ModifyLiquidityState {
        bool flippedLower;
        uint128 liquidityGrossAfterLower;
        bool flippedUpper;
        uint128 liquidityGrossAfterUpper;
    }

    /// @notice 修改池中的一个仓位，并结算该仓位自上次更新以来的手续费。
    /// @dev PoolManager 在调用前检查池已初始化。本函数依次更新边界 tick、bitmap、仓位手续费快照，
    ///      再根据当前价格位于区间下方、区间内或区间上方，计算 LP 应支付/收回的资产。
    /// @param params 仓位详情与要应用的流动性变化。
    /// @return delta 流动性变化导致的池 token 余额差额。
    /// @return feeDelta 该流动性区间已累计、应结算给仓位的手续费。
    function modifyLiquidity(State storage self, ModifyLiquidityParams memory params)
        internal
        returns (BalanceDelta delta, BalanceDelta feeDelta)
    {
        int128 liquidityDelta = params.liquidityDelta;
        int24 tickLower = params.tickLower;
        int24 tickUpper = params.tickUpper;
        checkTicks(tickLower, tickUpper);

        {
            ModifyLiquidityState memory state;

            // 只有流动性实际变化时才需要更新上下边界 tick。
            if (liquidityDelta != 0) {
                (state.flippedLower, state.liquidityGrossAfterLower) =
                    updateTick(self, tickLower, liquidityDelta, false);
                (state.flippedUpper, state.liquidityGrossAfterUpper) = updateTick(self, tickUpper, liquidityDelta, true);

                // 此处 `>` 与 `>=` 在逻辑上等价，但 `>=` 更省 gas。
                if (liquidityDelta >= 0) {
                    uint128 maxLiquidityPerTick = tickSpacingToMaxLiquidityPerTick(params.tickSpacing);
                    if (state.liquidityGrossAfterLower > maxLiquidityPerTick) {
                        TickLiquidityOverflow.selector.revertWith(tickLower);
                    }
                    if (state.liquidityGrossAfterUpper > maxLiquidityPerTick) {
                        TickLiquidityOverflow.selector.revertWith(tickUpper);
                    }
                }

                if (state.flippedLower) {
                    self.tickBitmap.flipTick(tickLower, params.tickSpacing);
                }
                if (state.flippedUpper) {
                    self.tickBitmap.flipTick(tickUpper, params.tickSpacing);
                }
            }

            {
                (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
                    getFeeGrowthInside(self, tickLower, tickUpper);

                Position.State storage position = self.positions.get(params.owner, tickLower, tickUpper, params.salt);
                (uint256 feesOwed0, uint256 feesOwed1) =
                    position.update(liquidityDelta, feeGrowthInside0X128, feeGrowthInside1X128);

                // 计算并返回该仓位提供流动性期间赚取的手续费。
                feeDelta = toBalanceDelta(feesOwed0.toInt128(), feesOwed1.toInt128());
            }

            // 移除流动性后，若某边界已无任何仓位引用，则清理其 tick 数据。
            if (liquidityDelta < 0) {
                if (state.flippedLower) {
                    clearTick(self, tickLower);
                }
                if (state.flippedUpper) {
                    clearTick(self, tickUpper);
                }
            }
        }

        if (liquidityDelta != 0) {
            Slot0 _slot0 = self.slot0;
            (int24 tick, uint160 sqrtPriceX96) = (_slot0.tick(), _slot0.sqrtPriceX96());
            if (tick < tickLower) {
                // 当前 tick 低于仓位区间。价格只有从左向右上涨后该流动性才会进入活跃区间；
                // 此时仓位完全由 currency0 构成，因此新增流动性只需用户提供 currency0。
                delta = toBalanceDelta(
                    SqrtPriceMath.getAmount0Delta(
                        TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), liquidityDelta
                    ).toInt128(),
                    0
                );
            } else if (tick < tickUpper) {
                delta = toBalanceDelta(
                    SqrtPriceMath.getAmount0Delta(sqrtPriceX96, TickMath.getSqrtPriceAtTick(tickUpper), liquidityDelta)
                        .toInt128(),
                    SqrtPriceMath.getAmount1Delta(TickMath.getSqrtPriceAtTick(tickLower), sqrtPriceX96, liquidityDelta)
                        .toInt128()
                );

                self.liquidity = LiquidityMath.addDelta(self.liquidity, liquidityDelta);
            } else {
                // 当前 tick 高于仓位区间。价格只有从右向左下跌后该流动性才会进入活跃区间；
                // 此时仓位完全由 currency1 构成，因此新增流动性只需用户提供 currency1。
                delta = toBalanceDelta(
                    0,
                    SqrtPriceMath.getAmount1Delta(
                        TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), liquidityDelta
                    ).toInt128()
                );
            }
        }
    }

    // 在整个 swap 循环中跟踪池状态，并在结束时返回最终值。
    struct SwapResult {
        // 当前 sqrt(price)。
        uint160 sqrtPriceX96;
        // 当前价格对应的 tick。
        int24 tick;
        // 当前价格区间内的活跃流动性。
        uint128 liquidity;
    }

    struct StepComputations {
        // 本步开始时的价格。
        uint160 sqrtPriceStartX96;
        // 沿兑换方向从当前 tick 出发将遇到的下一 tick。
        int24 tickNext;
        // tickNext 是否已初始化。
        bool initialized;
        // 下一 tick 对应的 sqrt(price)（currency1/currency0）。
        uint160 sqrtPriceNextX96;
        // 本步实际投入数量。
        uint256 amountIn;
        // 本步实际输出数量。
        uint256 amountOut;
        // 本步从输入中支付的手续费。
        uint256 feeAmount;
        // 输入 token 的全局手续费增长，在 swap 结束时统一写回 storage。
        uint256 feeGrowthGlobalX128;
    }

    struct SwapParams {
        int256 amountSpecified;
        int24 tickSpacing;
        bool zeroForOne;
        uint160 sqrtPriceLimitX96;
        uint24 lpFeeOverride;
    }

    /// @notice 在池状态上执行兑换，返回池的资产差额、协议费和最终价格/流动性。
    /// @dev PoolManager 在调用前检查池已初始化。兑换循环逐 word 寻找下一初始化 tick，
    ///      在每个流动性恒定区间内执行一步 SwapMath，跨边界后再更新活跃流动性。
    function swap(State storage self, SwapParams memory params)
        internal
        returns (BalanceDelta swapDelta, uint256 amountToProtocol, uint24 swapFee, SwapResult memory result)
    {
        Slot0 slot0Start = self.slot0;
        bool zeroForOne = params.zeroForOne;

        uint256 protocolFee =
            zeroForOne ? slot0Start.protocolFee().getZeroForOneFee() : slot0Start.protocolFee().getOneForZeroFee();

        // 输入/输出资产尚待兑换的数量，初始值为 amountSpecified。
        int256 amountSpecifiedRemaining = params.amountSpecified;
        // 已兑换出的输出资产或已投入的输入资产数量，初始为 0。
        int256 amountCalculated = 0;
        // 从当前 sqrt(price) 初始化结果。
        result.sqrtPriceX96 = slot0Start.sqrtPriceX96();
        // 从当前 tick 初始化结果。
        result.tick = slot0Start.tick();
        // 从当前活跃流动性初始化结果。
        result.liquidity = self.liquidity;

        // 若 beforeSwap hook 返回有效覆盖费率，则本次使用该 LP fee；否则读取池中存储值。
        // lpFee、swapFee 与 protocolFee 均以 pips 表示。
        {
            uint24 lpFee = params.lpFeeOverride.isOverride()
                ? params.lpFeeOverride.removeOverrideFlagAndValidate()
                : slot0Start.lpFee();

            swapFee = protocolFee == 0 ? lpFee : uint16(protocolFee).calculateSwapFee(lpFee);
        }

        // 总 swap fee 达到 MAX_SWAP_FEE（100%）时，输入会被手续费全部消耗，因此 exact output 不可能完成。
        if (swapFee >= SwapMath.MAX_SWAP_FEE) {
            // exactOutput。
            if (params.amountSpecified > 0) {
                InvalidFeeForExactOut.selector.revertWith();
            }
        }

        // swapFee 是池以 pips 表示的总费率（LP fee 与 protocol fee 的组合）。
        // 兑换数量为 0 时不收协议费，支付给协议的金额固定为 0。
        if (params.amountSpecified == 0) return (BalanceDeltaLibrary.ZERO_DELTA, 0, swapFee, result);

        if (zeroForOne) {
            if (params.sqrtPriceLimitX96 >= slot0Start.sqrtPriceX96()) {
                PriceLimitAlreadyExceeded.selector.revertWith(slot0Start.sqrtPriceX96(), params.sqrtPriceLimitX96);
            }
            // 除池初始化外，swap 永远不能在 MIN_TICK 成交，只能到 MIN_TICK + 1。
            // 在下文某些边界情况下，记录 tick 可能预先到达 MIN_TICK，但不会真的在该价格兑换。
            if (params.sqrtPriceLimitX96 <= TickMath.MIN_SQRT_PRICE) {
                PriceLimitOutOfBounds.selector.revertWith(params.sqrtPriceLimitX96);
            }
        } else {
            if (params.sqrtPriceLimitX96 <= slot0Start.sqrtPriceX96()) {
                PriceLimitAlreadyExceeded.selector.revertWith(slot0Start.sqrtPriceX96(), params.sqrtPriceLimitX96);
            }
            if (params.sqrtPriceLimitX96 >= TickMath.MAX_SQRT_PRICE) {
                PriceLimitOutOfBounds.selector.revertWith(params.sqrtPriceLimitX96);
            }
        }

        StepComputations memory step;
        step.feeGrowthGlobalX128 = zeroForOne ? self.feeGrowthGlobal0X128 : self.feeGrowthGlobal1X128;

        // 只要尚未耗尽指定输入/输出且尚未到达价格限制，就继续逐步兑换。
        while (!(amountSpecifiedRemaining == 0 || result.sqrtPriceX96 == params.sqrtPriceLimitX96)) {
            step.sqrtPriceStartX96 = result.sqrtPriceX96;

            (step.tickNext, step.initialized) =
                self.tickBitmap.nextInitializedTickWithinOneWord(result.tick, params.tickSpacing, zeroForOne);

            // tick bitmap 不感知全局最小/最大 tick，因此这里显式限制，避免越界。
            if (step.tickNext <= TickMath.MIN_TICK) {
                step.tickNext = TickMath.MIN_TICK;
            }
            if (step.tickNext >= TickMath.MAX_TICK) {
                step.tickNext = TickMath.MAX_TICK;
            }

            // 取得下一 tick 对应价格。
            step.sqrtPriceNextX96 = TickMath.getSqrtPriceAtTick(step.tickNext);

            // 计算本步兑换到下一 tick、用户价格限制或指定输入/输出耗尽点时的结果。
            (result.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = SwapMath.computeSwapStep(
                result.sqrtPriceX96,
                SwapMath.getSqrtPriceTarget(zeroForOne, step.sqrtPriceNextX96, params.sqrtPriceLimitX96),
                result.liquidity,
                amountSpecifiedRemaining,
                swapFee
            );

            // exactOutput：扣减尚需输出，并累计为获得这些输出所需的负输入。
            if (params.amountSpecified > 0) {
                unchecked {
                    amountSpecifiedRemaining -= step.amountOut.toInt256();
                }
                amountCalculated -= (step.amountIn + step.feeAmount).toInt256();
            } else {
                // SwapMath 已保证剩余指定输入足以覆盖 amountIn + feeAmount，因此此处安全。
                unchecked {
                    amountSpecifiedRemaining += (step.amountIn + step.feeAmount).toInt256();
                }
                amountCalculated += step.amountOut.toInt256();
            }

            // 启用协议费时，计算协议应得部分，从 LP 手续费中扣除并累计到 amountToProtocol。
            if (protocolFee > 0) {
                unchecked {
                    // step.amountIn 不包含手续费，因为费用已经从输入中分离。
                    // 将 feeAmount 加回可还原总输入，再据此计算协议费。
                    // protocolFee 与 params.amountSpecified 的范围限制保证不会溢出。
                    // 此处向下取整，使舍入余量归 LP 而非协议。
                    uint256 delta = (swapFee == protocolFee)
                        ? step.feeAmount // LP fee 为 0 时，全部手续费均归协议。
                        : (step.amountIn + step.feeAmount) * protocolFee / ProtocolFeeLibrary.PIPS_DENOMINATOR;
                    // 从总手续费中扣除协议部分，并累计到协议费。
                    step.feeAmount -= delta;
                    amountToProtocol += delta;
                }
            }

            // 把剩余 LP 手续费按当前活跃流动性分摊，更新全局每单位流动性手续费增长。
            if (result.liquidity > 0) {
                unchecked {
                    // token 数量上限为 type(uint128).max，分子不会溢出 uint256，因此无需 FullMath.mulDiv。
                    step.feeGrowthGlobalX128 +=
                        UnsafeMath.simpleMulDiv(step.feeAmount, FixedPoint128.Q128, result.liquidity);
                }
            }

            // 若价格到达下一 tick，则执行 tick 转移。zeroForOne 向左移动时预先把结果记为 tickNext - 1。
            // 若兑换随后停止（amountRemaining == 0 或到达价格限制），slot0.tick 会比
            // getTickAtSqrtPrice(slot0.sqrtPrice) 小 1。这不影响 swap，但 donate 逻辑应同时核对价格与 tick，
            // 才能把费用分给正确的活跃 LP。
            if (result.sqrtPriceX96 == step.sqrtPriceNextX96) {
                // tick 已初始化时执行跨 tick 会计，并应用边界上的净流动性变化。
                if (step.initialized) {
                    (uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128) = zeroForOne
                        ? (step.feeGrowthGlobalX128, self.feeGrowthGlobal1X128)
                        : (self.feeGrowthGlobal0X128, step.feeGrowthGlobalX128);
                    int128 liquidityNet =
                        Pool.crossTick(self, step.tickNext, feeGrowthGlobal0X128, feeGrowthGlobal1X128);
                    // liquidityNet 按从左向右定义；向左移动时应按相反符号解释。
                    // liquidityNet 不可能等于 type(int128).min，因此取负安全。
                    unchecked {
                        if (zeroForOne) liquidityNet = -liquidityNet;
                    }

                    result.liquidity = LiquidityMath.addDelta(result.liquidity, liquidityNet);
                }

                unchecked {
                    result.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;
                }
            } else if (result.sqrtPriceX96 != step.sqrtPriceStartX96) {
                // 若本步价格发生变化但没有恰好跨边界，则根据最终价格重新计算 tick。
                result.tick = TickMath.getTickAtSqrtPrice(result.sqrtPriceX96);
            }
        }

        self.slot0 = slot0Start.setTick(result.tick).setSqrtPriceX96(result.sqrtPriceX96);

        // 活跃流动性变化时写回 storage。
        if (self.liquidity != result.liquidity) self.liquidity = result.liquidity;

        // 只写回输入 token 对应的全局手续费增长。
        if (!zeroForOne) {
            self.feeGrowthGlobal1X128 = step.feeGrowthGlobalX128;
        } else {
            self.feeGrowthGlobal0X128 = step.feeGrowthGlobalX128;
        }

        unchecked {
            // “若指定数量对应 currency1”，据此把 specified/unspecified 数量放入正确的 BalanceDelta 半区。
            if (zeroForOne != (params.amountSpecified < 0)) {
                swapDelta = toBalanceDelta(
                    amountCalculated.toInt128(), (params.amountSpecified - amountSpecifiedRemaining).toInt128()
                );
            } else {
                swapDelta = toBalanceDelta(
                    (params.amountSpecified - amountSpecifiedRemaining).toInt128(), amountCalculated.toInt128()
                );
            }
        }
    }

    /// @notice 向池 donate 指定数量的 currency0 与 currency1，并按当前活跃流动性分摊给 LP。
    /// @dev donate 不改变价格，只增加全局手续费增长；只有当前 in-range LP 会按流动性份额获得收益。
    function donate(State storage state, uint256 amount0, uint256 amount1) internal returns (BalanceDelta delta) {
        uint128 liquidity = state.liquidity;
        if (liquidity == 0) NoLiquidityToReceiveFees.selector.revertWith();
        unchecked {
            // amount0 与 amount1 始终为正，转换为调用方应支付的负 delta 时取负安全。
            delta = toBalanceDelta(-(amount0.toInt128()), -(amount1.toInt128()));
            // 分子上限为 type(int128).max * Q128，小于 type(uint256).max，因此无需 FullMath.mulDiv。
            if (amount0 > 0) {
                state.feeGrowthGlobal0X128 += UnsafeMath.simpleMulDiv(amount0, FixedPoint128.Q128, liquidity);
            }
            if (amount1 > 0) {
                state.feeGrowthGlobal1X128 += UnsafeMath.simpleMulDiv(amount1, FixedPoint128.Q128, liquidity);
            }
        }
    }

    /// @notice 计算仓位上下边界之间的历史手续费增长。
    /// @dev 根据当前 tick 位于区间下方、上方或内部，使用全局增长与两个边界的 outside 增长推导 inside 值。
    /// @param self 池状态。
    /// @param tickLower 仓位下边界 tick。
    /// @param tickUpper 仓位上边界 tick。
    /// @return feeGrowthInside0X128 仓位区间内 token0 历史累计的每单位流动性手续费增长。
    /// @return feeGrowthInside1X128 仓位区间内 token1 历史累计的每单位流动性手续费增长。
    function getFeeGrowthInside(State storage self, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128)
    {
        TickInfo storage lower = self.ticks[tickLower];
        TickInfo storage upper = self.ticks[tickUpper];
        int24 tickCurrent = self.slot0.tick();

        unchecked {
            if (tickCurrent < tickLower) {
                feeGrowthInside0X128 = lower.feeGrowthOutside0X128 - upper.feeGrowthOutside0X128;
                feeGrowthInside1X128 = lower.feeGrowthOutside1X128 - upper.feeGrowthOutside1X128;
            } else if (tickCurrent >= tickUpper) {
                feeGrowthInside0X128 = upper.feeGrowthOutside0X128 - lower.feeGrowthOutside0X128;
                feeGrowthInside1X128 = upper.feeGrowthOutside1X128 - lower.feeGrowthOutside1X128;
            } else {
                feeGrowthInside0X128 =
                    self.feeGrowthGlobal0X128 - lower.feeGrowthOutside0X128 - upper.feeGrowthOutside0X128;
                feeGrowthInside1X128 =
                    self.feeGrowthGlobal1X128 - lower.feeGrowthOutside1X128 - upper.feeGrowthOutside1X128;
            }
        }
    }

    /// @notice 更新一个边界 tick，并报告其初始化状态是否发生翻转。
    /// @param self 池状态，其中包含所有已初始化 tick 信息。
    /// @param tick 要更新的 tick。
    /// @param liquidityDelta 仓位流动性变化量。
    /// @param upper true 表示更新仓位上边界，false 表示更新下边界。
    /// @return flipped tick 是否在 initialized 与 uninitialized 之间翻转。
    /// @return liquidityGrossAfter 更新后所有引用该 tick 的仓位流动性总和。
    function updateTick(State storage self, int24 tick, int128 liquidityDelta, bool upper)
        internal
        returns (bool flipped, uint128 liquidityGrossAfter)
    {
        TickInfo storage info = self.ticks[tick];

        uint128 liquidityGrossBefore = info.liquidityGross;
        int128 liquidityNetBefore = info.liquidityNet;

        liquidityGrossAfter = LiquidityMath.addDelta(liquidityGrossBefore, liquidityDelta);

        flipped = (liquidityGrossAfter == 0) != (liquidityGrossBefore == 0);

        if (liquidityGrossBefore == 0) {
            // 约定 tick 首次初始化前发生的全部手续费增长都位于该 tick 下方。
            if (tick <= self.slot0.tick()) {
                info.feeGrowthOutside0X128 = self.feeGrowthGlobal0X128;
                info.feeGrowthOutside1X128 = self.feeGrowthGlobal1X128;
            }
        }

        // 从左向右跨越下（上）边界时，应增加（移除）流动性。
        // 从右向左跨越下（上）边界时，应移除（增加）流动性。
        int128 liquidityNet = upper ? liquidityNetBefore - liquidityDelta : liquidityNetBefore + liquidityDelta;
        assembly ("memory-safe") {
            // liquidityGrossAfter 与 liquidityNet 打包在 `info` 的首个槽位中，
            // 因此先手动打包，再用一次 sstore 同时写入。
            sstore(
                info.slot,
                // 使用 bitwise OR 打包 liquidityGrossAfter 与 liquidityNet。
                or(
                    // 将 liquidityGrossAfter 放入低位，并清除其高位。
                    and(liquidityGrossAfter, 0xffffffffffffffffffffffffffffffff),
                    // 左移 liquidityNet 放入高位；左移时不需要 signextend。
                    shl(128, liquidityNet)
                )
            )
        }
    }

    /// @notice 根据 tick spacing 推导每个 tick 可承载的最大流动性。
    /// @dev 添加流动性时执行。把 uint128 最大值平均分摊到全部可用 tick，防止最坏情况下累计溢出。
    /// @param tickSpacing tick 之间要求的间距，以 `tickSpacing` 的整数倍体现。
    ///        例如 tickSpacing 为 3 时，只能初始化 ..., -6, -3, 0, 3, 6, ...。
    /// @return result 每个 tick 的最大流动性。
    function tickSpacingToMaxLiquidityPerTick(int24 tickSpacing) internal pure returns (uint128 result) {
        // 等价于：
        // int24 minTick = (TickMath.MIN_TICK / tickSpacing);
        // if (TickMath.MIN_TICK  % tickSpacing != 0) minTick--;
        // int24 maxTick = (TickMath.MAX_TICK / tickSpacing);
        // uint24 numTicks = maxTick - minTick + 1;
        // return type(uint128).max / numTicks;
        int24 MAX_TICK = TickMath.MAX_TICK;
        int24 MIN_TICK = TickMath.MIN_TICK;
        // TickMath.MIN_TICK_SPACING 为 1，因此 tick spacing 永远不会为 0。
        assembly ("memory-safe") {
            tickSpacing := signextend(2, tickSpacing)
            let minTick := sub(sdiv(MIN_TICK, tickSpacing), slt(smod(MIN_TICK, tickSpacing), 0))
            let maxTick := sdiv(MAX_TICK, tickSpacing)
            let numTicks := add(sub(maxTick, minTick), 1)
            result := div(sub(shl(128, 1), 1), numTicks)
        }
    }

    /// @notice 指定池尚未初始化时回滚。
    function checkPoolInitialized(State storage self) internal view {
        if (self.slot0.sqrtPriceX96() == 0) PoolNotInitialized.selector.revertWith();
    }

    /// @notice 清除已无仓位引用的 tick 数据。
    /// @param self 池状态，其中包含已初始化 tick 信息。
    /// @param tick 要清除的 tick。
    function clearTick(State storage self, int24 tick) internal {
        delete self.ticks[tick];
    }

    /// @notice 随价格跨越边界 tick，翻转该 tick 两侧的手续费增长并返回净流动性变化。
    /// @dev outside = global - oldOutside；每次跨越都执行该变换，使 outside 始终代表相对当前价格的另一侧。
    /// @param self 池状态。
    /// @param tick 要跨越到的目标 tick。
    /// @param feeGrowthGlobal0X128 token0 历史累计的全局每单位流动性手续费增长。
    /// @param feeGrowthGlobal1X128 token1 历史累计的全局每单位流动性手续费增长。
    /// @return liquidityNet 从左向右跨越时增加的净流动性；从右向左时应由调用方取反。
    function crossTick(State storage self, int24 tick, uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128)
        internal
        returns (int128 liquidityNet)
    {
        unchecked {
            TickInfo storage info = self.ticks[tick];
            info.feeGrowthOutside0X128 = feeGrowthGlobal0X128 - info.feeGrowthOutside0X128;
            info.feeGrowthOutside1X128 = feeGrowthGlobal1X128 - info.feeGrowthOutside1X128;
            liquidityNet = info.liquidityNet;
        }
    }
}
