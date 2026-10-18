# Security review and release handoff

This is the implementation author's local review, not an independent audit. IdentityMD's independent contributor review and deployment checks remain the release gate. No production transaction was sent.

## Custody and authority

Only `open`, `join`, `settle`, and `refund` interact with tokens. Each is non-reentrant, changes the match state before token interactions, and uses SafeERC20. Incoming balance deltas must equal the exact requested stake. No approval is ever granted by the escrow. Signature contract calls are static, and the settlement entry point is guarded throughout validation and payment.

The fixed owner can only change the signer and pause/unpause new opens. The ABI exposes no ownership transfer, withdrawal, token rescue, adjustable economics, arbitrary execution or upgrade operation. Runtime bytecode is tested against EIP-170 and scanned, skipping PUSH immediates, for forbidden DELEGATECALL, CALLCODE and SELFDESTRUCT opcodes, matching the supplied deployment floor's approach. Construction is tested without token or owner code and never derives ownership from its caller.

A valid result can pay only a recorded participant, or refund both for a draw. Signing is a trusted authority: a dishonest or compromised signer can pick the wrong participant or falsely declare a draw. The owner can select that signer. No cryptographic mechanism in this escrow proves gameplay fairness. The server's replay, anti-cheat and signing controls need their own review.

## State, time and signatures

Unopened IDs have no funds or refund rights. Open IDs admit one different second player. Settled and refunded IDs are permanent tombstones, so they cannot be reopened or reused with a previous signature. The same ID is permitted on another deployment, but EIP-712 binds signatures to the chain and contract. The domain updates if the chain ID changes.

Join is valid strictly before `openedAt + 3600`; settlement is valid strictly before `joinedAt + 86400`; refunds start at those exact boundaries. Signature deadlines are inclusive, and cannot extend the match lifetime. Block timestamps are intentionally used for these hours-long windows, not for randomness. Near-boundary transactions may miss their window because of inclusion delays or timestamp choice.

The backend must observe and validate actual joined matches before signing. Public open/join calls allow competing transactions to reserve an ID or take the second slot. This can disrupt an off-chain invitation or matchmaking assumption; it cannot change an already funded match's token, amount or participants. Clients and the server must detect mismatches. Adding an invite-only second player or signing token/stake fields would change the requested interface and was not done.

Signer rotation does not erase signatures. Reinstating a key can revive still-valid authorizations because the specified signed type has no signer epoch. A valid ECDSA signature takes precedence over contract validation at that same address, allowing a delegated EOA to sign directly. Contract signers without a matching ECDSA key use ERC-1271 and may revoke results through their policy.

## Transfers, arithmetic and failure isolation

Only fixed 18-decimal stake tiers enter accounting, bounding every pot and multiplication. Each allowed pot yields an integer 5% fee. Donations are excluded from pots and refund amounts. Every token movement and state transition is atomic: a failed second payment also reverses the first payment and leaves the match available for retry or eventual timeout refund.

Refunds are per match, with no shared queue or loop over users. A transfer problem in one match does not block independent matches. Within a joined match, both refunds are deliberately atomic. A token that blocks one participant can therefore prevent that match's payout/refund until its policy allows transfer. Outgoing exact delivery relies on the brief's no-tax, non-rebasing token assumption; the escrow cannot override a token pause, blocklist, upgrade or issuer policy. The live token contracts are external dependencies and were not audited here.

There is no rescue function. Accidental direct ERC-20 transfers and forced ETH are not assigned to matches and cannot be reclaimed by the owner. Ordinary ETH sends and unknown selectors revert. Players should fund through the escrow entry points.

## Local validation

The suite contains deterministic success/failure tests, fuzzed stakes/addresses/results and an independent state/accounting model. Coverage includes:

- Every fixed stake for both tokens, either winner, and full draw refunds; fee exactly 5% to the splitter and no owner/relayer payment.
- Unjoined and joined timeout refunds, just-before/exact boundaries, settlement cutoff, and permissionless triggering.
- Wrong tokens/stakes, insufficient allowance/balance, duplicate IDs, missing matches, self-join, third players, and reuse of terminal IDs.
- Wrong/expired/malformed/malleable signatures, tampering with every signed field, wrong domain name/version, personal-sign signatures, replay across IDs/contracts/chains, and double/conflicting settlements.
- Signer rotation, delegated EOA signatures, ERC-1271 success/revocation/reversion, owner-only administration, and all existing-match operations while paused.
- Fee-on-transfer and overpayment rejection, false-return/reverting/no-return token behavior, atomic failed winner/fee/draw/refund transfers, and retryability.
- Reentrancy from token transferFrom and transfer into open/join/settle/refund, including attempts to affect a separate funded match; callback observations confirm state effects precede token interaction.
- Randomized sequences of opens, joins, settlements, refunds, time changes, pauses, signer rotations and direct donations. Every success or failure is compared to an independent model; all participant balances, exact fees, per-token outstanding obligations and global conservation are checked after calls. A final time advance demonstrates that every remaining stake is refundable even after arbitrary pause/signer changes.

The recorded final commands and results are in [validation.md](validation.md). Foundry coverage reports 100% of the application's lines, statements, branches and functions exercised. Coverage does not establish correctness of external token implementations, server fairness, signer operations or all possible EVM states.

The compiler's default lint notices about timestamps, strict balance equality, the constructor signer check, and event placement were reviewed. Timestamp comparisons implement the requested timeouts; strict delta equality enforces exact deposits; equality with the fixed nonzero owner rejects a zero initial signer; and the external call before Settled events is static signature verification inside a guarded operation. Slither and Mythril were not run.
