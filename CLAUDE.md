# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Submodule: YieldClaimNft

This is a Foundry smart contract submodule for the YieldClaimNft contract.

## Dependencies

All dependencies live at the root of `lib/` as ordinary git submodules with their full
source available — there is no interface-only stripping and no change request process.

Current dependencies:

- `lib/forge-std` - Foundry standard library
- `lib/openzeppelin-contracts` - OpenZeppelin contracts
- `lib/pauser` - Behodler pauser (`Behodler/pauser`)
- `lib/phoenix-nft-staking` - Phoenix NFT staking (`Behodler/phoenix-nft-staking`)

Remappings are declared in `foundry.toml`:

```
@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/
pauser/=lib/pauser/src/
phoenix-nft-staking/=lib/phoenix-nft-staking/src/
```

Add a new dependency with `forge install <org>/<repo>` (or `git submodule add`) into `lib/`,
then add a remapping in `foundry.toml`.

Sibling repos are pinned to a specific commit like any other submodule. If a sibling needs a
change, make it in that repo, then bump the pinned commit here with
`git submodule update --remote lib/<name>` and commit the new pointer.

## Project Structure

- `src/` - Solidity source files
- `test/` - Test files (TDD required)
- `script/` - Deployment scripts
- `lib/` - Dependencies (git submodules)

## Development Guidelines

### Test-Driven Development (TDD)

**ALL** features, bug fixes, and modifications MUST follow TDD principles:

1. **Write tests first** - Before implementing any feature
2. **Red phase** - Write failing tests that define the expected behavior
3. **Green phase** - Write minimal code to make tests pass
4. **Refactor phase** - Improve code while keeping tests green

### Testing Commands

- `forge test` - Run all tests
- `forge test -vvv` - Run tests with verbose output
- `forge test --match-contract <ContractName>` - Run specific contract tests
- `forge test --match-test <testName>` - Run specific test
- `forge coverage` - Check test coverage

### Other Commands

- `forge build` - Compile contracts
- `forge fmt` - Format Solidity code
- `forge snapshot` - Generate gas snapshots

## Important Reminders

- Follow Solidity best practices and naming conventions
- Use Foundry testing tools exclusively (no Hardhat or Truffle)
