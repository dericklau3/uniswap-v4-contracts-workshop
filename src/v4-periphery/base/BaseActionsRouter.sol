// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SafeCallback} from "./SafeCallback.sol";
import {CalldataDecoder} from "../libraries/CalldataDecoder.sol";
import {ActionConstants} from "../libraries/ActionConstants.sol";
import {IMsgSender} from "../interfaces/IMsgSender.sol";

/// @notice 在一次 Uniswap V4 解锁周期内组合并执行多项操作的抽象路由基类。
/// @dev `Actions.sol` 给出了推荐的 `uint256` 动作编号，但继承合约也可以定义自己的编号体系。
/// 调用链通常为：外部入口组装 `actions + params`，本合约请求 `PoolManager.unlock`，
/// 再由 `unlockCallback` 回调逐项分派。整个批次共享同一组瞬时货币 delta，便于把兑换、增减流动性和结算原子化。
abstract contract BaseActionsRouter is IMsgSender, SafeCallback {
    using CalldataDecoder for bytes;

    /// @notice 当动作数量与参数数组长度不一致时回退，避免动作读取到错误的参数。
    error InputLengthMismatch();

    /// @notice 当继承合约不支持给定动作编号时回退。
    error UnsupportedAction(uint256 action);

    constructor(IPoolManager _poolManager) SafeCallback(_poolManager) {}

    /// @notice 请求 `PoolManager` 解锁并触发一组 V4 动作。
    /// @dev 继承合约的标准外部入口应调用本函数。实际动作会在 `PoolManager` 回调 `_unlockCallback` 时执行，
    /// 因而执行期间 `msg.sender` 是 `PoolManager`，原始用户地址必须通过 `msgSender()` 恢复。
    function _executeActions(bytes calldata unlockData) internal {
        poolManager.unlock(unlockData);
    }

    /// @notice 由 `PoolManager` 经 `SafeCallback.unlockCallback` 调用，解码并执行整个动作批次。
    /// @param data `(bytes actions, bytes[] params)` 的 ABI 编码；`params[i]` 是 `actions[i]` 对应的编码参数。
    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        // 与 abi.decode(data, (bytes, bytes[])) 等价，但直接返回 calldata 切片以减少复制和 gas。
        (bytes calldata actions, bytes[] calldata params) = data.decodeActionsRouterParams();
        _executeActionsWithoutUnlock(actions, params);
        return "";
    }

    function _executeActionsWithoutUnlock(bytes calldata actions, bytes[] calldata params) internal {
        uint256 numActions = actions.length;
        if (numActions != params.length) revert InputLengthMismatch();

        for (uint256 actionIndex = 0; actionIndex < numActions; actionIndex++) {
            uint256 action = uint8(actions[actionIndex]);

            _handleAction(action, params[actionIndex]);
        }
    }

    /// @notice 解析一个动作及其参数并执行；具体支持哪些动作由继承合约决定。
    function _handleAction(uint256 action, bytes calldata params) internal virtual;

    /// @notice 返回在业务上被视为本批动作执行者的地址。
    /// @dev 本合约不提供 `_msgData`、`_msgValue` 等其他上下文函数。通常该地址是调用外部入口并触发
    /// `_executeActions` 的原始调用者；不能直接使用 `msg.sender`，因为回调阶段它是 V4 `PoolManager`。
    /// 若继承合约使用 `ReentrancyLock.sol`，可通过 `_getLocker()` 返回已保存的原始调用者。
    function msgSender() public view virtual returns (address);

    /// @notice 将动作参数中的特殊收款人常量映射为原始调用者、本合约或显式地址。
    function _mapRecipient(address recipient) internal view returns (address) {
        if (recipient == ActionConstants.MSG_SENDER) {
            return msgSender();
        } else if (recipient == ActionConstants.ADDRESS_THIS) {
            return address(this);
        } else {
            return recipient;
        }
    }

    /// @notice 根据动作参数决定付款方是原始用户还是当前路由合约。
    function _mapPayer(bool payerIsUser) internal view returns (address) {
        return payerIsUser ? msgSender() : address(this);
    }
}
