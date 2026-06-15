// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {MigratorImmutables} from '../modules/MigratorImmutables.sol';
import {INonfungiblePositionManager} from '@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol';
import {Actions} from '@uniswap/v4-periphery/src/libraries/Actions.sol';
import {IERC721Permit} from '@uniswap/v3-periphery/contracts/interfaces/IERC721Permit.sol';
import {CalldataDecoder} from '@uniswap/v4-periphery/src/libraries/CalldataDecoder.sol';

/// @title Uniswap V3 到 V4 流动性迁移校验器
/// @notice 限制 Universal Router 对 V3/V4 PositionManager 的调用，使组合命令只能安全地退出 V3 头寸并铸造 V4 头寸。
abstract contract V3ToV4Migrator is MigratorImmutables {
    using CalldataDecoder for bytes;

    error InvalidAction(bytes4 action);
    error OnlyMintAllowed();
    error NotAuthorizedForToken(uint256 tokenId);

    /// @dev 判断 V3 PositionManager 调用是否属于迁移所需的减流动性、领取资产或销毁空头寸。
    function _isValidAction(bytes4 selector) private pure returns (bool) {
        return selector == INonfungiblePositionManager.decreaseLiquidity.selector
            || selector == INonfungiblePositionManager.collect.selector
            || selector == INonfungiblePositionManager.burn.selector;
    }

    /// @dev 调用者是 NFT 所有者、该 tokenId 的被授权地址或所有者的全局 operator 时，视为有权迁移该头寸。
    function _isAuthorizedForToken(address caller, uint256 tokenId) private view returns (bool) {
        address owner = V3_POSITION_MANAGER.ownerOf(tokenId);
        return caller == owner || V3_POSITION_MANAGER.getApproved(tokenId) == caller
            || V3_POSITION_MANAGER.isApprovedForAll(owner, caller);
    }

    /// @dev 校验 V3 PositionManager 调用只能是 ERC721 permit，用于在同一笔迁移交易中建立 NFT 授权。
    function _checkV3PermitCall(bytes calldata inputs) internal pure {
        bytes4 selector;
        assembly {
            selector := calldataload(inputs.offset)
        }

        if (selector != IERC721Permit.permit.selector) {
            revert InvalidAction(selector);
        }
    }

    /// @dev 校验 V3 PositionManager 调用既是迁移允许的退出动作，又由该 tokenId 的合法控制者发起。
    function _checkV3PositionManagerCall(bytes calldata inputs, address caller) internal view {
        bytes4 selector;
        assembly {
            selector := calldataload(inputs.offset)
        }

        if (!_isValidAction(selector)) {
            revert InvalidAction(selector);
        }

        uint256 tokenId;
        assembly {
            // 三种允许动作都把 tokenId 放在第一个参数，因此可从 selector 后的首槽直接读取。
            tokenId := calldataload(add(inputs.offset, 0x04))
        }
        // PositionManager 实际看到的执行者是 Universal Router，因此路由器本身必须获得 NFT 授权；
        // 同时，发起整条路由的 caller 也必须是所有者或获授权者，不能仅凭路由器授权替别人迁移头寸。
        // 常见授权组合有两种：
        // 1. 路由器获得特定 tokenId 授权，caller 是所有者的全局 operator；
        // 2. 路由器是所有者的全局 operator，caller 获得特定 tokenId 授权。
        if (!_isAuthorizedForToken(caller, tokenId)) {
            revert NotAuthorizedForToken(tokenId);
        }
    }

    /// @dev 校验 V4 PositionManager 调用只能通过 `modifyLiquidities` 铸造新头寸。
    /// 在会改变既有头寸的 Actions 中禁止增仓、减仓和销毁：如果用户曾授权 Universal Router 操作 V4 NFT，
    /// 放开这些动作会使恶意路由命令能够提取手续费或抽走整笔流动性。迁移流程只需要用退出 V3 得到的资产
    /// 创建新 V4 头寸，因此保留 MINT 类动作即可。
    function _checkV4PositionManagerCall(bytes calldata inputs) internal view {
        bytes4 selector;
        assembly {
            selector := calldataload(inputs.offset)
        }
        if (selector != V4_POSITION_MANAGER.modifyLiquidities.selector) {
            revert InvalidAction(selector);
        }

        // 去掉 4 字节 selector 后，slice 的布局为 `abi.encode(bytes unlockData, uint256 deadline)`。
        bytes calldata slice = inputs[4:];
        // 第一次 `toBytes(0)` 取出 modifyLiquidities 的 unlockData；
        // unlockData = `abi.encode(bytes actions, bytes[] params)`，
        // 第二次 `toBytes(0)` 再取出真正的 action 字节序列，逐项检查是否包含危险头寸操作。
        bytes calldata actions = slice.toBytes(0).toBytes(0);

        uint256 numActions = actions.length;

        for (uint256 actionIndex = 0; actionIndex < numActions; actionIndex++) {
            uint256 action = uint8(actions[actionIndex]);

            if (
                action == Actions.INCREASE_LIQUIDITY || action == Actions.INCREASE_LIQUIDITY_FROM_DELTAS
                    || action == Actions.DECREASE_LIQUIDITY || action == Actions.BURN_POSITION
            ) {
                revert OnlyMintAllowed();
            }
        }
    }
}
