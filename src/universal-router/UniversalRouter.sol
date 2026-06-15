// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

// Universal Router 命令实现与执行上下文
import {Dispatcher} from './base/Dispatcher.sol';
import {RouteSigner} from './base/RouteSigner.sol';
import {RouterParameters} from './types/RouterParameters.sol';
import {PaymentsImmutables, PaymentsParameters} from './modules/PaymentsImmutables.sol';
import {UniswapImmutables, UniswapParameters} from './modules/uniswap/UniswapImmutables.sol';
import {V4SwapRouter} from './modules/uniswap/v4/V4SwapRouter.sol';
import {Commands} from './libraries/Commands.sol';
import {IUniversalRouter} from './interfaces/IUniversalRouter.sol';
import {MigratorImmutables, MigratorParameters} from './modules/MigratorImmutables.sol';
import {EIP712} from '@openzeppelin/contracts/utils/cryptography/EIP712.sol';
import {ChainedActions} from './modules/ChainedActions.sol';

contract UniversalRouter is IUniversalRouter, ChainedActions, RouteSigner, Dispatcher {
    constructor(RouterParameters memory params)
        UniswapImmutables(UniswapParameters(
                params.v2Factory, params.v3Factory, params.pairInitCodeHash, params.poolInitCodeHash
            ))
        V4SwapRouter(params.v4PoolManager, params.permissionsAdapterFactory)
        PaymentsImmutables(PaymentsParameters(params.permit2, params.weth9))
        MigratorImmutables(MigratorParameters(params.v3NFTPositionManager, params.v4PositionManager))
        ChainedActions(params.spokePool)
        EIP712('UniversalRouter', '2')
    {}

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert TransactionDeadlinePassed();
        _;
    }

    /// @notice 接收 WETH9 解包或 V4 PoolManager 结算时退回的 ETH。
    /// @dev 不接受普通地址直接转入 ETH；用户携带 ETH 执行路由时应调用带 calldata 的 payable 执行入口。
    receive() external payable {
        if (msg.sender != address(WETH9) && msg.sender != address(poolManager)) revert InvalidEthSender();
    }

    /// @notice 在截止时间前按顺序执行一组编码命令。
    /// @dev `commands` 中每个字节对应 `inputs` 中同索引的一份 ABI 编码参数；整个调用共享同一付款、
    /// 锁和路由余额上下文，可在一次交易中组合 V2、V3、V4、Permit2 与支付命令。
    /// @param commands 拼接后的命令字节流，每条命令占 1 字节。
    /// @param inputs 与命令逐项对应的 ABI 编码参数数组。
    /// @param deadline 交易必须完成的最后时间戳。
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline)
        external
        payable
        checkDeadline(deadline)
    {
        execute(commands, inputs);
    }

    /// @notice 验证 EIP-712 路由签名后，在截止时间前执行整组命令。
    /// @dev 签名覆盖顶层命令、全部输入及其嵌套子计划。验证成功后，签名者、业务意图和附加数据会写入
    /// transient storage，供本次执行中的 V4 hook 或其他命令读取；执行结束后立即清空。
    /// `verifySender=true` 时签名还绑定实际提交交易的 `msg.sender`，可防止第三方代提交。
    /// @param commands 拼接后的命令字节流，每条命令占 1 字节。
    /// @param inputs 与命令逐项对应的 ABI 编码参数数组。
    /// @param intent 应用定义的路由意图标识。
    /// @param data 应用定义的附加上下文。
    /// @param verifySender 是否把当前 `msg.sender` 纳入签名校验。
    /// @param nonce 防重放的无序 nonce；设为 `bytes32(type(uint256).max)` 可跳过 nonce 消耗。
    /// @param signature 授权本次执行的 EIP-712 签名。
    /// @param deadline 交易必须完成的最后时间戳。
    function executeSigned(
        bytes calldata commands,
        bytes[] calldata inputs,
        bytes32 intent,
        bytes32 data,
        bool verifySender,
        bytes32 nonce,
        bytes calldata signature,
        uint256 deadline
    ) external payable checkDeadline(deadline) {
        // 先验签并建立本次路由可读取的签名上下文。
        _setSignatureContext(commands, inputs, intent, data, verifySender, nonce, signature, deadline);

        // 在同一个锁与签名上下文中执行全部命令。
        execute(commands, inputs);

        // 执行结束后清除瞬态上下文，避免后续调用读到旧签名数据。
        _resetSignatureContext();
    }

    /// @notice 按索引逐条分发编码命令，并将对应的 ABI 输入交给具体 V2-V4、支付或迁移模块执行。
    /// @dev 外部调用会取得锁；`EXECUTE_SUB_PLAN` 通过合约自调用进入时允许自重入，从而复用同一原始
    /// 调用者。命令最高位可设置 `FLAG_ALLOW_REVERT`，允许该条失败后继续执行后续命令。
    /// @param commands 拼接后的命令字节流，每条命令占 1 字节。
    /// @param inputs 与命令逐项对应的 ABI 编码参数数组，长度必须与 `commands` 相同。
    function execute(bytes calldata commands, bytes[] calldata inputs) public payable override isNotLocked {
        bool success;
        bytes memory output;
        uint256 numCommands = commands.length;
        if (inputs.length != numCommands) revert LengthMismatch();

        // 顺序执行全部命令；只有未设置允许失败标志的命令失败时，才回滚整笔路由交易。
        for (uint256 commandIndex = 0; commandIndex < numCommands; commandIndex++) {
            bytes1 command = commands[commandIndex];

            bytes calldata input = inputs[commandIndex];

            (success, output) = dispatch(command, input);

            if (!success && successRequired(command)) {
                revert ExecutionFailed({commandIndex: commandIndex, message: output});
            }
        }
    }

    /// @notice 一次性返回当前签名路由的签名者、业务意图和附加数据。
    /// @dev 仅 `executeSigned` 执行期间 transient storage 中存在这些值。外部 hook 使用时必须同时确认
    /// 调用者确实是本 Universal Router，否则执行链上的恶意合约可能借用合法上下文触发非预期操作。
    /// @return signer 当前路由签名者；非签名执行时为 `address(0)`。
    /// @return intent 签名中的业务意图；非签名执行时为 `bytes32(0)`。
    /// @return data 签名中的附加数据；非签名执行时为 `bytes32(0)`。
    function signedRouteContext() external view returns (address signer, bytes32 intent, bytes32 data) {
        return _signedRouteContext();
    }

    function successRequired(bytes1 command) internal pure returns (bool) {
        return command & Commands.FLAG_ALLOW_REVERT == 0;
    }
}
