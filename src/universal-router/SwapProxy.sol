// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {ERC20} from 'solmate/src/tokens/ERC20.sol';
import {SafeTransferLib} from 'solmate/src/utils/SafeTransferLib.sol';
import {IUniversalRouter} from './interfaces/IUniversalRouter.sol';
import {ISwapProxy} from './interfaces/ISwapProxy.sol';

/// @title SwapProxy 交换代理
/// @notice 为不使用 Permit2 签名消息的用户提供“先 approve、再 swap”的两笔交易流程。
/// @dev 代理先把 ERC20 从用户直接转入 Universal Router（UR），再调用 UR 执行命令。由于输入资产此时
/// 已在路由器余额中，所有 swap 命令都必须设置 `payerIsUser=false`。接收者也必须填写用户的明确地址，
/// 不能使用 `MSG_SENDER`，因为在 UR 的执行上下文中 `MSG_SENDER` 会解析成当前代理合约。
/// 本代理只服务 ERC20 输入；以 ETH 为输入的操作应直接发送给 UR。
contract SwapProxy is ISwapProxy {
    using SafeTransferLib for ERC20;

    /// @notice 从调用者拉取 ERC20 到 Universal Router，然后执行对应的路由命令。
    /// @dev 调用前用户必须先向本代理授权 `token`。命令中的付款方应选择路由器余额，接收者应写用户地址。
    /// @param router 执行命令的 Universal Router。
    /// @param token 从调用者转出的 ERC20。
    /// @param amount 转入 Universal Router 的代币数量。
    /// @param commands Universal Router 的编码命令字节流。
    /// @param inputs 每条命令对应的 ABI 编码输入。
    /// @param deadline 路由交易截止时间。
    function execute(
        IUniversalRouter router,
        address token,
        uint256 amount,
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external {
        // 注意：Solmate SafeTransferLib 不检查 `token` 地址是否存在合约代码；
        // 对空地址发起的 transfer 调用可能静默成功，因此调用方必须提供真实 ERC20 地址。
        ERC20(token).safeTransferFrom(msg.sender, address(router), amount);
        router.execute(commands, inputs, deadline);
    }
}
