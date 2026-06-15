// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolId} from "../types/PoolId.sol";
import {IPoolManager} from "../interfaces/IPoolManager.sol";
import {Position} from "./Position.sol";

/// @notice 通过 extsload 按 PoolManager 存储布局读取池状态的辅助库。
/// @dev 该库避免 PoolManager 为每个内部字段单独暴露 getter，但与当前存储 slot/offset 强绑定。
library StateLibrary {
    /// @notice PoolManager 中 pools mapping 的存储槽索引。
    bytes32 public constant POOLS_SLOT = bytes32(uint256(6));

    /// @notice feeGrowthGlobal0X128 在 Pool.State 中相对 slot0 的偏移。
    uint256 public constant FEE_GROWTH_GLOBAL0_OFFSET = 1;

    // feeGrowthGlobal1X128 在 Pool.State 中的偏移为 2。

    /// @notice liquidity 在 Pool.State 中的偏移。
    uint256 public constant LIQUIDITY_OFFSET = 3;

    /// @notice ticks mapping 在 Pool.State 中的偏移：mapping(int24 => TickInfo) ticks。
    uint256 public constant TICKS_OFFSET = 4;

    /// @notice tickBitmap mapping 在 Pool.State 中的偏移。
    uint256 public constant TICK_BITMAP_OFFSET = 5;

    /// @notice positions mapping 在 Pool.State 中的偏移：mapping(bytes32 => Position.State) positions。
    uint256 public constant POSITIONS_OFFSET = 6;

    /**
     * @notice 读取池的 Slot0：sqrtPriceX96、tick、protocolFee 与 lpFee。
     * @dev 对应 pools[poolId].slot0。
     * @param manager PoolManager 合约。
     * @param poolId 池 ID。
     * @return sqrtPriceX96 池价格平方根的 Q96 精度表示。
     * @return tick 池当前 tick。
     * @return protocolFee 池当前双向协议费打包值。
     * @return lpFee 池当前 LP 兑换费。
     */
    function getSlot0(IPoolManager manager, PoolId poolId)
        internal
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
    {
        // Pool.State 值 `pools[poolId]` 的槽位键。
        bytes32 stateSlot = _getPoolStateSlot(poolId);

        bytes32 data = manager.extsload(stateSlot);

        //   24 bits  |24bits|24bits      |24 bits|160 bits
        // 0x000000   |000bb8|000000      |ffff75 |0000000000000000fe3aa841ba359daa0ea9eff7
        // ---------- | fee  |protocolfee | tick  | sqrtPriceX96
        assembly ("memory-safe") {
            // data 最低 160 bit。
            sqrtPriceX96 := and(data, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
            // 接下来的 24 bit。
            tick := signextend(2, shr(160, data))
            // 再接下来的 24 bit。
            protocolFee := and(shr(184, data), 0xFFFFFF)
            // 最后的 24 bit。
            lpFee := and(shr(208, data), 0xFFFFFF)
        }
    }

    /**
     * @notice 读取池在指定 tick 上的完整 TickInfo。
     * @dev 对应 pools[poolId].ticks[tick]。
     * @param manager PoolManager 合约。
     * @param poolId 池 ID。
     * @param tick 要读取信息的 tick。
     * @return liquidityGross 所有引用该 tick 的仓位流动性总和。
     * @return liquidityNet 从左向右跨越该 tick 时净增加的流动性；反向跨越时符号相反。
     * @return feeGrowthOutside0X128 相对当前 tick，边界另一侧每单位流动性的 currency0 手续费增长。
     * @return feeGrowthOutside1X128 相对当前 tick，边界另一侧每单位流动性的 currency1 手续费增长。
     */
    function getTickInfo(IPoolManager manager, PoolId poolId, int24 tick)
        internal
        view
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128
        )
    {
        bytes32 slot = _getTickInfoSlot(poolId, tick);

        // 连续读取 TickInfo 结构体的全部 3 个 word。
        bytes32[] memory data = manager.extsload(slot, 3);
        assembly ("memory-safe") {
            let firstWord := mload(add(data, 32))
            liquidityNet := sar(128, firstWord)
            liquidityGross := and(firstWord, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
            feeGrowthOutside0X128 := mload(add(data, 64))
            feeGrowthOutside1X128 := mload(add(data, 96))
        }
    }

    /**
     * @notice 只读取池在指定 tick 上的 liquidityGross 与 liquidityNet。
     * @dev 对应 pools[poolId].ticks[tick] 的首个 word，比读取完整 getTickInfo 更节省 gas。
     * @param manager PoolManager 合约。
     * @param poolId 池 ID。
     * @param tick 要读取流动性的 tick。
     * @return liquidityGross 所有引用该 tick 的仓位流动性总和。
     * @return liquidityNet 从左向右跨越该 tick 时净增加的流动性；反向跨越时符号相反。
     */
    function getTickLiquidity(IPoolManager manager, PoolId poolId, int24 tick)
        internal
        view
        returns (uint128 liquidityGross, int128 liquidityNet)
    {
        bytes32 slot = _getTickInfoSlot(poolId, tick);

        bytes32 value = manager.extsload(slot);
        assembly ("memory-safe") {
            liquidityNet := sar(128, value)
            liquidityGross := and(value, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
        }
    }

    /**
     * @notice 只读取指定 tick 外侧的两种货币手续费增长。
     * @dev 对应 TickInfo 的后两个 word，比读取完整 getTickInfo 更节省 gas。
     * @param manager PoolManager 合约。
     * @param poolId 池 ID。
     * @param tick 要读取手续费增长的 tick。
     * @return feeGrowthOutside0X128 相对当前 tick，边界另一侧每单位流动性的 currency0 手续费增长。
     * @return feeGrowthOutside1X128 相对当前 tick，边界另一侧每单位流动性的 currency1 手续费增长。
     */
    function getTickFeeGrowthOutside(IPoolManager manager, PoolId poolId, int24 tick)
        internal
        view
        returns (uint256 feeGrowthOutside0X128, uint256 feeGrowthOutside1X128)
    {
        bytes32 slot = _getTickInfoSlot(poolId, tick);

        // 跳过首个 word，因为其中打包的是 liquidityGross 与 liquidityNet。
        bytes32[] memory data = manager.extsload(bytes32(uint256(slot) + 1), 2);
        assembly ("memory-safe") {
            feeGrowthOutside0X128 := mload(add(data, 32))
            feeGrowthOutside1X128 := mload(add(data, 64))
        }
    }

    /**
     * @notice 读取池两种货币的全局手续费增长。
     * @dev 对应 pools[poolId].feeGrowthGlobal0X128 与 feeGrowthGlobal1X128。
     * @param manager PoolManager 合约。
     * @param poolId 池 ID。
     * @return feeGrowthGlobal0 token0 的全局手续费增长。
     * @return feeGrowthGlobal1 token1 的全局手续费增长。
     * @dev feeGrowthGlobal 可被人为放大。若池只有一个流动性仓位，参与者可向自己所在池 donate，
     *      再领取同一笔费用；在同一个 unlockCallback 中原子执行 donate 与 collect 会让数值膨胀更明显。
     *      因此集成方不应把该累计值直接当作不可操纵的经济指标。
     */
    function getFeeGrowthGlobals(IPoolManager manager, PoolId poolId)
        internal
        view
        returns (uint256 feeGrowthGlobal0, uint256 feeGrowthGlobal1)
    {
        // Pool.State 值 `pools[poolId]` 的槽位键。
        bytes32 stateSlot = _getPoolStateSlot(poolId);

        // Pool.State 中的 `uint256 feeGrowthGlobal0X128`。
        bytes32 slot_feeGrowthGlobal0X128 = bytes32(uint256(stateSlot) + FEE_GROWTH_GLOBAL0_OFFSET);

        // 连续读取 feeGrowthGlobal 的两个 word。
        bytes32[] memory data = manager.extsload(slot_feeGrowthGlobal0X128, 2);
        assembly ("memory-safe") {
            feeGrowthGlobal0 := mload(add(data, 32))
            feeGrowthGlobal1 := mload(add(data, 64))
        }
    }

    /**
     * @notice 读取池当前价格所在区间的活跃总流动性。
     * @dev 对应 pools[poolId].liquidity；并非所有仓位名义流动性的总和，仅包含当前 in-range 流动性。
     * @param manager PoolManager 合约。
     * @param poolId 池 ID。
     * @return liquidity 池当前活跃流动性。
     */
    function getLiquidity(IPoolManager manager, PoolId poolId) internal view returns (uint128 liquidity) {
        // Pool.State 值 `pools[poolId]` 的槽位键。
        bytes32 stateSlot = _getPoolStateSlot(poolId);

        // Pool.State: `uint128 liquidity`
        bytes32 slot = bytes32(uint256(stateSlot) + LIQUIDITY_OFFSET);

        liquidity = uint128(uint256(manager.extsload(slot)));
    }

    /**
     * @notice 读取池指定 wordPos 的 tick bitmap。
     * @dev 对应 pools[poolId].tickBitmap[tick]，返回的每个 bit 表示一个压缩 tick 是否已初始化。
     * @param manager PoolManager 合约。
     * @param poolId 池 ID。
     * @param tick 要读取的 bitmap mapping 键，即 wordPos。
     * @return tickBitmap 包含 256 个 tick 初始化标志的 bitmap。
     */
    function getTickBitmap(IPoolManager manager, PoolId poolId, int16 tick)
        internal
        view
        returns (uint256 tickBitmap)
    {
        // Pool.State 值 `pools[poolId]` 的槽位键。
        bytes32 stateSlot = _getPoolStateSlot(poolId);

        // Pool.State: `mapping(int16 => uint256) tickBitmap;`
        bytes32 tickBitmapMapping = bytes32(uint256(stateSlot) + TICK_BITMAP_OFFSET);

        // mapping 键 `pools[poolId].tickBitmap[tick]` 对应的槽位 ID。
        bytes32 slot = keccak256(abi.encodePacked(int256(tick), tickBitmapMapping));

        tickBitmap = uint256(manager.extsload(slot));
    }

    /**
     * @notice 无需调用方预先计算 positionId，即可读取池中的仓位信息。
     * @dev 根据 owner、区间与 salt 计算 positionId，再读取 pools[poolId].positions[positionId]。
     * @param poolId 池 ID。
     * @param owner 流动性仓位所有者。
     * @param tickLower 流动性区间下边界 tick。
     * @param tickUpper 流动性区间上边界 tick。
     * @param salt 进一步区分仓位状态的 bytes32 值。
     * @return liquidity 仓位流动性。
     * @return feeGrowthInside0LastX128 仓位上次更新时区间内 token0 手续费增长快照。
     * @return feeGrowthInside1LastX128 仓位上次更新时区间内 token1 手续费增长快照。
     */
    function getPositionInfo(
        IPoolManager manager,
        PoolId poolId,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) internal view returns (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) {
        // positionKey = keccak256(abi.encodePacked(owner, tickLower, tickUpper, salt))
        bytes32 positionKey = Position.calculatePositionKey(owner, tickLower, tickUpper, salt);

        (liquidity, feeGrowthInside0LastX128, feeGrowthInside1LastX128) = getPositionInfo(manager, poolId, positionKey);
    }

    /**
     * @notice 根据 positionId 读取池中的完整仓位信息。
     * @dev 对应 pools[poolId].positions[positionId]。
     * @param manager PoolManager 合约。
     * @param poolId 池 ID。
     * @param positionId 仓位 ID。
     * @return liquidity 仓位流动性。
     * @return feeGrowthInside0LastX128 仓位上次更新时区间内 token0 手续费增长快照。
     * @return feeGrowthInside1LastX128 仓位上次更新时区间内 token1 手续费增长快照。
     */
    function getPositionInfo(IPoolManager manager, PoolId poolId, bytes32 positionId)
        internal
        view
        returns (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128)
    {
        bytes32 slot = _getPositionInfoSlot(poolId, positionId);

        // 连续读取 Position.State 结构体的全部 3 个 word。
        bytes32[] memory data = manager.extsload(slot, 3);

        assembly ("memory-safe") {
            liquidity := mload(add(data, 32))
            feeGrowthInside0LastX128 := mload(add(data, 64))
            feeGrowthInside1LastX128 := mload(add(data, 96))
        }
    }

    /**
     * @notice 只读取仓位的流动性。
     * @dev 对应 pools[poolId].positions[positionId].liquidity；只需该字段时比 getPositionInfo 更节省 gas。
     * @param manager PoolManager 合约。
     * @param poolId 池 ID。
     * @param positionId 仓位 ID。
     * @return liquidity 仓位流动性。
     */
    function getPositionLiquidity(IPoolManager manager, PoolId poolId, bytes32 positionId)
        internal
        view
        returns (uint128 liquidity)
    {
        bytes32 slot = _getPositionInfoSlot(poolId, positionId);
        liquidity = uint128(uint256(manager.extsload(slot)));
    }

    /**
     * @notice 计算池某个 tick 区间内最新的手续费增长。
     * @dev Position.State 中的 feeGrowthInside*LastX128 只是上次更新快照，可能已经过时。
     *      本函数结合全局增长、上下边界 outside 增长和当前 tick，实时推导区间内数值。
     * @param manager PoolManager 合约。
     * @param poolId 池 ID。
     * @param tickLower 区间下边界 tick。
     * @param tickUpper 区间上边界 tick。
     * @return feeGrowthInside0X128 tick 区间内 token0 的最新手续费增长。
     * @return feeGrowthInside1X128 tick 区间内 token1 的最新手续费增长。
     */
    function getFeeGrowthInside(IPoolManager manager, PoolId poolId, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128)
    {
        (uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128) = getFeeGrowthGlobals(manager, poolId);

        (uint256 lowerFeeGrowthOutside0X128, uint256 lowerFeeGrowthOutside1X128) =
            getTickFeeGrowthOutside(manager, poolId, tickLower);
        (uint256 upperFeeGrowthOutside0X128, uint256 upperFeeGrowthOutside1X128) =
            getTickFeeGrowthOutside(manager, poolId, tickUpper);
        (, int24 tickCurrent,,) = getSlot0(manager, poolId);
        unchecked {
            if (tickCurrent < tickLower) {
                feeGrowthInside0X128 = lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
                feeGrowthInside1X128 = lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
            } else if (tickCurrent >= tickUpper) {
                feeGrowthInside0X128 = upperFeeGrowthOutside0X128 - lowerFeeGrowthOutside0X128;
                feeGrowthInside1X128 = upperFeeGrowthOutside1X128 - lowerFeeGrowthOutside1X128;
            } else {
                feeGrowthInside0X128 = feeGrowthGlobal0X128 - lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
                feeGrowthInside1X128 = feeGrowthGlobal1X128 - lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
            }
        }
    }

    function _getPoolStateSlot(PoolId poolId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(PoolId.unwrap(poolId), POOLS_SLOT));
    }

    function _getTickInfoSlot(PoolId poolId, int24 tick) internal pure returns (bytes32) {
        // Pool.State 值 `pools[poolId]` 的槽位键。
        bytes32 stateSlot = _getPoolStateSlot(poolId);

        // Pool.State: `mapping(int24 => TickInfo) ticks`
        bytes32 ticksMappingSlot = bytes32(uint256(stateSlot) + TICKS_OFFSET);

        // tick 键 `pools[poolId].ticks[tick]` 对应的槽位键。
        return keccak256(abi.encodePacked(int256(tick), ticksMappingSlot));
    }

    function _getPositionInfoSlot(PoolId poolId, bytes32 positionId) internal pure returns (bytes32) {
        // Pool.State 值 `pools[poolId]` 的槽位键。
        bytes32 stateSlot = _getPoolStateSlot(poolId);

        // Pool.State: `mapping(bytes32 => Position.State) positions;`
        bytes32 positionMapping = bytes32(uint256(stateSlot) + POSITIONS_OFFSET);

        // mapping 键 `pools[poolId].positions[positionId]` 对应的槽位。
        return keccak256(abi.encodePacked(positionId, positionMapping));
    }
}
