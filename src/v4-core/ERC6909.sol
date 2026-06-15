// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC6909Claims} from "./interfaces/external/IERC6909Claims.sol";

/// @notice 精简且节省 gas 的 ERC6909 标准实现，用一个合约统一管理多种 `id` 对应的同质化资产。
/// @author Solmate (https://github.com/transmissions11/solmate/blob/main/src/tokens/ERC6909.sol)
/// @dev 复制自提交 4b47a19038b798b4a33d9749d25e570443520647。
/// @dev 本合约已在上述链接版本的基础上做过修改。
abstract contract ERC6909 is IERC6909Claims {
    /*//////////////////////////////////////////////////////////////
                             ERC6909 存储
    //////////////////////////////////////////////////////////////*/

    mapping(address owner => mapping(address operator => bool isOperator)) public isOperator;

    mapping(address owner => mapping(uint256 id => uint256 balance)) public balanceOf;

    mapping(address owner => mapping(address spender => mapping(uint256 id => uint256 amount))) public allowance;

    /*//////////////////////////////////////////////////////////////
                              ERC6909 逻辑
    //////////////////////////////////////////////////////////////*/

    function transfer(address receiver, uint256 id, uint256 amount) public virtual returns (bool) {
        balanceOf[msg.sender][id] -= amount;

        balanceOf[receiver][id] += amount;

        emit Transfer(msg.sender, msg.sender, receiver, id, amount);

        return true;
    }

    function transferFrom(address sender, address receiver, uint256 id, uint256 amount) public virtual returns (bool) {
        if (msg.sender != sender && !isOperator[sender][msg.sender]) {
            uint256 allowed = allowance[sender][msg.sender][id];
            if (allowed != type(uint256).max) allowance[sender][msg.sender][id] = allowed - amount;
        }

        balanceOf[sender][id] -= amount;

        balanceOf[receiver][id] += amount;

        emit Transfer(msg.sender, sender, receiver, id, amount);

        return true;
    }

    function approve(address spender, uint256 id, uint256 amount) public virtual returns (bool) {
        allowance[msg.sender][spender][id] = amount;

        emit Approval(msg.sender, spender, id, amount);

        return true;
    }

    function setOperator(address operator, bool approved) public virtual returns (bool) {
        isOperator[msg.sender][operator] = approved;

        emit OperatorSet(msg.sender, operator, approved);

        return true;
    }

    /*//////////////////////////////////////////////////////////////
                              ERC165 逻辑
    //////////////////////////////////////////////////////////////*/

    function supportsInterface(bytes4 interfaceId) public view virtual returns (bool) {
        return interfaceId == 0x01ffc9a7 // ERC165 的 ERC165 Interface ID
            || interfaceId == 0x0f632fb3; // ERC6909 的 ERC165 Interface ID
    }

    /*//////////////////////////////////////////////////////////////
                        内部铸造/销毁逻辑
    //////////////////////////////////////////////////////////////*/

    function _mint(address receiver, uint256 id, uint256 amount) internal virtual {
        balanceOf[receiver][id] += amount;

        emit Transfer(msg.sender, address(0), receiver, id, amount);
    }

    function _burn(address sender, uint256 id, uint256 amount) internal virtual {
        balanceOf[sender][id] -= amount;

        emit Transfer(msg.sender, sender, address(0), id, amount);
    }
}
