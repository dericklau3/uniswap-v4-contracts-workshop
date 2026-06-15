// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {VanityAddressLib} from "./libraries/VanityAddressLib.sol";
import {IUniswapV4DeployerCompetition} from "./interfaces/IUniswapV4DeployerCompetition.sol";

/// @title Uniswap V4 部署地址竞赛
/// @notice 众包搜索 CREATE2 salt，以获得评分最高的 Uniswap V4 合约靓号地址，并按时限完成确定性部署。
contract UniswapV4DeployerCompetition is IUniswapV4DeployerCompetition {
    using VanityAddressLib for address;

    /// @dev 当前最高分地址对应的 salt。
    bytes32 public bestAddressSalt;
    /// @dev 当前最高分 salt 的提交者。
    address public bestAddressSubmitter;

    /// @dev 接收更优 salt 的竞赛截止时间。
    uint256 public immutable competitionDeadline;
    /// @dev 目标 V4 合约部署字节码的 init code hash。
    bytes32 public immutable initCodeHash;

    /// @dev 在独占部署截止时间前，只有指定 deployer 可部署 V4 PoolManager；之后任何人都可代为部署。
    address public immutable deployer;
    /// @dev 竞赛结束后指定 deployer 的独占部署截止时间。
    uint256 public immutable exclusiveDeployDeadline;

    constructor(
        bytes32 _initCodeHash,
        uint256 _competitionDeadline,
        address _exclusiveDeployer,
        uint256 _exclusiveDeployLength
    ) {
        initCodeHash = _initCodeHash;
        competitionDeadline = _competitionDeadline;
        exclusiveDeployDeadline = _competitionDeadline + _exclusiveDeployLength;
        deployer = _exclusiveDeployer;
    }

    /// @notice 若给定 salt 计算出的 CREATE2 地址评分更高，则更新当前最佳记录。
    /// @param salt 用于计算目标地址的 CREATE2 salt。
    /// @dev salt 前 20 字节必须为零地址或提交者地址，防止他人抢报与自己无关的搜索成果。
    function updateBestAddress(bytes32 salt) external {
        if (block.timestamp > competitionDeadline) {
            revert CompetitionOver(block.timestamp, competitionDeadline);
        }

        address saltSubAddress = address(bytes20(salt));
        if (saltSubAddress != msg.sender && saltSubAddress != address(0)) revert InvalidSender(salt, msg.sender);

        address newAddress = Create2.computeAddress(salt, initCodeHash);
        address _bestAddress = bestAddress();
        if (!newAddress.betterThan(_bestAddress)) {
            revert WorseAddress(newAddress, _bestAddress, newAddress.score(), _bestAddress.score());
        }

        bestAddressSalt = salt;
        bestAddressSubmitter = msg.sender;

        emit NewAddressFound(newAddress, msg.sender, newAddress.score());
    }

    /// @notice 使用最佳 salt 部署目标 Uniswap V4 PoolManager 字节码。
    /// @param bytecode 必须与构造时 `initCodeHash` 完全匹配的部署字节码。
    /// @dev 竞赛结束后进入指定部署者独占期；独占期结束仍未部署时，任何人都可完成部署。
    function deploy(bytes memory bytecode) external {
        if (keccak256(bytecode) != initCodeHash) {
            revert InvalidBytecode();
        }

        if (block.timestamp <= competitionDeadline) {
            revert CompetitionNotOver(block.timestamp, competitionDeadline);
        }

        if (msg.sender != deployer && block.timestamp <= exclusiveDeployDeadline) {
            // 独占期结束后开放给任何地址部署，避免指定部署者失联导致永久阻塞。
            revert NotAllowedToDeploy(msg.sender, deployer);
        }

        // 合约 owner 等构造参数必须已编码在 bytecode 中，本函数不会另行拼接参数。
        Create2.deploy(0, bestAddressSalt, bytecode);
    }

    /// @dev 返回当前最佳 salt 与固定 initCodeHash 对应的 CREATE2 目标地址。
    function bestAddress() public view returns (address) {
        return Create2.computeAddress(bestAddressSalt, initCodeHash);
    }
}
