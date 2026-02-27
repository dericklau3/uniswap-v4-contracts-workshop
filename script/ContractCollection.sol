// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.13;

// import {BaseDeployScript} from "./BaseDeployScript.sol";

// import {Wallet} from "../src/Wallet.sol";

// import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// contract ContractCollection is BaseDeployScript {

//     function deployWallet(address usdc, address signer, address tokenRecipient) public returns (Wallet wallet) {
//         Wallet walletImpl = new Wallet();
//         saveContract("walletImpl", address(walletImpl));

//         bytes memory data = abi.encodeWithSignature("initialize(address,address)", tokenRecipient, signer);
//         ERC1967Proxy walletProxy = new ERC1967Proxy(
//             address(walletImpl),
//             data
//         );
//         wallet = Wallet(address(walletProxy));
//         // Save proxy contract
//         saveContract("wallet", address(walletProxy));
        
//         address[] memory tokenAddrs = new address[](1);
//         tokenAddrs[0] = usdc;
//         wallet.updateTokenAllowed(tokenAddrs, true);
//     }

//     function upgradeWallet() public {
//         Wallet walletImpl = new Wallet();
//         saveContract("walletImpl", address(walletImpl));

//         address walletAddr = getContractAddress("wallet");
//         Wallet(walletAddr).upgradeToAndCall(address(walletAddr), new bytes(0));
//     }
// }
