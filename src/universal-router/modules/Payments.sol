// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {Constants} from '../libraries/Constants.sol';
import {ActionConstants} from '@uniswap/v4-periphery/src/libraries/ActionConstants.sol';
import {BipsLibrary} from '@uniswap/v4-periphery/src/libraries/BipsLibrary.sol';
import {PaymentsImmutables} from '../modules/PaymentsImmutables.sol';
import {SafeTransferLib} from 'solmate/src/utils/SafeTransferLib.sol';
import {ERC20} from 'solmate/src/tokens/ERC20.sol';

/// @title Universal Router 资金支付模块
/// @notice 处理路由器余额中的 ETH/ERC20 转账、按比例分配、余额归集以及 ETH/WETH9 转换。
abstract contract Payments is PaymentsImmutables {
    using SafeTransferLib for ERC20;
    using SafeTransferLib for address;
    using BipsLibrary for uint256;

    error InsufficientToken();
    error InsufficientETH();
    error InvalidPortion();

    /// @notice 从 Universal Router 当前余额向接收者支付指定数量的 ETH 或 ERC20。
    /// @dev `value == CONTRACT_BALANCE` 仅对 ERC20 表示发送路由器持有的全部该代币余额。
    /// @param token 支付资产地址；使用 `Constants.ETH` 表示原生 ETH。
    /// @param recipient 收款地址。
    /// @param value 支付数量，或用于 ERC20 的 `CONTRACT_BALANCE` 哨兵值。
    function pay(address token, address recipient, uint256 value) internal {
        if (token == Constants.ETH) {
            recipient.safeTransferETH(value);
        } else {
            if (value == ActionConstants.CONTRACT_BALANCE) {
                value = ERC20(token).balanceOf(address(this));
            }

            ERC20(token).safeTransfer(recipient, value);
        }
    }

    /// @notice 按 bips 比例支付路由器持有的 ETH 或 ERC20 余额。
    /// @dev 常用于将一次 swap 或多命令执行后的剩余资产按份额分给费用接收者。
    /// @param token 支付资产地址；使用 `Constants.ETH` 表示原生 ETH。
    /// @param recipient 收款地址。
    /// @param bips 占路由器该资产总余额的万分比份额。
    function payPortion(address token, address recipient, uint256 bips) internal {
        if (token == Constants.ETH) {
            uint256 balance = address(this).balance;
            uint256 amount = balance.calculatePortion(bips);
            recipient.safeTransferETH(amount);
        } else {
            uint256 balance = ERC20(token).balanceOf(address(this));
            uint256 amount = balance.calculatePortion(bips);
            ERC20(token).safeTransfer(recipient, amount);
        }
    }

    /// @notice 以 1e18 精度按比例支付路由器持有的 ETH 或 ERC20 余额。
    /// @dev 相比 bips 版本可表达更细粒度的分润；`portion` 不能超过 1e18。
    /// @param token 支付资产地址；使用 `Constants.ETH` 表示原生 ETH。
    /// @param recipient 收款地址。
    /// @param portion 占总余额的比例，其中 1e18 表示 100%。
    function payPortionFullPrecision(address token, address recipient, uint256 portion) internal {
        if (portion > 1e18) revert InvalidPortion();
        if (token == Constants.ETH) {
            uint256 balance = address(this).balance;
            uint256 amount = balance * portion / 1e18;
            recipient.safeTransferETH(amount);
        } else {
            uint256 balance = ERC20(token).balanceOf(address(this));
            uint256 amount = balance * portion / 1e18;
            ERC20(token).safeTransfer(recipient, amount);
        }
    }

    /// @notice 将路由器持有的某种 ERC20 或 ETH 全部归集到指定地址。
    /// @dev `amountMinimum` 同时承担最终滑点/余额下限检查，避免前序命令产出不足时仍把低于预期的余额转走。
    /// @param token 待归集资产地址；使用 `Constants.ETH` 表示原生 ETH。
    /// @param recipient 接收全部余额的地址。
    /// @param amountMinimum 可接受的最小归集数量。
    function sweep(address token, address recipient, uint256 amountMinimum) internal {
        uint256 balance;
        if (token == Constants.ETH) {
            balance = address(this).balance;
            if (balance < amountMinimum) revert InsufficientETH();
            if (balance > 0) recipient.safeTransferETH(balance);
        } else {
            balance = ERC20(token).balanceOf(address(this));
            if (balance < amountMinimum) revert InsufficientToken();
            if (balance > 0) ERC20(token).safeTransfer(recipient, balance);
        }
    }

    /// @notice 将路由器持有的指定数量 ETH 包装为 WETH9。
    /// @dev 可把 WETH9 留在路由器中供后续 swap 使用，也可直接发送给最终接收者。
    /// @param recipient WETH9 接收者。
    /// @param amount 包装数量；可使用 `CONTRACT_BALANCE` 表示路由器全部 ETH 余额。
    function wrapETH(address recipient, uint256 amount) internal {
        if (amount == ActionConstants.CONTRACT_BALANCE) {
            amount = address(this).balance;
        } else if (amount > address(this).balance) {
            revert InsufficientETH();
        }
        if (amount > 0) {
            WETH9.deposit{value: amount}();
            if (recipient != address(this)) {
                WETH9.transfer(recipient, amount);
            }
        }
    }

    /// @notice 将路由器持有的全部 WETH9 解包为 ETH。
    /// @dev 解包前检查最低数量；接收者为路由器自身时，ETH 会保留给后续命令使用。
    /// @param recipient ETH 接收者。
    /// @param amountMinimum 可接受的最小 WETH9/ETH 数量。
    function unwrapWETH9(address recipient, uint256 amountMinimum) internal {
        uint256 value = WETH9.balanceOf(address(this));
        if (value < amountMinimum) {
            revert InsufficientETH();
        }
        if (value > 0) {
            WETH9.withdraw(value);
            if (recipient != address(this)) {
                recipient.safeTransferETH(value);
            }
        }
    }
}
