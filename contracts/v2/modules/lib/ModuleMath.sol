// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title ModuleMath
/// @notice Small fixed-point helpers shared by v2 modules (WAD = 1e18). Every function is O(1) or
///         O(log n) with a hard bound, so callbacks that use them stay far below MODULE_GAS.
library ModuleMath {
    uint256 internal constant WAD = 1e18;

    /// @dev sin(k/64 · π/2) for k = 0..64, scaled by 1e9, 4 bytes each (quarter wave).
    bytes internal constant SIN_TABLE =
        hex"000000000176782d02ecb69a0462819405d79f74074bd6b308beedea0a30abe10ba0d7920d0f38380e7b95540fe5b6b5114d648512b2674c141487fd15738ffd16cf492818277de2197bf9151acc86421c18f1811d6107901ea495d81fe36a74211d5439225222bf2381a66824abb06725d012c426eea06b28072d2b29198dc12a2597dd2b2b222b2c2a04552d22170f2e1334152efd363c2fdff96b30bb5aad318f382c325b713d331fe66233dc794f34910cf0353d856d35e1c82d367dbbdc3711486d379c571f381ed2813898a6753909c03039720e4239d180953a2808723a7598803aba24ca3af5a2be3b28092f3b5150573b7171d93b8868c03b9631833b9aca00";

    /// @notice sin(2π · turn) where `turn` is a fraction of a full turn in WAD (any value; taken mod 1).
    ///         Quarter-wave lookup table (64 steps) with linear interpolation: |error| < 8e-5.
    /// @return s WAD in [-1e18, 1e18]
    function sinTurn(uint256 turn) internal pure returns (int256 s) {
        turn %= WAD;
        uint256 q = (turn * 4) / WAD; // quadrant 0..3
        uint256 p = (turn * 4) % WAD; // position inside the quadrant, WAD
        if (q == 1 || q == 3) p = WAD - p; // mirror: sin(π - x) = sin(x)
        uint256 v = _quarter(p);
        s = q < 2 ? int256(v) : -int256(v);
    }

    /// @notice cos(2π · turn) = sin(2π · (turn + 1/4)).
    function cosTurn(uint256 turn) internal pure returns (int256) {
        return sinTurn((turn % WAD) + WAD / 4);
    }

    /// @dev sin(p · π/2) for p in [0, WAD], WAD.
    function _quarter(uint256 p) private pure returns (uint256) {
        uint256 x = p * 64; // index scaled by WAD
        uint256 i = x / WAD;
        if (i >= 64) return WAD;
        uint256 frac = x % WAD;
        bytes memory t = SIN_TABLE;
        uint256 a;
        uint256 b;
        assembly ("memory-safe") {
            let ptr := add(add(t, 32), mul(i, 4))
            a := shr(224, mload(ptr))
            b := shr(224, mload(add(ptr, 4)))
        }
        // a, b are 1e9-scaled; interpolate in WAD
        return (a * 1e9) + ((b - a) * 1e9 * frac) / WAD;
    }

    /// @notice base^exp in WAD for base <= WAD (exponentiation by squaring, at most 64 rounds).
    function rpow(uint256 base, uint256 exp) internal pure returns (uint256 r) {
        r = WAD;
        while (exp != 0) {
            if (exp & 1 != 0) r = (r * base) / WAD;
            exp >>= 1;
            if (exp != 0) base = (base * base) / WAD;
            if (r == 0) return 0;
        }
    }
}

/// @title TxTally
/// @notice Per-transaction running sums kept in the module's own transient storage (EIP-1153). They reset
///         at the end of every transaction, so a rule priced "per buy" can't be dodged by splitting one
///         transaction into several swaps.
abstract contract TxTally {
    function _tallyAdd(bytes32 key, uint256 amount) internal returns (uint256 total) {
        assembly ("memory-safe") {
            total := add(tload(key), amount)
            tstore(key, total)
        }
    }

    function _tload(bytes32 key) internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := tload(key)
        }
    }

    function _tstore(bytes32 key, uint256 v) internal {
        assembly ("memory-safe") {
            tstore(key, v)
        }
    }
}
