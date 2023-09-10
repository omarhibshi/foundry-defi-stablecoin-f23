## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

-   **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
-   **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
-   **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
-   **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
RoadMap to Creating our Stable Coin

1. Relative Stability: Anchored or Pegged -> $1.00
    a. To make sure this is pegged to a dollar, we use:
        1. Chainlink Price feed.
        2. Set a function to exchange ETH & BTC -> $
2. Stability Mechanism (Minting): Algorithmic (Decentralized) 
    a. To make the stability mechanism algorithmic, we stipulate that:
        1. People can only mint stabelcoin with enough colletral (coded directrly into the protocol)
3. Collatral Exogenous (Crypto)
    a. We will only allow the following coins to be deposited and therefore used as collateral:
    1. wETH
    2. wBTC