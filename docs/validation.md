# Local validation record

Compiler: Solidity 0.8.26. Foundry: 1.8.3. Production settings: Cancun, optimizer enabled with 200 runs, no bytecode metadata hash or CBOR trailer.

All fuzzed runs below used the requested seed:

```text
0x3e61902c7f82a5b3ab213507c40e5a257eeebda9117402b1a813cd99b4314e4a
```

| Check | Result |
| --- | --- |
| `forge build` | Passed with the pinned compiler |
| Clean `forge build --offline` | Passed; vendored source imports are complete |
| `forge test` with the required seed | 56 passed, 0 failed, 0 skipped across 4 suites |
| `forge test --offline` in a cleared environment | Same 56 passed; only PATH and the fuzz seed were supplied |
| `forge fmt --check` | Passed |
| `forge coverage --report summary` with the required seed | All 56 passed; escrow line, statement, branch and function coverage each 100% |

Six fuzz tests run 512 cases each. The stateful invariant runs 128 sequences of 64 scheduled calls: 8,192 calls, with zero handler reverts or discarded calls. Expected application reverts are explicitly compared against the model inside each handler. The cleanup hook advances time, refunds every remaining active match, and checks that only voluntary donations remain in escrow.

Application coverage: 79/79 lines, 113/113 statements, 22/22 branches, 13/13 functions. Coverage is measured using Foundry's instrumentation settings; the final build and test commands also passed with the production optimizer configuration.

The built `PinballEscrow` runtime is **6,810 bytes**, below the 24,576-byte EIP-170 limit. Creation bytecode is **7,917 bytes** before the single 32-byte constructor argument. Both bytecodes have empty library link-reference maps. The ABI has exactly seven state-changing functions: `open`, `join`, `settle`, `refund`, `setSigner`, `pause`, and `unpause`.

The local deployment test uses CREATE2 with the actual creation code and required signer argument, validates the predicted address, removes token/owner code before construction, checks the fixed owner and configuration, and proves the deploying factory cannot pause the contract. The runtime scanner rejects DELEGATECALL, CALLCODE and SELFDESTRUCT while correctly skipping PUSH data.

The supplied manifest-driven protected tests are run by IdentityMD's later validation stage. The local suite rehearses their deployment, ownership, runtime-size and opcode properties without inventing deployment environment values. These local results carry no independent review authority.

Default Foundry lint emits reviewed notices for intentional timestamp comparisons, exact deposit balance checks, fixed-owner constructor validation and static signature verification before settlement events. Their rationale and the remaining external assumptions are documented in [security-review.md](security-review.md). Slither, Mythril, production replay-service testing and a live broadcast were not performed.
