// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ITrustedRouter
/// @notice Implemented by routers that can report the address which initiated
///         the current swap, so a hook can attribute activity to the real
///         trader instead of to the router.
///
/// Uniswap v4 passes `beforeSwap` whoever called `poolManager.swap()`. For any
/// router that is the router itself, so a hook keying on it collapses every
/// trader behind that router into one identity. A router implementing this
/// interface lets the hook recover the originator.
///
/// @dev Implementations normally record `msg.sender` in transient storage at the
///      top of their swap entrypoint and return it here, so the value is only
///      meaningful for the duration of the transaction that set it.
///
///      Some routers in the wild expose this as `msgSender()` rather than
///      `getMsgSender()`. A hook supporting those needs the corresponding
///      selector; see {GradientShieldHook._resolveTrader}.
///
/// SECURITY: a hook must never call this on an arbitrary `sender`. Anyone can
/// deploy a contract that calls the PoolManager directly and returns whatever
/// address it likes from `getMsgSender()`, spoofing an innocent trader or a
/// clean reputation. Only call it on routers held in an explicit allow-list.
interface ITrustedRouter {
    /// @notice The address that initiated the swap currently being executed.
    /// @dev Declared `view` so callers issue a STATICCALL, which cannot mutate
    ///      state or re-enter.
    function getMsgSender() external view returns (address);
}
