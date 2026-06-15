// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {INonfungiblePositionManager} from '@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol';
import {IPositionManager} from '@uniswap/v4-periphery/src/interfaces/IPositionManager.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';

struct MigratorParameters {
    address v3PositionManager;
    address v4PositionManager;
}

/// @title 迁移模块不可变量
/// @notice 保存 V3 与 V4 PositionManager 地址，供跨版本流动性迁移命令调用。
contract MigratorImmutables {
    /// @notice 管理 Uniswap V3 NFT 流动性头寸的 PositionManager。
    INonfungiblePositionManager public immutable V3_POSITION_MANAGER;
    /// @notice 管理 Uniswap V4 流动性头寸的 PositionManager。
    IPositionManager public immutable V4_POSITION_MANAGER;

    constructor(MigratorParameters memory params) {
        V3_POSITION_MANAGER = INonfungiblePositionManager(params.v3PositionManager);
        V4_POSITION_MANAGER = IPositionManager(params.v4PositionManager);
    }
}
