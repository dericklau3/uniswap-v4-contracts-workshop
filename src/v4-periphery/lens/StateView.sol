// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {ImmutableState} from "../base/ImmutableState.sol";
import {IStateView} from "../interfaces/IStateView.sol";

/// @notice 面向查询的只读适配器，封装 `StateLibrary.sol` 对 V4 核心存储的读取能力。
/// @dev 主要供前端、索引器和报价服务等链下客户端通过标准 ABI 查询。链上合约若已持有
/// `IPoolManager`，应直接使用 `StateLibrary`，避免多一次外部调用。
contract StateView is ImmutableState, IStateView {
    using StateLibrary for IPoolManager;

    constructor(IPoolManager _poolManager) ImmutableState(_poolManager) {}

    /// @notice 读取池的核心实时状态：价格、当前 tick、协议费和 LP 手续费。
    /// @dev 对应 `pools[poolId].slot0`，是判断当前价格区间和兑换费率的入口。
    /// @param poolId 要查询的池 ID。
    /// @return sqrtPriceX96 池内 `currency1/currency0` 价格平方根的 Q96 定点数表示。
    /// @return tick 当前价格对应的 tick。
    /// @return protocolFee 当前协议费配置。
    /// @return lpFee 当前 LP 兑换手续费。
    function getSlot0(PoolId poolId)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
    {
        return poolManager.getSlot0(poolId);
    }

    /// @notice 读取池在指定 tick 上的完整流动性和外侧手续费增长信息。
    /// @dev 对应 `pools[poolId].ticks[tick]`。跨越该 tick 时，`liquidityNet` 会加入或移出活跃流动性；
    /// 两个 `feeGrowthOutside` 用于结合当前 tick 计算某价格区间内部累计的手续费增长。
    /// @param poolId 要查询的池 ID。
    /// @param tick 要查询的 tick。
    /// @return liquidityGross 所有引用该 tick 作为边界的仓位流动性总量。
    /// @return liquidityNet 价格从左向右跨越时加入的净流动性；反向跨越时符号相反。
    /// @return feeGrowthOutside0X128 相对当前 tick 位于另一侧的 currency0 单位流动性手续费增长。
    /// @return feeGrowthOutside1X128 相对当前 tick 位于另一侧的 currency1 单位流动性手续费增长。
    function getTickInfo(PoolId poolId, int24 tick)
        external
        view
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128
        )
    {
        return poolManager.getTickInfo(poolId, tick);
    }

    /// @notice 只读取指定 tick 的总流动性和净流动性。
    /// @dev 对应 tick 存储中的 `liquidityGross` 与 `liquidityNet`，比读取完整 tick 信息更节省 gas。
    /// @param poolId 要查询的池 ID。
    /// @param tick 要查询的 tick。
    /// @return liquidityGross 所有引用该 tick 的仓位流动性总量。
    /// @return liquidityNet 跨越该 tick 时活跃流动性的净变化。
    function getTickLiquidity(PoolId poolId, int24 tick)
        external
        view
        returns (uint128 liquidityGross, int128 liquidityNet)
    {
        return poolManager.getTickLiquidity(poolId, tick);
    }

    /// @notice 只读取指定 tick 两种货币的外侧手续费增长。
    /// @dev 用于计算区间内手续费，比 `getTickInfo` 少读取不需要的流动性字段。
    /// @param poolId 要查询的池 ID。
    /// @param tick 要查询的 tick。
    /// @return feeGrowthOutside0X128 tick 另一侧的 currency0 单位流动性手续费增长。
    /// @return feeGrowthOutside1X128 tick 另一侧的 currency1 单位流动性手续费增长。
    function getTickFeeGrowthOutside(PoolId poolId, int24 tick)
        external
        view
        returns (uint256 feeGrowthOutside0X128, uint256 feeGrowthOutside1X128)
    {
        return poolManager.getTickFeeGrowthOutside(poolId, tick);
    }

    /// @notice 读取池自创建以来两种货币的全局单位流动性手续费增长。
    /// @dev 该累计值采用 X128 定点精度，并会随兑换手续费持续增长。
    /// @param poolId 要查询的池 ID。
    /// @return feeGrowthGlobal0 currency0 的全局手续费增长。
    /// @return feeGrowthGlobal1 currency1 的全局手续费增长。
    function getFeeGrowthGlobals(PoolId poolId)
        external
        view
        returns (uint256 feeGrowthGlobal0, uint256 feeGrowthGlobal1)
    {
        return poolManager.getFeeGrowthGlobals(poolId);
    }

    /// @notice 返回池在当前价格处实际参与报价的活跃流动性。
    /// @param poolId 要查询的池 ID。
    /// @return liquidity 当前活跃流动性，不等于所有价格区间仓位流动性的简单总和。
    function getLiquidity(PoolId poolId) external view returns (uint128 liquidity) {
        return poolManager.getLiquidity(poolId);
    }

    /// @notice 读取一个 tick bitmap 字，判断对应 256 个压缩 tick 中哪些已初始化。
    /// @param poolId 要查询的池 ID。
    /// @param tick bitmap 的字索引，而非未经压缩的单个 tick。
    /// @return tickBitmap 每一位表示相应 tick 是否有流动性边界。
    function getTickBitmap(PoolId poolId, int16 tick) external view returns (uint256 tickBitmap) {
        return poolManager.getTickBitmap(poolId, tick);
    }

    /// @notice 根据仓位组成字段计算 positionId，并读取底层仓位状态。
    /// @dev 对应 `pools[poolId].positions[positionId]`，适合尚未自行计算 positionId 的客户端。
    /// @param poolId 仓位所属池 ID。
    /// @param owner 在核心层拥有该仓位的地址；外围 NFT 仓位通常是 PositionManager。
    /// @param tickLower 仓位价格区间下界。
    /// @param tickUpper 仓位价格区间上界。
    /// @param salt 用于区分相同 owner 和 tick 区间下多个仓位的 salt。
    /// @return liquidity 仓位当前流动性。
    /// @return feeGrowthInside0LastX128 仓位上次更新时记录的区间内 currency0 手续费增长。
    /// @return feeGrowthInside1LastX128 仓位上次更新时记录的区间内 currency1 手续费增长。
    function getPositionInfo(PoolId poolId, address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        external
        view
        returns (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128)
    {
        return poolManager.getPositionInfo(poolId, owner, tickLower, tickUpper, salt);
    }

    /// @notice 使用已计算的 positionId 读取底层仓位状态。
    /// @param poolId 仓位所属池 ID。
    /// @param positionId 由 owner、tickLower、tickUpper 和 salt 计算出的仓位 ID。
    /// @return liquidity 仓位当前流动性。
    /// @return feeGrowthInside0LastX128 仓位上次更新时记录的区间内 currency0 手续费增长。
    /// @return feeGrowthInside1LastX128 仓位上次更新时记录的区间内 currency1 手续费增长。
    function getPositionInfo(PoolId poolId, bytes32 positionId)
        external
        view
        returns (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128)
    {
        return poolManager.getPositionInfo(poolId, positionId);
    }

    /// @notice 只读取指定底层仓位的流动性。
    /// @dev 比 `getPositionInfo` 更适合只关心仓位规模的调用方，可减少不必要的存储读取。
    /// @param poolId 仓位所属池 ID。
    /// @param positionId 底层仓位 ID。
    /// @return liquidity 仓位当前流动性。
    function getPositionLiquidity(PoolId poolId, bytes32 positionId) external view returns (uint128 liquidity) {
        return poolManager.getPositionLiquidity(poolId, positionId);
    }

    /// @notice 按池的最新状态实时计算给定价格区间内部的手续费增长。
    /// @dev `Position.Info` 中保存的是仓位上次更新时的快照，可能已经过时；本函数结合全局累计值、
    /// 上下边界的外侧累计值和当前 tick，得到截至当前区块的最新区间内增长。
    /// @param poolId 要查询的池 ID。
    /// @param tickLower 区间下界。
    /// @param tickUpper 区间上界。
    /// @return feeGrowthInside0X128 区间内 currency0 的最新单位流动性手续费增长。
    /// @return feeGrowthInside1X128 区间内 currency1 的最新单位流动性手续费增长。
    function getFeeGrowthInside(PoolId poolId, int24 tickLower, int24 tickUpper)
        external
        view
        returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128)
    {
        return poolManager.getFeeGrowthInside(poolId, tickLower, tickUpper);
    }
}
