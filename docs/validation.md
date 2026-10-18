# Local validation record

Compiler: Solidity 0.8.26. Foundry: 1.8.3. Production settings: Cancun, optimizer enabled with 200 runs, no bytecode metadata hash or CBOR trailer.

All fuzzed runs use the requested seed:

```text
0x3e61902c7f82a5b3ab213507c40e5a257eeebda9117402b1a813cd99b4314e4a
```

## Accepted round

| Check | Result |
| --- | --- |
| `forge build` | Passed with the pinned compiler |
| Clean `forge build --offline` | Passed; vendored source imports are complete |
| `forge test` with the required seed | 56 passed, 0 failed, 0 skipped across 4 suites |
| `forge test --offline` in a cleared environment | Same 56 passed; only PATH and the fuzz seed were supplied |
| `forge fmt --check` | Passed |
| `forge coverage --report summary` with the required seed | All 56 passed; escrow line, statement, branch and function coverage each 100% |

## Revision round (findings a257ef2d, cc82eb10, 93ef1f4d)

This revision changed the constructor to `(address owner_, address initialSigner)` with an immutable owner, added `openInvite` and `joinChecked`, added the `invitee` field and `Invited` event, and added ten tests plus two invariant handler actions. The ABI now has exactly nine state-changing functions: `open`, `openInvite`, `join`, `joinChecked`, `settle`, `refund`, `setSigner`, `pause`, and `unpause`.

The worker machine for this revision could not execute any shell command: every invocation failed inside the sandbox wrapper before the command started (`apply-seccomp: write /proc/self/setgroups ... Permission denied`). `forge build`, `forge test` and `forge fmt --check` were therefore **not run locally for this revision**. The changes were reviewed by hand against the compiler rules (struct literal fields, stack depth in the invariant handler, cheatcode ordering, event signatures) and the accepted suite's conventions, and `forge fmt` is applied by the pipeline after submission. The verifier's own `forge build` and `forge test` run with the seed above is the authoritative result for this round; if either fails, the failure belongs to this revision, not to the accepted round.

Seven fuzz tests run 512 cases each. The stateful invariant runs 128 sequences of 64 scheduled calls over ten handler actions, including invite-only opens and checked joins with each mismatch kind. Expected application reverts are explicitly compared against the model inside each handler. The cleanup hook advances time, refunds every remaining active match, and checks that only voluntary donations remain in escrow.

The local deployment test uses CREATE2 with the actual creation code and both constructor arguments, validates the predicted address, removes token/owner code before construction, checks the owner and configuration, and proves the deploying factory cannot pause the contract. A fuzz test deploys through the factory probe with a pranked `tx.origin` and checks that `owner()` equals the constructor argument and that neither the factory nor the origin can administer the contract. The runtime scanner rejects DELEGATECALL, CALLCODE and SELFDESTRUCT while correctly skipping PUSH data.

The supplied manifest-driven protected tests are run by IdentityMD's later validation stage. The local suite rehearses their deployment, ownership, runtime-size and opcode properties without inventing deployment environment values. These local results carry no independent review authority.

Default Foundry lint emits reviewed notices for intentional timestamp comparisons, exact deposit balance checks and static signature verification before settlement events. Their rationale and the remaining external assumptions are documented in [security-review.md](security-review.md). Slither, Mythril, production replay-service testing and a live broadcast were not performed.
