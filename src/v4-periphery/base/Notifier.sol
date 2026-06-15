// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ISubscriber} from "../interfaces/ISubscriber.sol";
import {INotifier} from "../interfaces/INotifier.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PositionInfo} from "../libraries/PositionInfoLibrary.sol";

/// @notice 为仓位提供可选订阅机制，把订阅、流动性变化、销毁和转让相关状态通知给外部合约。
/// @dev 每个 tokenId 最多绑定一个订阅者。普通修改通知失败会使仓位操作回退；
/// 主动取消订阅则必须始终可完成，防止恶意订阅者永久锁死用户流动性。
abstract contract Notifier is INotifier {
    using CustomRevert for *;

    ISubscriber private constant NO_SUBSCRIBER = ISubscriber(address(0));

    /// @notice 取消订阅通知允许使用的最大 gas，限制外部订阅者消耗。
    uint256 public immutable unsubscribeGasLimit;

    /// @notice 返回每个仓位 NFT 当前绑定的订阅者合约。
    mapping(uint256 tokenId => ISubscriber subscriber) public subscriber;

    constructor(uint256 _unsubscribeGasLimit) {
        unsubscribeGasLimit = _unsubscribeGasLimit;
    }

    /// @notice 仅允许 tokenId 的 owner、单独授权地址或 operator 继续执行。
    /// @dev 由父合约 `PositionManager` 根据其 ERC-721 权限模型实现。
    /// @param caller 要校验的调用者。
    /// @param tokenId 仓位 NFT 的 token ID。
    modifier onlyIfApproved(address caller, uint256 tokenId) virtual;

    /// @notice 要求 `PoolManager` 已锁定，避免仓位修改回调与订阅状态变更交错。
    modifier onlyIfPoolManagerLocked() virtual;

    function _setUnsubscribed(uint256 tokenId) internal virtual;

    function _setSubscribed(uint256 tokenId) internal virtual;

    /// @notice 为仓位绑定订阅者，使其接收后续仓位变化通知。
    /// @param tokenId 要订阅的仓位 NFT。
    /// @param newSubscriber 实现 `ISubscriber` 的订阅者合约。
    /// @param data 原样转发给 `notifySubscribe` 的集成方数据。
    /// @dev 仓位已订阅、调用者无权限、订阅者无代码或订阅回调失败时回退。
    function subscribe(uint256 tokenId, address newSubscriber, bytes calldata data)
        external
        payable
        onlyIfPoolManagerLocked
        onlyIfApproved(msg.sender, tokenId)
    {
        ISubscriber _subscriber = subscriber[tokenId];

        if (_subscriber != NO_SUBSCRIBER) revert AlreadySubscribed(tokenId, address(_subscriber));
        _setSubscribed(tokenId);

        subscriber[tokenId] = ISubscriber(newSubscriber);

        bool success = _call(newSubscriber, abi.encodeCall(ISubscriber.notifySubscribe, (tokenId, data)));

        if (!success) {
            newSubscriber.bubbleUpAndRevertWith(ISubscriber.notifySubscribe.selector, SubscriptionReverted.selector);
        }

        emit Subscription(tokenId, newSubscriber);
    }

    /// @notice 取消仓位订阅，并尽力通知原订阅者。
    /// @param tokenId 要取消订阅的仓位 NFT。
    /// @dev 调用者必须保留足够 gas 供固定额度通知。通知本身失败不会阻止取消订阅，
    /// 从而保证恶意或故障订阅者不能锁住用户仓位。
    function unsubscribe(uint256 tokenId) external payable onlyIfPoolManagerLocked onlyIfApproved(msg.sender, tokenId) {
        _unsubscribe(tokenId);
    }

    function _unsubscribe(uint256 tokenId) internal {
        ISubscriber _subscriber = subscriber[tokenId];

        if (_subscriber == NO_SUBSCRIBER) revert NotSubscribed();
        _setUnsubscribed(tokenId);

        delete subscriber[tokenId];

        if (address(_subscriber).code.length > 0) {
            // 要求剩余 gas 足以完整提供固定通知额度；否则用户可故意压低 gas，
            // 让 notifyUnsubscribe 因 OOG 失败却仍完成取消订阅，破坏订阅者的状态同步预期。
            if (gasleft() < unsubscribeGasLimit) GasLimitTooLow.selector.revertWith();
            try _subscriber.notifyUnsubscribe{gas: unsubscribeGasLimit}(tokenId) {} catch {}
        }

        emit Unsubscription(tokenId, address(_subscriber));
    }

    /// @dev 仓位销毁时删除订阅映射并通知订阅者；通知失败会使销毁回退。
    function _removeSubscriberAndNotifyBurn(
        uint256 tokenId,
        address owner,
        PositionInfo info,
        uint256 liquidity,
        BalanceDelta feesAccrued
    ) internal {
        address _subscriber = address(subscriber[tokenId]);

        // 先删除订阅关系，避免外部回调重入时仍观察到旧订阅者。
        delete subscriber[tokenId];

        bool success =
            _call(_subscriber, abi.encodeCall(ISubscriber.notifyBurn, (tokenId, owner, info, liquidity, feesAccrued)));

        if (!success) {
            _subscriber.bubbleUpAndRevertWith(ISubscriber.notifyBurn.selector, BurnNotificationReverted.selector);
        }
    }

    function _notifyModifyLiquidity(uint256 tokenId, int256 liquidityChange, BalanceDelta feesAccrued) internal {
        address _subscriber = address(subscriber[tokenId]);

        bool success = _call(
            _subscriber, abi.encodeCall(ISubscriber.notifyModifyLiquidity, (tokenId, liquidityChange, feesAccrued))
        );

        if (!success) {
            _subscriber.bubbleUpAndRevertWith(
                ISubscriber.notifyModifyLiquidity.selector, ModifyLiquidityNotificationReverted.selector
            );
        }
    }

    function _call(address target, bytes memory encodedCall) internal returns (bool success) {
        if (target.code.length == 0) NoCodeSubscriber.selector.revertWith();
        assembly ("memory-safe") {
            success := call(gas(), target, 0, add(encodedCall, 0x20), mload(encodedCall), 0, 0)
        }
    }
}
