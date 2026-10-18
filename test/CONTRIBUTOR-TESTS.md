# Additional escrow tests

These tests extend the accepted flow, signature, token and state-model suites. The
application and its configuration are unchanged. No additional dependencies are
required.

## Edge cases

`PinballEscrowEdges.t.sol` checks:

- Zero, one wei, maximum uint256, both neighbours of every allowed stake, whole-token
  inputs, and the other token's tiers, with no balance or allowance consumption.
- Depositing an actor's entire balance with an exact allowance, then either winner,
  a draw, an unjoined refund or a joined refund. This property runs 1,000 cases.
- A join cannot use approval or funds belonging to the other token.
- Every failed outgoing payment leg for all eight token/stake combinations:
  winner, splitter, either draw refund, either joined refund and the unjoined refund.
  Failed second payments must roll back the first payment; the same exit must then
  succeed when transfers recover. There are 56 deterministic failure/retry cases.
- Malformed signature lengths cannot consume a joined match or prevent a subsequent
  correctly signed settlement.
- For any fuzzed invitee address, outsiders cannot join an invite-only match through
  `join` or `joinChecked` and lose no funds. A signed result naming an outsider is
  rejected. The invitee's win pays exactly 95% of the pot and the splitter 5%.

## Continuous invariant campaign

`PinballEscrowContinuousInvariant.t.sol` adds 256 sequences of 128 calls. Its handler
keeps six slots and assigns fresh match IDs when a finished slot is used again.
This complements the existing handler, whose finite ID set tests attempted reuse.

The targeted actions advance lifecycles, inject failed deposits, fail and retry
payments, advance time, pause/unpause and rotate the signer, donate tokens, and
challenge retired IDs with fresh signatures and repeated calls. Retired IDs are
also challenged with `openInvite` and `joinChecked`.

`progressInvite` opens invite-only matches (`openInvite`) and joins through
`joinChecked`. Failed deposits on an invite-only match come from the invitee.
`intrude` attacks every live open within its join window: player A joins through
either entry point, a non-invitee joins an invite-only match, and the eligible
joiner calls `joinChecked` with the wrong token, tier or opponent. Each attempt must
revert with its specific error and leave the match and all balances unchanged. Expected failures
assert specific errors. Unexpected handler reverts fail the campaign explicitly;
the existing invariant now also sets this option in its test source.

Independent ledgers track deposits, player payments, fees, donations and each
player's balance. After each scheduled action the suite checks:

1. Deposits equal outstanding obligations plus player payments plus fees.
2. Escrow token balances equal outstanding obligations plus voluntary donations.
3. Each player's balance and the splitter's fees equal their independent ledgers.
4. Token supply is conserved, and neither the owner nor the relayer receives funds.
5. Recorded participants, invitee, token, stake, timestamps and match state remain
   correct. Player B of an invite-only match is always the invitee.

After every sequence, time advances and all remaining matches are refunded; only
donations may remain. A deterministic handler test verifies that wins, draws,
refunds, fresh IDs, all deposit fault modes, payment retries and replay attempts
are reachable, including joins and exits while paused. A second deterministic
test reaches invite-only opens, checked joins, every intrusion, a failed invitee
deposit, paused invite-only opens and an unjoined invite refund.

## Reproduction

Run from the repository root. Artifacts are placed in the disposable scratch area.

```sh
FOUNDRY_OUT=test/scratch/out FOUNDRY_CACHE_PATH=test/scratch/cache forge build --offline
FOUNDRY_OUT=test/scratch/out FOUNDRY_CACHE_PATH=test/scratch/cache FOUNDRY_FUZZ_SEED=0x3e61902c7f82a5b3ab213507c40e5a257eeebda9117402b1a813cd99b4314e4a forge test --offline
```

No confirmed application defect was found by these checks. Tokens are local mocks
at the specified addresses; these tests do not validate live token deployments or
the NIGHTSHIFT replay server. Fault modes deliberately stress SafeERC20 and atomic
rollback beyond the plain-token assumptions in the brief.
