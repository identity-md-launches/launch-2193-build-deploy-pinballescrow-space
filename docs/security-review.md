# Security review and release handoff

This is the implementation author's local review, not an independent audit. IdentityMD's independent contributor review and deployment checks remain the release gate. No production transaction was sent.

## Custody and authority

Only `open`, `join`, `settle`, and `refund` interact with tokens. Each is non-reentrant, changes the match state before token interactions, and uses SafeERC20. Incoming balance deltas must equal the exact requested stake. No approval is ever granted by the escrow. Signature contract calls are static, and the settlement entry point is guarded throughout validation and payment.

The owner is an immutable taken from the `owner_` constructor argument, which the launch fills with `$owner`. It is never `msg.sender` (the factory) or `tx.origin` (the launch wallet); a fuzz test deploys through a factory contract with a pranked origin and checks that `owner()` equals the argument and that neither the factory nor the origin can administer the contract. The owner can only change the signer and pause/unpause new opens. The ABI exposes no ownership transfer, withdrawal, token rescue, adjustable economics, arbitrary execution or upgrade operation. Runtime bytecode is tested against EIP-170 and scanned, skipping PUSH immediates, for forbidden DELEGATECALL, CALLCODE and SELFDESTRUCT opcodes, matching the supplied deployment floor's approach. Construction is tested without token or owner code.

A valid result can pay only a recorded participant, or refund both for a draw. Signing is a trusted authority: a dishonest or compromised signer can pick the wrong participant or falsely declare a draw. The owner can select that signer. No cryptographic mechanism in this escrow proves gameplay fairness. The server's replay, anti-cheat and signing controls need their own review.

## State, time and signatures

Unopened IDs have no funds or refund rights. Open IDs admit one different second player. Settled and refunded IDs are permanent tombstones, so they cannot be reopened or reused with a previous signature. The same ID is permitted on another deployment, but EIP-712 binds signatures to the chain and contract. The domain updates if the chain ID changes.

Join is valid strictly before `openedAt + 3600`; settlement is valid strictly before `joinedAt + 86400`; refunds start at those exact boundaries. Signature deadlines are inclusive, and cannot extend the match lifetime. Block timestamps are intentionally used for these hours-long windows, not for randomness. Near-boundary transactions may miss their window because of inclusion delays or timestamp choice.

The backend must observe and validate actual joined matches before signing. Match IDs are first-come, so a public `open` or `join` can be front-run: a squatter can reserve an arranged ID with another token or tier, or a stranger can take player B's slot. The independent review (finding cc82eb10) reproduced both; neither moves funds, but either locked the affected stake until its timeout. Two guarded entry points now close them on chain while leaving the requested `open(bytes32,address,uint256)` and `join(bytes32)` unchanged. `joinChecked(matchId, token, stake, playerA)` reverts with `MatchMismatch` unless the ID holds exactly the agreed terms, so a squatted ID cannot bind B to a different tier or opponent. `openInvite(matchId, token, stake, invitee)` records the arranged opponent and `join`/`joinChecked` by anyone else revert with `NotInvited`, so A's stake can only be paired with the intended player. Tests cover the reviewer's squat and slot-snipe scenarios, each mismatch field, zero/self invitees, invite-only refunds and pausing, and a fuzzed `joinChecked` over all parameters; the invariant handler models the invitee and both entry points. What remains is griefing a predictable ID: a squatter pays gas and locks one minimum stake for an hour to force the server to reassign the ID, and A's reverted open deposits nothing.

Signer rotation does not erase signatures. Reinstating a key revives its still-valid authorizations for still-joined matches because the specified signed type has no signer epoch (finding 93ef1f4d, reproduced and documented as an owner trust assumption: never reinstate a key that may have signed a disputed result). A valid ECDSA signature takes precedence over contract validation at that same address, allowing a delegated EOA to sign directly. Contract signers without a matching ECDSA key use ERC-1271 and may revoke results through their policy.

## Transfers, arithmetic and failure isolation

Only fixed 18-decimal stake tiers enter accounting, bounding every pot and multiplication. Each allowed pot yields an integer 5% fee. Donations are excluded from pots and refund amounts. Every token movement and state transition is atomic: a failed second payment also reverses the first payment and leaves the match available for retry or eventual timeout refund.

Refunds are per match, with no shared queue or loop over users. A transfer problem in one match does not block independent matches. Within a joined match, both refunds are deliberately atomic. A token that blocks one participant can therefore prevent that match's payout/refund until its policy allows transfer. Outgoing exact delivery relies on the brief's no-tax, non-rebasing token assumption; the escrow cannot override a token pause, blocklist, upgrade or issuer policy. The live token contracts are external dependencies and were not audited here.

There is no rescue function. Accidental direct ERC-20 transfers and forced ETH are not assigned to matches and cannot be reclaimed by the owner. Ordinary ETH sends and unknown selectors revert. Players should fund through the escrow entry points.

## Local validation

The suite contains deterministic success/failure tests, fuzzed stakes/addresses/results and an independent state/accounting model. Coverage includes:

- Every fixed stake for both tokens, either winner, and full draw refunds; fee exactly 5% to the splitter and no owner/relayer payment.
- Unjoined and joined timeout refunds, just-before/exact boundaries, settlement cutoff, and permissionless triggering.
- Wrong tokens/stakes, insufficient allowance/balance, duplicate IDs, missing matches, self-join, third players, and reuse of terminal IDs.
- ID squatting and slot sniping: a checked join against a squatted ID, every `joinChecked` mismatch, invite-only opens rejecting uninvited joiners, invalid invitees, and owner assignment from the constructor argument under a factory deployer and foreign origin.
- Wrong/expired/malformed/malleable signatures, tampering with every signed field, wrong domain name/version, personal-sign signatures, replay across IDs/contracts/chains, and double/conflicting settlements.
- Signer rotation, delegated EOA signatures, ERC-1271 success/revocation/reversion, owner-only administration, and all existing-match operations while paused.
- Fee-on-transfer and overpayment rejection, false-return/reverting/no-return token behavior, atomic failed winner/fee/draw/refund transfers, and retryability.
- Reentrancy from token transferFrom and transfer into open/join/settle/refund, including attempts to affect a separate funded match; callback observations confirm state effects precede token interaction.
- Randomized sequences of opens, joins, settlements, refunds, time changes, pauses, signer rotations and direct donations. Every success or failure is compared to an independent model; all participant balances, exact fees, per-token outstanding obligations and global conservation are checked after calls. A final time advance demonstrates that every remaining stake is refundable even after arbitrary pause/signer changes.

The recorded final commands and results are in [validation.md](validation.md). Foundry coverage reports 100% of the application's lines, statements, branches and functions exercised. Coverage does not establish correctness of external token implementations, server fairness, signer operations or all possible EVM states.

The compiler's default lint notices about timestamps, strict balance equality, the constructor signer check, and event placement were reviewed. Timestamp comparisons implement the requested timeouts; strict delta equality enforces exact deposits; equality with the fixed nonzero owner rejects a zero initial signer; and the external call before Settled events is static signature verification inside a guarded operation. Slither and Mythril were not run.
