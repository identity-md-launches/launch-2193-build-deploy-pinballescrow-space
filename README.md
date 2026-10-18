# Space Pinball escrow

`PinballEscrow` holds equal ERC-20 stakes from two players and pays the result authorized by NIGHTSHIFT's deterministic replay server. A win pays 95% of the combined stakes to the winner and 5% to the fixed fee splitter. A draw or timeout returns the original stakes without fees.

The deliverable is one immutable application contract, a self-contained Foundry test suite, and vendored dependencies. IdentityMD's deployment service performs the production launch after acceptance and independent review. This repository does not broadcast transactions or contain a launch manifest, deployment wallet, or claimed live escrow address.

## Build and test

Run from the repository root with Foundry and Solidity **0.8.26** available:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x3e61902c7f82a5b3ab213507c40e5a257eeebda9117402b1a813cd99b4314e4a forge test
forge fmt --check
```

The compiler, Cancun EVM target, optimizer settings, and metadata settings are pinned in `foundry.toml`. `bytecode_hash = "none"` and `cbor_metadata = false` keep metadata out of deployed bytecode. No FFI, filesystem permissions, RPC connections, environment-reading cheatcodes, package installation, or submodules are required by the tests. The verifier supplies the pinned compiler; all imported Solidity sources are ordinary files under `lib/`.

OpenZeppelin Contracts **v5.1.0** supplies SafeERC20, EIP712, ECDSA, ERC-1271 checking, Pausable, and ReentrancyGuard. Forge Standard Library **v1.9.7** supplies test tooling. Archive URLs, checksums, and retained file counts are in [docs/dependencies.json](docs/dependencies.json); each dependency retains its license and unmodified source files.

## Deployment parameters

| Parameter | Required value |
| --- | --- |
| Network | Ethereum, chain ID `1` |
| Application | `src/PinballEscrow.sol:PinballEscrow` |
| Constructor | `constructor(address owner_, address initialSigner)`; nonpayable |
| `owner_` | `$owner` = `0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5` |
| `initialSigner` | `$owner` = `0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5` |
| Fee splitter | `0x1119d5Df2f046bC2d3c0F6279EF2E9cE49422d44` |
| Fee | `500 / 10_000` of the combined pot, exactly 5% |
| Native value at deployment | `0` |
| Initialization calls | None |

The owner is an immutable set from the `owner_` constructor argument, which the launch manifest fills with `$owner`. It is never derived from `msg.sender` (the launch factory) or `tx.origin` (the launch wallet); `owner()` returns whatever address the manifest supplied, and only that address can call `setSigner`, `pause` and `unpause`. The initial signer is a separate argument that the manifest also fills with `$owner`, as the brief requires. Both arguments must be non-zero. Construction performs no external calls and does not require token or signer code to exist. There are no linked external libraries, proxies, upgrade functions, ownership transfers, delegatecalls, selfdestruct, or administrative withdrawal functions. Only `PinballEscrow` is an application to deploy; contracts under `test/` are fixtures.

The manifest step supplies these two constructor arguments after acceptance. Use the deployment service's confirmed escrow address as the client `verifyingContract` and token approval spender. Do not infer an escrow address from local test deployments.

## Fixed assets and stakes

| Token | Ethereum address | Allowed stakes, in whole tokens |
| --- | --- | --- |
| IMD | `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` | 1, 5, 10, 25 |
| SHIFT | `0xE5e58E53d0Bb204Aa62c995A6c8CC8a48e60C3AC` | 100000, 500000, 1000000, 5000000 |

Both use 18 decimals. Pass `wholeTokens * 10**18` as `stake`; passing the unscaled whole-token number reverts. `isAllowedStake(token, stake)` exposes the exact whitelist. The addresses and tiers cannot change.

The assignment specifies ordinary tokens with no transfer tax or rebasing. Incoming deposits additionally require the escrow's balance to increase by exactly `stake`. SafeERC20 checks every transfer; any failure reverts the entire operation. All allowed pots are divisible by 20 in base units, so the 5% fee has no rounding remainder. For example, two 5 IMD stakes produce 9.5 IMD for the winner and 0.5 IMD for the splitter.

## Match lifecycle

Players approve the deployed escrow to spend the exact stake before their deposit call. Approval and gas are paid separately from the stake.

| Call | Conditions | Effect |
| --- | --- | --- |
| `open(matchId, token, stake)` | Unused ID, allowed token/tier, opens unpaused | Caller becomes A and deposits one stake; anyone else may join |
| `openInvite(matchId, token, stake, invitee)` | As `open`, plus a non-zero invitee other than the caller | Caller becomes A and deposits one stake; only `invitee` may join |
| `join(matchId)` | Open match, caller differs from A, caller is the invitee if one is set, `now < openedAt + 1 hour` | Caller becomes B and deposits whatever token and stake the ID holds |
| `joinChecked(matchId, token, stake, playerA)` | As `join`, plus the match must hold exactly this token, stake and player A | Caller becomes B and deposits the asserted stake |
| `settle(matchId, winner, draw, deadline, signature)` | Joined match, current signer's valid signature, `now <= deadline`, `now < joinedAt + 24 hours` | Winner gets 95% and splitter gets 5%, or both stakes are refunded for a draw |
| `refund(matchId)` | Unjoined open at `now >= openedAt + 1 hour`, or joined match at `now >= joinedAt + 24 hours` | Refunds original depositor(s) in full |

`settle` and `refund` are permissionless; the caller cannot redirect a payment. Players can also be smart contracts. The match has exactly two distinct participants. All `bytes32` IDs, including zero, are accepted once. A successful open permanently reserves the ID, even after refund or settlement. Failed deposits do not reserve an ID or join slot.

### Front-running protection for arranged matches

Match IDs are first-come, and the plain `join(matchId)` deposits whatever the ID currently holds. Because every `open` and `join` sits in the public mempool, a third party could otherwise front-run an arranged pairing: squat the agreed ID with a different token or tier before A opens it, or take B's slot on A's real match. Neither can move anyone's funds, but either locks the affected stake until its timeout refund. The two guarded entry points close both races at the contract level:

- **`joinChecked(matchId, token, stake, playerA)`** reverts with `MatchMismatch` unless the ID holds exactly the agreed token, stake and opener. A squatted ID can therefore never bind B to a tier or opponent B did not agree to; B's transaction fails and B keeps the stake. Clients should always use `joinChecked` with the terms the server handed out, and approve only the exact stake per call.
- **`openInvite(matchId, token, stake, invitee)`** records the arranged opponent. Any other address that tries to join reverts with `NotInvited`, so A's stake can only ever be paired with the invited player. The invitee may use `join` or `joinChecked`. Public matchmaking still uses `open`, which anyone may join.

A squatted ID still cannot be reused: A's `open` reverts with `MatchAlreadyExists` and nothing is deposited, so the server must assign a fresh ID when an open fails. The squatter's own minimum stake is locked for the one-hour join window. The server must still read the on-chain match (token, stake, both recorded players) before signing a result, because the contract does not verify gameplay.

The 24-hour clock starts at **join**, not open. Joining closes exactly at the one-hour boundary, and settlement closes exactly at the 24-hour boundary, leaving refund as the available resolution. These choices prevent a late join or late settlement from racing an already available timeout refund. Expiry of a result signature alone does not accelerate the refund clock. Contracts do not execute automatically at a deadline; someone must submit the transaction.

`matches(matchId)` returns `(token, stake, playerA, playerB, invitee, openedAt, joinedAt, state)` as a struct. State values are `0=None`, `1=Open`, `2=Joined`, `3=Settled`, `4=Refunded`. The absent player B and join time are zero while unjoined; `invitee` is zero for a public match. Terminal records remain available and cannot transition again.

### Events

| Event | Meaning |
| --- | --- |
| `Opened(matchId, token, stake, playerA)` | Exact first deposit succeeded (emitted by `open` and `openInvite`) |
| `Invited(matchId, invitee)` | The open recorded an invite-only opponent (emitted by `openInvite` after `Opened`) |
| `Joined(matchId, playerB)` | Exact second deposit succeeded (emitted by `join` and `joinChecked`) |
| `Settled(matchId, winner, draw, payout, fee)` | Final authorized result; `payout` is the total sent to players |
| `Refunded(matchId)` | Timeout refunded the recorded participants |
| `SignerUpdated(previousSigner, newSigner)` | Initial signer assignment or owner rotation |
| `Paused(account)` / `Unpaused(account)` | Owner changed availability of new opens |

For a draw, `winner` is the zero address (the explicit no-winner sentinel), `payout = 2 * stake`, and `fee = 0`; each player receives `stake`. For a win, `winner` must equal A or B and `payout` is that winner's receipt. Events and state changes roll back if any token transfer fails. Indexed fields are `matchId`, `token`, and `playerA` on Opened; `matchId` and `invitee` on Invited; `matchId` and `playerB` on Joined; `matchId` and `winner` on Settled; `matchId` on Refunded; and both signer addresses on SignerUpdated.

## Signing integration

The precise EIP-712 type string is:

```text
Result(bytes32 matchId,address winner,bool draw,uint256 deadline)
```

The domain uses name `SpacePinball`, version `1`, the current chain ID, and the deployed escrow address. On the launch chain the ID is `1`. `hashResult(...)` returns the final `0x1901`-prefixed EIP-712 digest, and inherited `eip712Domain()` exposes the domain fields.

For an EOA backend using an EIP-712-capable signing library, construct this data from a confirmed on-chain match and the server's verified replay result:

```js
const domain = {
  name: "SpacePinball",
  version: "1",
  chainId: 1,
  verifyingContract: deployedEscrowAddress,
};
const types = {
  Result: [
    { name: "matchId", type: "bytes32" },
    { name: "winner", type: "address" },
    { name: "draw", type: "bool" },
    { name: "deadline", type: "uint256" },
  ],
};
const result = {
  matchId,
  winner: draw ? "0x0000000000000000000000000000000000000000" : winningPlayer,
  draw,
  deadline: deadlineUnixSeconds,
};
const signature = await backendSigner.signTypedData(domain, types, result);
```

`deployedEscrowAddress`, `matchId`, `winningPlayer`, `draw`, and `deadlineUnixSeconds` above are application inputs, not deployment defaults. Use integer base units and Unix seconds; avoid JavaScript floating-point numbers for token amounts. Submit the same fields and signature to `settle`. Do not wrap the digest in a personal-sign prefix. ECDSA signatures must be 65-byte `r || s || v`, with low `s` and `v` equal to 27 or 28; compact 64-byte signatures are not supported. ECDSA is checked first even when the signer's address has delegated code. Otherwise ERC-1271 validates the digest through a static call to the configured signer.

The signed structure intentionally has exactly the requested fields. Match IDs act as single-use nonces. The server must never pre-sign unopened/unjoined matches: it must bind its game records to the actual escrow address, chain, permanent match ID, token, stake and two recorded players before signing. The contract does not verify gameplay, scores or deterministic replays.

## After launch

The deployment operator records the actual contract address, verifies its source and constructor argument, and checks the fixed getters against this document. Mainnet read-only checks during implementation reported code at both supplied token addresses and `decimals() == 18` for both (chain 1, observed head block 26,222,054). This observation does not establish token transfer policy; the launch review should confirm the stated ordinary-token assumptions on current chain state.

The owner initially is also the result signer. The owner can call `setSigner(actualBackendSigner)` once the NIGHTSHIFT operator supplies the production signing address, and can rotate it later. No additional configuration is required. Zero signer addresses are rejected. Protect the backend key or ERC-1271 wallet policy, and monitor SignerUpdated events. The owner can pause/unpause **only new opens** (both `open` and `openInvite`); existing joins, settlement and refunds continue.

The NIGHTSHIFT operator maintains replay determinism, anti-cheat inputs, authenticated player/game records, unique match IDs, chain confirmation policy, and the signing service. Read canonical chain state before signing and issue one consistent result per match with a deadline allowing settlement before its timeout. For arranged pairings, have A call `openInvite` with B's address and B call `joinChecked` with the agreed token, stake and A's address; the server then reads the recorded players from `matches(id)` before signing. For open matchmaking through `open`, the service must use the actual on-chain player B. If an `open` reverts with `MatchAlreadyExists`, the ID was taken by someone else: assign a fresh ID rather than letting B join it.

A relayer or either player submits the result in time. A keeper or player calls refunds after timeouts; neither operation requires owner cooperation. The frontend should show the current signer, match state, expiry time and remaining refund window, and refresh them after chain reorganizations.

Signer rotation immediately changes authorization for all unsettled matches. Old-key signatures fail while that key is deselected. Because the requested Result type has no signer epoch, restoring a retired signer re-enables its unexpired signatures for still-joined matches: rotation suspends a key's outstanding results, it does not revoke them. Operational rule for the owner: never reinstate a key that may have signed a disputed result; rotate to a fresh key instead. ERC-1271 validity can change according to the signer's own policy.

The owner cannot transfer ownership or directly withdraw stakes, change the fee, redirect the splitter, change token tiers, or upgrade the contract. The owner can change the trusted result authority, so fair settlement still depends on the owner and signer. Pausing alone does not stop a compromised signer from settling existing games. See [docs/security-review.md](docs/security-review.md) for the review evidence, tested boundaries and remaining trust assumptions.
