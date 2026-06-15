// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {V2SwapRouter} from '../modules/uniswap/v2/V2SwapRouter.sol';
import {V3SwapRouter} from '../modules/uniswap/v3/V3SwapRouter.sol';
import {V4SwapRouter} from '../modules/uniswap/v4/V4SwapRouter.sol';
import {BytesLib} from '../modules/uniswap/v3/BytesLib.sol';
import {Payments} from '../modules/Payments.sol';
import {PaymentsImmutables} from '../modules/PaymentsImmutables.sol';
import {V3ToV4Migrator} from '../modules/V3ToV4Migrator.sol';
import {Commands} from '../libraries/Commands.sol';
import {Lock} from './Lock.sol';
import {ERC20} from 'solmate/src/tokens/ERC20.sol';
import {IAllowanceTransfer} from 'permit2/src/interfaces/IAllowanceTransfer.sol';
import {ActionConstants} from '@uniswap/v4-periphery/src/libraries/ActionConstants.sol';
import {CalldataDecoder} from '@uniswap/v4-periphery/src/libraries/CalldataDecoder.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {ChainedActions} from '../modules/ChainedActions.sol';

/// @title Universal Router 命令解码与分发器
/// @notice 由 UniversalRouter 调用，以低 gas 的嵌套分支解码单字节命令，并转交给对应业务模块执行。
abstract contract Dispatcher is
    Payments,
    V2SwapRouter,
    V3SwapRouter,
    V4SwapRouter,
    V3ToV4Migrator,
    Lock,
    ChainedActions
{
    using BytesLib for bytes;
    using CalldataDecoder for bytes;

    error InvalidCommandType(uint256 commandType);
    error BalanceTooLow();

    /// @notice 执行拼接后的命令字节流及其逐项 ABI 编码输入。
    /// @param commands 拼接后的命令集合，每条命令占 1 字节。
    /// @param inputs 与命令索引一一对应的 ABI 编码参数数组。
    function execute(bytes calldata commands, bytes[] calldata inputs) external payable virtual;

    /// @notice 返回整条路由最初取得锁的调用者，用来代替可能失真的 `msg.sender`。
    /// @dev 执行子计划时合约会自调用，此时 `msg.sender == address(this)`；本函数仍返回外层用户。
    /// 同时覆盖 V4Router 中 `BaseActionsRouter.msgSender` 的实现，使 V4 action 也共享同一用户语义。
    function msgSender() public view override returns (address) {
        return _getLocker();
    }

    /// @notice 解码一条命令及其输入，并调用对应的交换、支付、授权、迁移或跨链逻辑。
    /// @param commandType 待执行的单字节命令；高位可携带允许失败标志，低 7 位表示命令类型。
    /// @param inputs 该命令对应的 ABI 编码参数。
    /// @dev 先用掩码提取命令类型，再按数值区间进入嵌套 `if`。这种布局与 `Commands` 常量分组一致，
    /// 可减少逐项比较带来的 gas。低级解码只读取所需静态槽，动态 path/数组再由 BytesLib 定位。
    /// @return success 命令是否成功；允许失败的外层逻辑可据此决定是否继续。
    /// @return output 外部低级调用的返回数据或回滚信息；无返回数据的内部命令通常为空。
    function dispatch(bytes1 commandType, bytes calldata inputs) internal returns (bool success, bytes memory output) {
        uint256 command = uint8(commandType & Commands.COMMAND_TYPE_MASK);

        success = true;

        // 0x00 <= command < 0x21：内置交换、Permit2、支付、V4 与头寸迁移命令。
        if (command < Commands.EXECUTE_SUB_PLAN) {
            // 0x00 <= command < 0x10：V2/V3 swap、Permit2 和基础支付。
            if (command < Commands.V4_SWAP) {
                // 0x00 <= command < 0x08：V3 swap、Permit2 单笔转账/批量许可及余额支付。
                if (command < Commands.V2_SWAP_EXACT_IN) {
                    if (command == Commands.V3_SWAP_EXACT_IN) {
                        // 等价于：abi.decode(inputs, (address, uint256, uint256, bytes, bool, uint256[]))
                        address recipient;
                        uint256 amountIn;
                        uint256 amountOutMin;
                        bool payerIsUser;
                        assembly {
                            recipient := calldataload(inputs.offset)
                            amountIn := calldataload(add(inputs.offset, 0x20))
                            amountOutMin := calldataload(add(inputs.offset, 0x40))
                            // 0x60 槽存放动态 path 的偏移量，稍后由 BytesLib 解码。
                            payerIsUser := calldataload(add(inputs.offset, 0x80))
                        }
                        bytes calldata path = inputs.toBytes(3);
                        uint256[] calldata minHopPriceX36 = inputs.toUint256Array(5);
                        address payer = payerIsUser ? msgSender() : address(this);
                        v3SwapExactInput(map(recipient), amountIn, amountOutMin, path, payer, minHopPriceX36);
                    } else if (command == Commands.V3_SWAP_EXACT_OUT) {
                        // 等价于：abi.decode(inputs, (address, uint256, uint256, bytes, bool, uint256[]))
                        address recipient;
                        uint256 amountOut;
                        uint256 amountInMax;
                        bool payerIsUser;
                        assembly {
                            recipient := calldataload(inputs.offset)
                            amountOut := calldataload(add(inputs.offset, 0x20))
                            amountInMax := calldataload(add(inputs.offset, 0x40))
                            // 0x60 槽存放动态 path 的偏移量，稍后由 BytesLib 解码。
                            payerIsUser := calldataload(add(inputs.offset, 0x80))
                        }
                        bytes calldata path = inputs.toBytes(3);
                        uint256[] calldata minHopPriceX36 = inputs.toUint256Array(5);
                        address payer = payerIsUser ? msgSender() : address(this);
                        v3SwapExactOutput(map(recipient), amountOut, amountInMax, path, payer, minHopPriceX36);
                    } else if (command == Commands.PERMIT2_TRANSFER_FROM) {
                        // 等价于：abi.decode(inputs, (address, address, uint160))
                        address token;
                        address recipient;
                        uint160 amount;
                        assembly {
                            token := calldataload(inputs.offset)
                            recipient := calldataload(add(inputs.offset, 0x20))
                            amount := calldataload(add(inputs.offset, 0x40))
                        }
                        permit2TransferFrom(token, msgSender(), map(recipient), amount);
                    } else if (command == Commands.PERMIT2_PERMIT_BATCH) {
                        IAllowanceTransfer.PermitBatch calldata permitBatch;
                        assembly {
                            // PermitBatch 是动态长度结构体；首槽保存它相对 `inputs.offset` 的起始偏移。
                            permitBatch := add(inputs.offset, calldataload(inputs.offset))
                        }
                        bytes calldata data = inputs.toBytes(1);
                        (success, output) = address(PERMIT2)
                            .call(
                                abi.encodeWithSignature(
                                    'permit(address,((address,uint160,uint48,uint48)[],address,uint256),bytes)',
                                    msgSender(),
                                    permitBatch,
                                    data
                                )
                            );
                    } else if (command == Commands.SWEEP) {
                        // 等价于：abi.decode(inputs, (address, address, uint256))
                        address token;
                        address recipient;
                        uint160 amountMin;
                        assembly {
                            token := calldataload(inputs.offset)
                            recipient := calldataload(add(inputs.offset, 0x20))
                            amountMin := calldataload(add(inputs.offset, 0x40))
                        }
                        Payments.sweep(token, map(recipient), amountMin);
                    } else if (command == Commands.TRANSFER) {
                        // 等价于：abi.decode(inputs, (address, address, uint256))
                        address token;
                        address recipient;
                        uint256 value;
                        assembly {
                            token := calldataload(inputs.offset)
                            recipient := calldataload(add(inputs.offset, 0x20))
                            value := calldataload(add(inputs.offset, 0x40))
                        }
                        Payments.pay(token, map(recipient), value);
                    } else if (command == Commands.PAY_PORTION) {
                        // 等价于：abi.decode(inputs, (address, address, uint256))
                        address token;
                        address recipient;
                        uint256 bips;
                        assembly {
                            token := calldataload(inputs.offset)
                            recipient := calldataload(add(inputs.offset, 0x20))
                            bips := calldataload(add(inputs.offset, 0x40))
                        }
                        Payments.payPortion(token, map(recipient), bips);
                    } else if (command == Commands.PAY_PORTION_FULL_PRECISION) {
                        // 等价于：abi.decode(inputs, (address, address, uint256))
                        address token;
                        address recipient;
                        uint256 portion;
                        assembly {
                            token := calldataload(inputs.offset)
                            recipient := calldataload(add(inputs.offset, 0x20))
                            portion := calldataload(add(inputs.offset, 0x40))
                        }
                        Payments.payPortionFullPrecision(token, map(recipient), portion);
                    } else {
                        revert InvalidCommandType(command);
                    }
                } else {
                    // 0x08 <= command < 0x10：V2 swap、Permit2 单笔许可、ETH/WETH 与余额检查。
                    if (command == Commands.V2_SWAP_EXACT_IN) {
                        // 等价于：abi.decode(inputs, (address, uint256, uint256, address[], bool, uint256[]))
                        address recipient;
                        uint256 amountIn;
                        uint256 amountOutMin;
                        bool payerIsUser;
                        assembly {
                            recipient := calldataload(inputs.offset)
                            amountIn := calldataload(add(inputs.offset, 0x20))
                            amountOutMin := calldataload(add(inputs.offset, 0x40))
                            // 0x60 槽存放动态 address[] path 的偏移量，稍后解码。
                            payerIsUser := calldataload(add(inputs.offset, 0x80))
                        }
                        address[] calldata path = inputs.toAddressArray(3);
                        uint256[] calldata minHopPriceX36 = inputs.toUint256Array(5);
                        address payer = payerIsUser ? msgSender() : address(this);
                        v2SwapExactInput(map(recipient), amountIn, amountOutMin, path, payer, minHopPriceX36);
                    } else if (command == Commands.V2_SWAP_EXACT_OUT) {
                        // 等价于：abi.decode(inputs, (address, uint256, uint256, address[], bool, uint256[]))
                        address recipient;
                        uint256 amountOut;
                        uint256 amountInMax;
                        bool payerIsUser;
                        assembly {
                            recipient := calldataload(inputs.offset)
                            amountOut := calldataload(add(inputs.offset, 0x20))
                            amountInMax := calldataload(add(inputs.offset, 0x40))
                            // 0x60 槽存放动态 address[] path 的偏移量，稍后解码。
                            payerIsUser := calldataload(add(inputs.offset, 0x80))
                        }
                        address[] calldata path = inputs.toAddressArray(3);
                        uint256[] calldata minHopPriceX36 = inputs.toUint256Array(5);
                        address payer = payerIsUser ? msgSender() : address(this);
                        v2SwapExactOutput(map(recipient), amountOut, amountInMax, path, payer, minHopPriceX36);
                    } else if (command == Commands.PERMIT2_PERMIT) {
                        // 等价于：abi.decode(inputs, (IAllowanceTransfer.PermitSingle, bytes))
                        IAllowanceTransfer.PermitSingle calldata permitSingle;
                        assembly {
                            permitSingle := inputs.offset
                        }
                        bytes calldata data = inputs.toBytes(6); // PermitSingle 占用前 6 个槽（0..5）。
                        (success, output) = address(PERMIT2)
                            .call(
                                abi.encodeWithSignature(
                                    'permit(address,((address,uint160,uint48,uint48),address,uint256),bytes)',
                                    msgSender(),
                                    permitSingle,
                                    data
                                )
                            );
                    } else if (command == Commands.WRAP_ETH) {
                        // 等价于：abi.decode(inputs, (address, uint256))
                        address recipient;
                        uint256 amount;
                        assembly {
                            recipient := calldataload(inputs.offset)
                            amount := calldataload(add(inputs.offset, 0x20))
                        }
                        Payments.wrapETH(map(recipient), amount);
                    } else if (command == Commands.UNWRAP_WETH) {
                        // 等价于：abi.decode(inputs, (address, uint256))
                        address recipient;
                        uint256 amountMin;
                        assembly {
                            recipient := calldataload(inputs.offset)
                            amountMin := calldataload(add(inputs.offset, 0x20))
                        }
                        Payments.unwrapWETH9(map(recipient), amountMin);
                    } else if (command == Commands.PERMIT2_TRANSFER_FROM_BATCH) {
                        IAllowanceTransfer.AllowanceTransferDetails[] calldata batchDetails;
                        (uint256 length, uint256 offset) = inputs.toLengthOffset(0);
                        assembly {
                            batchDetails.length := length
                            batchDetails.offset := offset
                        }
                        permit2TransferFrom(batchDetails, msgSender());
                    } else if (command == Commands.BALANCE_CHECK_ERC20) {
                        // 等价于：abi.decode(inputs, (address, address, uint256))
                        address owner;
                        address token;
                        uint256 minBalance;
                        assembly {
                            owner := calldataload(inputs.offset)
                            token := calldataload(add(inputs.offset, 0x20))
                            minBalance := calldataload(add(inputs.offset, 0x40))
                        }
                        success = (ERC20(token).balanceOf(owner) >= minBalance);
                        if (!success) output = abi.encodePacked(BalanceTooLow.selector);
                    } else {
                        // 0x0f 为预留命令位，当前不允许执行。
                        revert InvalidCommandType(command);
                    }
                }
            } else {
                // 0x10 <= command < 0x21：V4 actions、V3/V4 PositionManager 与池初始化。
                if (command == Commands.V4_SWAP) {
                    // 将原始 calldata 交给 BaseActionsRouter 定义的 `_executeActions`，按 V4 action 序列结算。
                    _executeActions(inputs);
                    // 调用 PositionManager 的主体是本路由器，因此用户必须事先授权本路由器操作对应 NFT。
                } else if (command == Commands.V3_POSITION_MANAGER_PERMIT) {
                    _checkV3PermitCall(inputs);
                    (success, output) = address(V3_POSITION_MANAGER).call(inputs);
                } else if (command == Commands.V3_POSITION_MANAGER_CALL) {
                    _checkV3PositionManagerCall(inputs, msgSender());
                    (success, output) = address(V3_POSITION_MANAGER).call(inputs);
                } else if (command == Commands.V4_INITIALIZE_POOL) {
                    PoolKey calldata poolKey;
                    uint160 sqrtPriceX96;
                    assembly {
                        poolKey := inputs.offset
                        sqrtPriceX96 := calldataload(add(inputs.offset, 0xa0))
                    }
                    (success, output) =
                        address(poolManager).call(abi.encodeCall(IPoolManager.initialize, (poolKey, sqrtPriceX96)));
                } else if (command == Commands.V4_POSITION_MANAGER_CALL) {
                    // 仅允许调用 `modifyLiquidities()`，并由迁移校验进一步限制为安全的 mint 流程。
                    _checkV4PositionManagerCall(inputs);
                    (success, output) = address(V4_POSITION_MANAGER).call{value: address(this).balance}(inputs);
                } else {
                    // 0x15-0x20 为预留命令区间。
                    revert InvalidCommandType(command);
                }
            }
        } else if (command < Commands.ACROSS_V4_DEPOSIT_V3) {
            // 0x21 <= command < 0x40：子计划及后续内置扩展区间。
            if (command == Commands.EXECUTE_SUB_PLAN) {
                (bytes calldata _commands, bytes[] calldata _inputs) = inputs.decodeCommandsAndInputs();
                (success, output) = (address(this)).call(abi.encodeCall(Dispatcher.execute, (_commands, _inputs)));
            } else {
                // 0x22-0x3f 为预留命令区间。
                revert InvalidCommandType(command);
            }
        } else {
            if (command == Commands.ACROSS_V4_DEPOSIT_V3) {
                _acrossV4DepositV3(inputs);
            } else {
                // 0x41-0x5f 为第三方集成预留区间。
                revert InvalidCommandType(command);
            }
        }
    }

    /// @notice 将命令中的特殊接收者标志解析为实际地址。
    /// @dev `MSG_SENDER` 映射到整条路由的原始用户，`ADDRESS_THIS` 映射到 Universal Router；
    /// 普通地址保持不变。这样中间 hop 可先由路由器托管，最终输出再发送给用户。
    /// @param recipient 命令指定的接收地址或特殊接收者标志。
    /// @return output 解析后的实际接收地址。
    function map(address recipient) internal view returns (address) {
        if (recipient == ActionConstants.MSG_SENDER) {
            return msgSender();
        } else if (recipient == ActionConstants.ADDRESS_THIS) {
            return address(this);
        } else {
            return recipient;
        }
    }
}
