// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IEIP712_v4} from "../interfaces/IEIP712_v4.sol";

/// @notice 通用 EIP-712 域分隔符和类型化数据哈希实现。
/// @dev 域中绑定 chainId 与当前合约地址，可在链分叉或跨链场景下防止签名重放。
/// 不应通过 delegatecall 使用：`DOMAIN_SEPARATOR` 会返回按本合约地址缓存的哈希，而不会按代理调用者地址重算。
/// 参考：https://github.com/Uniswap/permit2/blob/3f17e8db813189a03950dc7fc8382524a095c053/src/EIP712.sol
/// 参考：https://github.com/OpenZeppelin/openzeppelin-contracts/blob/7bd2b2aaf68c21277097166a9a51eb72ae239b34/contracts/utils/cryptography/EIP712.sol
contract EIP712_v4 is IEIP712_v4 {
    // 将域分隔符缓存为 immutable，同时记录对应 chainId；链分叉导致 chainId 改变时缓存自动失效。
    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;
    uint256 private immutable _CACHED_CHAIN_ID;
    bytes32 private immutable _HASHED_NAME;

    bytes32 private constant _TYPE_HASH =
        keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");

    constructor(string memory name) {
        _HASHED_NAME = keccak256(bytes(name));

        _CACHED_CHAIN_ID = block.chainid;
        _CACHED_DOMAIN_SEPARATOR = _buildDomainSeparator();
    }

    /// @notice 返回当前链对应的 EIP-712 域分隔符。
    /// @return 当前 name、chainId 和 verifyingContract 共同确定的域分隔符。
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        // chainId 未变化时使用缓存；变化时按当前链重新计算以维持重放保护。
        return block.chainid == _CACHED_CHAIN_ID ? _CACHED_DOMAIN_SEPARATOR : _buildDomainSeparator();
    }

    /// @notice 使用当前 chainId 和合约地址构建域分隔符。
    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(_TYPE_HASH, _HASHED_NAME, block.chainid, address(this)));
    }

    /// @notice 将结构体哈希包装为可供签名验证的 EIP-712 最终摘要。
    function _hashTypedData(bytes32 dataHash) internal view returns (bytes32 digest) {
        // 等价于 keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), dataHash))。
        bytes32 domainSeparator = DOMAIN_SEPARATOR();
        assembly ("memory-safe") {
            let fmp := mload(0x40)
            mstore(fmp, hex"1901")
            mstore(add(fmp, 0x02), domainSeparator)
            mstore(add(fmp, 0x22), dataHash)
            digest := keccak256(fmp, 0x42)

            // 清理临时写入的内存，避免污染后续依赖空闲内存内容的逻辑。
            mstore(fmp, 0) // fmp held "\x19\x01", domainSeparator
            mstore(add(fmp, 0x20), 0) // fmp+0x20 held domainSeparator, dataHash
            mstore(add(fmp, 0x40), 0) // fmp+0x40 held dataHash
        }
    }
}
