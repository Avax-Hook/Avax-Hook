// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title BalanceRead
/// @notice Gas-bounded `balanceOf` reads of arbitrary ERC-20s for transfer rules that look at other tokens.
///         Copies at most 32 bytes of return data (no return-data bomb) and never reverts: a failing,
///         out-of-gas or short answer reads as `ok = false`.
library BalanceRead {
    function balanceOf(address token, address who, uint256 gasLimit) internal view returns (bool ok, uint256 bal) {
        bytes4 sel = 0x70a08231; // balanceOf(address)
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, sel)
            mstore(add(p, 4), who)
            let success := staticcall(gasLimit, token, p, 0x24, p, 0x20)
            if and(success, gt(returndatasize(), 0x1f)) {
                ok := 1
                bal := mload(p)
            }
        }
    }

    /// @dev Balance or 0 when the read fails.
    function balanceOr0(address token, address who, uint256 gasLimit) internal view returns (uint256 bal) {
        (, bal) = balanceOf(token, who, gasLimit);
    }

    /// @dev True if `a` has no code or only an EIP-7702 delegation designator (0xef0100 ‖ address, 23 bytes):
    ///      an externally owned account. A contract under construction also has no code yet.
    function isEoa(address a) internal view returns (bool) {
        uint256 size = a.code.length;
        if (size == 0) return true;
        if (size != 23) return false;
        bytes3 prefix;
        assembly ("memory-safe") {
            let p := mload(0x40)
            extcodecopy(a, p, 0, 3)
            prefix := and(mload(p), shl(232, 0xffffff))
        }
        return prefix == 0xef0100;
    }
}
