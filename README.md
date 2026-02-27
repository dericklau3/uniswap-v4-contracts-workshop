# Foundry-Starter

## Usage

```shell

# Reinitialize git
$ rm -rf .git
$ rm -rf lib
$ git init
$ forge install foundry-rs/forge-std
$ forge install transmissions11/solmate
$ forge install OpenZeppelin/openzeppelin-contracts@v5.5.0


# Install Foundryup
$ curl -L https://foundry.paradigm.xyz | bash

# Upgrade Foundryup
$ foundryup

# Install dependencies
$ forge install

# Compile contracts
$ forge build
$ forge build src
$ forge clean

# Dependencies manage
$ forge install OpenZeppelin/openzeppelin-contracts@v5.0.2
$ forge install OpenZeppelin/openzeppelin-contracts-upgradeable
$ forge install transmissions11/solmate
$ forge remove OpenZeppelin/openzeppelin-contracts
$ forge update OpenZeppelin/openzeppelin-contracts

# List Wallet's contract selectors
$ forge inspect Wallet methodidentifiers 

# List contract selectors & events
$ forge selectors list
$ forge selectors list Wallet

# Remapping dependencies
$ forge remappings > remappings.txt

# Check the contract size [Runtime Size (B) | Initcode Size (B) | Runtime Margin (B) | Initcode Margin (B)]
$ forge build --sizes

# Generate documentation for the project
$ forge doc

# Run unit test
$ forge test
$ forge test -vvv --match-path test/xxx.t.sol
$ forge test --match-path test/xxx.t.sol --match-test testFunc

# Compare gas cost
# first
forge snapshot --match-path test/MyContract.t.sol
# last
forge snapshot --match-path test/MyContract.t.sol --diff

# Deploy
$ source .env
$ forge script script/Counter.s.sol:CounterScript --rpc-url mainnet  --broadcast
$ forge script script/Counter.s.sol:CounterScript --rpc-url mainnet  --broadcast --verify -vvvv
```



### Deployment considerations

**Watch out for frontrunning**. Forge simulates your script, generates transaction data from the simulation results, then broadcasts the transactions. Make sure your script is robust against chain-state changing between the simulation and broadcast. A sample script vulnerable to this is below:

```solidity
// Pseudo-code, may not compile.
contract VulnerableScript is Script {
   function run() public {
      vm.startBroadcast();
 
      // Transaction 1: Deploy a new Gnosis Safe with CREATE.
      // Because we're using CREATE instead of CREATE2, the address of the new
      // Safe is a function of the nonce of the gnosisSafeProxyFactory.
      address mySafe = gnosisSafeProxyFactory.createProxy(singleton, data);
 
      // Transaction 2: Send tokens to the new Safe.
      // We know the address of mySafe is a function of the nonce of the
      // gnosisSafeProxyFactory. If someone else deploys a Gnosis Safe between
      // the simulation and broadcast, the address of mySafe will be different,
      // and this script will send 1000 DAI to the other person's Safe. In this
      // case, we can protect ourselves from this by using CREATE2 instead of
      // CREATE, but every situation may have different solutions.
      dai.transfer(mySafe, 1000e18);
 
      vm.stopBroadcast();
   }
}
```

