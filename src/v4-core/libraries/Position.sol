// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {FullMath} from "./FullMath.sol";
import {FixedPoint128} from "./FixedPoint128.sol";
import {LiquidityMath} from "./LiquidityMath.sol";
import {CustomRevert} from "./CustomRevert.sol";

/// @title Position
/// @notice 仓位表示某个 owner 在下边界 tick 与上边界 tick 之间提供的集中流动性。
/// @dev 仓位还保存区间内手续费增长快照，用于在下一次增减流动性或主动 poke 时结算应得手续费。
library Position {
    using CustomRevert for bytes4;

    /// @notice 禁止对流动性为 0 的空仓位执行仅结算手续费的更新。
    error CannotUpdateEmptyPosition();

    // 每个用户仓位保存的信息。
    struct State {
        // 当前仓位拥有的流动性数量。
        uint128 liquidity;
        // 上次修改流动性或结算手续费时，仓位区间内每单位流动性的手续费增长快照。
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
    }

    /// @notice 根据 owner、价格区间和 salt 返回对应仓位的存储引用。
    /// @dev 相同 owner 可通过不同 salt 在同一区间建立多个互不合并的仓位。
    /// @param self 保存所有用户仓位的 mapping。
    /// @param owner 仓位所有者地址。
    /// @param tickLower 仓位下边界 tick。
    /// @param tickUpper 仓位上边界 tick。
    /// @param salt 区分同一区间多个仓位的唯一值。
    /// @return position 指定 owner 仓位的 State 存储引用。
    function get(mapping(bytes32 => State) storage self, address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        internal
        view
        returns (State storage position)
    {
        bytes32 positionKey = calculatePositionKey(owner, tickLower, tickUpper, salt);
        position = self[positionKey];
    }

    /// @notice 计算仓位在 mapping 中使用的唯一键。
    /// @dev 等价于对 owner、tickLower、tickUpper 与 salt 的紧凑编码执行 keccak256。
    /// @param owner 仓位所有者地址。
    /// @param tickLower 仓位下边界 tick。
    /// @param tickUpper 仓位上边界 tick。
    /// @param salt 由调用方传入，用于区分同一 owner 在相同区间内的多个仓位。
    function calculatePositionKey(address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        internal
        pure
        returns (bytes32 positionKey)
    {
        // positionKey = keccak256(abi.encodePacked(owner, tickLower, tickUpper, salt))
        assembly ("memory-safe") {
            let fmp := mload(0x40)
            mstore(add(fmp, 0x26), salt) // [0x26, 0x46)
            mstore(add(fmp, 0x06), tickUpper) // [0x23, 0x26)
            mstore(add(fmp, 0x03), tickLower) // [0x20, 0x23)
            mstore(fmp, owner) // [0x0c, 0x20)
            positionKey := keccak256(add(fmp, 0x0c), 0x3a) // 编码总长度为 58 byte。

            // 清理刚才使用的内存。
            mstore(add(fmp, 0x40), 0) // fmp+0x40 曾存放 salt。
            mstore(add(fmp, 0x20), 0) // fmp+0x20 曾存放 tickLower、tickUpper 和 salt。
            mstore(fmp, 0) // fmp 曾存放 owner。
        }
    }

    /// @notice 结算仓位自上次更新以来累计的手续费，并应用流动性变化。
    /// @dev 手续费按“区间内每单位流动性增长量 × 更新前流动性”计算。先用旧流动性结算历史手续费，
    ///      再保存最新增长快照，因此本次新增流动性不会追溯分享此前手续费，移除的流动性仍能拿到退出前收益。
    /// @param self 要更新的单个仓位。
    /// @param liquidityDelta 本次仓位更新导致的池流动性变化；0 表示只结算手续费。
    /// @param feeGrowthInside0X128 仓位 tick 区间内 currency0 历史累计的每单位流动性手续费增长。
    /// @param feeGrowthInside1X128 仓位 tick 区间内 currency1 历史累计的每单位流动性手续费增长。
    /// @return feesOwed0 本次应计给仓位 owner 的 currency0 数量。
    /// @return feesOwed1 本次应计给仓位 owner 的 currency1 数量。
    function update(
        State storage self,
        int128 liquidityDelta,
        uint256 feeGrowthInside0X128,
        uint256 feeGrowthInside1X128
    ) internal returns (uint256 feesOwed0, uint256 feesOwed1) {
        uint128 liquidity = self.liquidity;

        if (liquidityDelta == 0) {
            // 空仓位没有可参与分摊的历史流动性，因此禁止仅靠 poke 创建手续费债权。
            if (liquidity == 0) CannotUpdateEmptyPosition.selector.revertWith();
        } else {
            self.liquidity = LiquidityMath.addDelta(liquidity, liquidityDelta);
        }

        // 计算累计手续费。fee growth 是无界累加器，其减法按模 2**256 回绕是预期行为。
        unchecked {
            feesOwed0 =
                FullMath.mulDiv(feeGrowthInside0X128 - self.feeGrowthInside0LastX128, liquidity, FixedPoint128.Q128);
            feesOwed1 =
                FullMath.mulDiv(feeGrowthInside1X128 - self.feeGrowthInside1LastX128, liquidity, FixedPoint128.Q128);
        }

        // 保存最新快照，作为下次结算的起点。
        self.feeGrowthInside0LastX128 = feeGrowthInside0X128;
        self.feeGrowthInside1LastX128 = feeGrowthInside1X128;
    }
}
