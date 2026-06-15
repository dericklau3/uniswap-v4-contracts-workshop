// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {Payments} from './Payments.sol';
import {IV3SpokePool} from '../interfaces/external/IV3SpokePool.sol';
import {AcrossV4DepositV3Params} from '../interfaces/IUniversalRouter.sol';
import {IERC20, SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {ActionConstants} from '@uniswap/v4-periphery/src/libraries/ActionConstants.sol';

abstract contract ChainedActions is Payments {
    using SafeERC20 for IERC20;

    IV3SpokePool public immutable SPOKE_POOL;

    constructor(address spokePool) {
        SPOKE_POOL = IV3SpokePool(spokePool);
    }

    function _acrossV4DepositV3(bytes calldata input) internal {
        AcrossV4DepositV3Params memory params = abi.decode(input, (AcrossV4DepositV3Params));

        uint256 inputAmount = params.inputAmount;
        uint256 callValue = 0;

        // 解析 `CONTRACT_BALANCE` 哨兵值，使前序 swap 的全部产出可直接作为 Across 存款输入。
        if (inputAmount == ActionConstants.CONTRACT_BALANCE) {
            if (params.useNative) {
                inputAmount = address(this).balance;
            } else {
                inputAmount = IERC20(params.inputToken).balanceOf(address(this));
            }
        }

        if (params.useNative) {
            // 按 Across 约定，原生 ETH 路径仍以 WETH 作为 `inputToken` 标识；
            // Universal Router 此时必须实际持有等于 `inputAmount` 的 ETH，并作为 call value 发送。
            callValue = inputAmount;
        } else {
            // ERC20 路径由路由器授权 SpokePool 拉取本次存款数量。
            IERC20(params.inputToken).forceApprove(address(SPOKE_POOL), inputAmount);
        }

        SPOKE_POOL.depositV3{value: callValue}(
            params.depositor,
            params.recipient,
            params.inputToken,
            params.outputToken,
            inputAmount,
            params.outputAmount,
            params.destinationChainId,
            params.exclusiveRelayer,
            params.quoteTimestamp,
            params.fillDeadline,
            params.exclusivityDeadline,
            params.message
        );
    }
}
