// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

struct RouterParameters {
    // 支付基础设施参数：Permit2 负责用户 ERC20 拉款，WETH9 负责 ETH 包装与解包。
    address permit2;
    address weth9;
    // Uniswap V2-V4 交换参数：Factory、init code hash、PoolManager 与权限池适配器。
    address v2Factory;
    address v3Factory;
    bytes32 pairInitCodeHash;
    bytes32 poolInitCodeHash;
    address v4PoolManager;
    address permissionsAdapterFactory;
    // Uniswap V3 -> V4 流动性迁移所需的两个 PositionManager。
    address v3NFTPositionManager;
    address v4PositionManager;
    // Across 跨链存款所使用的 SpokePool。
    address spokePool;
}
