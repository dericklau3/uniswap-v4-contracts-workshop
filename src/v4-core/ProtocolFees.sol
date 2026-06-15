// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Currency} from "./types/Currency.sol";
import {CurrencyReserves} from "./libraries/CurrencyReserves.sol";
import {IProtocolFees} from "./interfaces/IProtocolFees.sol";
import {PoolKey} from "./types/PoolKey.sol";
import {ProtocolFeeLibrary} from "./libraries/ProtocolFeeLibrary.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {PoolId} from "./types/PoolId.sol";
import {Pool} from "./libraries/Pool.sol";
import {CustomRevert} from "./libraries/CustomRevert.sol";

/// @notice 负责设置、累计和提取 Uniswap V4 协议费的抽象合约。
abstract contract ProtocolFees is IProtocolFees, Owned {
    using ProtocolFeeLibrary for uint24;
    using Pool for Pool.State;
    using CustomRevert for bytes4;

    /// @notice 按货币记录当前累计、尚未提取的协议费；public getter 接收 currency 并返回对应 amount。
    mapping(Currency currency => uint256 amount) public protocolFeesAccrued;

    /// @notice 当前有权设置和提取协议费的 controller 地址；public getter 返回该地址。
    address public protocolFeeController;

    constructor(address initialOwner) Owned(initialOwner) {}

    /// @notice 由 owner 更新协议费 controller。
    /// @dev controller 负责按池设置费率并提取累计费用；设置后会发出 `ProtocolFeeControllerUpdated`。
    /// @param controller 新的协议费 controller 地址。
    function setProtocolFeeController(address controller) external onlyOwner {
        protocolFeeController = controller;
        emit ProtocolFeeControllerUpdated(controller);
    }

    /// @notice 为指定池设置两个兑换方向各自的协议费。
    /// @dev 仅 `protocolFeeController` 可调用；`newProtocolFee` 将两个方向的 12 bit 费率打包在一个 `uint24` 中，
    ///      每个方向都不得超过 1000 pips（0.1%）。更新后会发出 `ProtocolFeeUpdated`。
    /// @param key 目标池的完整 PoolKey。
    /// @param newProtocolFee 要写入的双向协议费打包值。
    function setProtocolFee(PoolKey memory key, uint24 newProtocolFee) external {
        if (msg.sender != protocolFeeController) InvalidCaller.selector.revertWith();
        if (!newProtocolFee.isValidProtocolFee()) ProtocolFeeTooLarge.selector.revertWith(newProtocolFee);
        PoolId id = key.toId();
        _getPool(id).setProtocolFee(newProtocolFee);
        emit ProtocolFeeUpdated(id, newProtocolFee);
    }

    /// @notice 将指定货币的已累计协议费转给 `recipient`。
    /// @dev 仅 `protocolFeeController` 可调用。若 `amount` 为 0，则提取该货币的全部累计协议费。
    ///      ERC20 货币处于 sync 到 settle 的结算窗口时禁止提取，避免协议费转账干扰余额差额计算。
    /// @param recipient 接收协议费的地址。
    /// @param currency 要提取的货币。
    /// @param amount 要提取的数量；传 0 表示全部提取。
    /// @return amountCollected 实际成功提取的数量。
    function collectProtocolFees(address recipient, Currency currency, uint256 amount)
        external
        returns (uint256 amountCollected)
    {
        if (msg.sender != protocolFeeController) InvalidCaller.selector.revertWith();
        if (!currency.isAddressZero() && CurrencyReserves.getSyncedCurrency() == currency) {
            // 防止在 sync 与 settle 两次 balanceOf 快照之间发生转账；原生币结算使用 msg.value，不走该快照差额。
            ProtocolFeeCurrencySynced.selector.revertWith();
        }

        amountCollected = (amount == 0) ? protocolFeesAccrued[currency] : amount;
        protocolFeesAccrued[currency] -= amountCollected;
        currency.transfer(recipient, amountCollected);
    }

    /// @dev 抽象内部函数，使 ProtocolFees 能读取 PoolManager 当前是否处于 unlock 结算窗口。
    function _isUnlocked() internal virtual returns (bool);

    /// @dev 抽象内部函数，使 ProtocolFees 能访问指定池的状态。
    /// @dev 该函数由 PoolManager.sol 重写，以提供对 `_pools` mapping 的访问。
    function _getPool(PoolId id) internal virtual returns (Pool.State storage);

    function _updateProtocolFees(Currency currency, uint256 amount) internal {
        unchecked {
            protocolFeesAccrued[currency] += amount;
        }
    }
}
