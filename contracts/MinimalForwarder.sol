// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;


/// @title MinimalForwarder
/// @notice EIP-712 compliant meta-transaction forwarder for sponsored/gasless transactions.
///
/// @dev Flow:
///   1. The user (signer) builds a `ForwardRequest` describing the call they want to execute.
///   2. The user EIP-712-signs it off-chain using the domain of this contract.
///   3. A relayer submits `execute(req, sig)` on the user's behalf, paying for gas.
///   4. The forwarder verifies the signature and nonce, then calls `req.to` with
///      `req.data || req.from` (ERC-2771 calldata extension).
///   5. The target contract strips the last 20 bytes to recover the true sender.
///
/// Security guarantees:
///   - **Replay protection**: Each `(signer, nonce)` pair is single-use.
///   - **Deadline enforcement**: Requests expire at `req.deadline` (block.timestamp).
///   - **Signature binding**: The EIP-712 hash covers every field of ForwardRequest;
///     altering any field invalidates the signature.
///   - **Chain binding**: Domain separator includes `block.chainid`; signatures are
///     non-transferable across chains (fork safety).
contract MinimalForwarder {
    error Expired();
    error NonceMismatch();
    error InvalidSignatureLength();
    error InvalidSignature();
    error InvalidSignatureV();
    error SignerRecoveryFailed();
    error CallFailed();

    // ─── EIP-712 Domain ─────────────────────────────────────────────────────

    /// @dev EIP-712 type hash for the domain separator.
    bytes32 private constant _DOMAIN_TYPE_HASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    /// @dev EIP-712 type hash for a ForwardRequest.
    bytes32 public constant FORWARD_REQUEST_TYPEHASH = keccak256(
        "ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,uint256 deadline,bytes data)"
    );

    /// @dev Cached domain separator (recomputed on every call to handle forks cleanly).
    bytes32 private immutable _DOMAIN_SEPARATOR;

    /// @dev Chain id captured at deploy time, used to detect cross-chain replays.
    uint256 private immutable _INITIAL_CHAIN_ID;

    // ─── State ──────────────────────────────────────────────────────────────

    /// @notice Per-signer sequential nonce.  Must be included in every signed request.
    mapping(address => uint256) public nonces;

    // ─── Structs ────────────────────────────────────────────────────────────

    /// @notice The data structure that the user signs.
    struct ForwardRequest {
        address from; // original signer / true sender
        address to; // target contract
        uint256 value; // ETH to forward (usually 0 for pure meta-txs)
        uint256 gas; // gas limit for the inner call
        uint256 nonce; // signer's current nonce (must match stored value)
        uint256 deadline; // request expires after this timestamp
        bytes data; // encoded function call
    }

    // ─── Events ─────────────────────────────────────────────────────────────

    event MetaTransactionExecuted(
        address indexed from,
        address indexed to,
        bool success,
        bytes returnData
    );

    // ─── Constructor ────────────────────────────────────────────────────────

    constructor() {
        _INITIAL_CHAIN_ID = block.chainid;
        _DOMAIN_SEPARATOR = _buildDomainSeparator();
    }

    // ─── EIP-712 Helpers ────────────────────────────────────────────────────

    /// @notice Returns the active EIP-712 domain separator.
    /// @dev Returns a freshly built separator if the chain id has changed (post-fork).
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        if (block.chainid == _INITIAL_CHAIN_ID) {
            return _DOMAIN_SEPARATOR;
        }
        return _buildDomainSeparator();
    }

    /// @dev Builds the EIP-712 domain separator.
    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                _DOMAIN_TYPE_HASH,
                keccak256(bytes("MinimalForwarder")),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    /// @notice Returns the EIP-712 typed-data hash for a request.
    function _hashRequest(ForwardRequest calldata req) internal view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        FORWARD_REQUEST_TYPEHASH,
                        req.from,
                        req.to,
                        req.value,
                        req.gas,
                        req.nonce,
                        req.deadline,
                        keccak256(req.data)
                    )
                )
            )
        );
    }

    // ─── Signature Verification ─────────────────────────────────────────────

    /// @notice Verify that `signature` is a valid EIP-712 signature for `req` from `req.from`.
    /// @return True if the signature is valid and nonce / deadline are still acceptable.
    function verify(ForwardRequest calldata req, bytes calldata signature)
        public
        view
        returns (bool)
    {
        if (req.nonce != nonces[req.from]) return false;
        if (block.timestamp > req.deadline) return false;
        if (signature.length != 65) return false;

        bytes32 digest = _hashRequest(req);
        address recovered = _recoverSigner(digest, signature);
        return recovered == req.from;
    }

    // ─── Execution ──────────────────────────────────────────────────────────

    /// @notice Execute a meta-transaction on behalf of the signer.
    /// @dev  Reverts on signature or nonce or deadline failure.
    ///       Forwards call as `req.data || req.from` per ERC-2771.
    ///       The inner call's success/failure is bubbled up.
    /// @param req    The forward request (must be signed by `req.from`).
    /// @param signature  65-byte ECDSA signature over the EIP-712 digest.
    /// @return success   Whether the inner call succeeded.
    /// @return returnData Raw return data from the inner call.
    function execute(ForwardRequest calldata req, bytes calldata signature)
        external
        payable
        returns (bool success, bytes memory returnData)
    {
        // ── Pre-flight checks ────────────────────────────────────────────────
        if (!(block.timestamp <= req.deadline)) revert Expired();
        if (!(req.nonce == nonces[req.from])) revert NonceMismatch();
        if (!(signature.length == 65)) revert InvalidSignatureLength();

        bytes32 digest = _hashRequest(req);
        address signer = _recoverSigner(digest, signature);
        if (!(signer == req.from)) revert InvalidSignature();

        // ── State mutation (increment nonce before call – reentrancy safe) ───
        nonces[req.from]++;

        // ── Forward call (ERC-2771: append `req.from` to calldata) ───────────
        // slither-disable-next-line arbitrary-send-eth
        (success, returnData) = req.to.call{gas: req.gas, value: req.value}(
            abi.encodePacked(req.data, req.from)
        );

        emit MetaTransactionExecuted(req.from, req.to, success, returnData);

        // Propagate inner revert if the call failed.
        if (!success) {
            // Bubble up revert reason if any.
            if (returnData.length > 0) {
                // solhint-disable-next-line no-inline-assembly
                assembly {
                    let ptr := mload(0x40)
                    revert(add(returnData, 32), mload(returnData))
                }
            }
            revert CallFailed();
        }
    }

    // ─── ECDSA ──────────────────────────────────────────────────────────────

    /// @dev Recover the signer address from a digest and a 65-byte ECDSA signature.
    function _recoverSigner(bytes32 digest, bytes calldata sig)
        internal
        pure
        returns (address)
    {
        bytes32 r;
        bytes32 s;
        uint8 v;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
        // Normalise Ethereum-style v values (27/28).
        if (v < 27) v += 27;
        if (!(v == 27 || v == 28)) revert InvalidSignatureV();

        address recovered = ecrecover(digest, v, r, s);
        if (!(recovered != address(0))) revert SignerRecoveryFailed();
        return recovered;
    }
}
