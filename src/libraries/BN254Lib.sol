// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title BN254Lib
/// @notice BN254 (alt_bn128) curve operations and BLS primitives, built on the
///         EVM precompiles: ecAdd (0x06), ecMul (0x07), pairing (0x08), modexp (0x05).
///
/// @dev This is a trimmed, pragma-compatible port of EigenLayer's
///      `eigenlayer-middleware/src/libraries/BN254.sol` (MIT). It exists because
///      Uniswap v4-core pins `PoolManager.sol` to exactly `=0.8.26` while the
///      EigenLayer library declares `^0.8.27` — the two cannot be linked into a
///      single compilation unit. Vendoring the subset we need lets the hook and
///      the BLS quorum live in the same test and the same deployment.
///
///      The arithmetic and the G2 coordinate ordering are byte-for-byte
///      identical to the EigenLayer original, so signatures and public keys are
///      interchangeable between this library and a real EigenLayer AVS.
library BN254Lib {
    /// @notice Modulus of the base field F_p.
    uint256 internal constant FP_MODULUS =
        21888242871839275222246405745257275088696311157297823662689037894645226208583;

    /// @notice Modulus of the scalar field F_r.
    uint256 internal constant FR_MODULUS =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    struct G1Point {
        uint256 X;
        uint256 Y;
    }

    /// @dev Field elements are encoded as `X[1] * i + X[0]`.
    struct G2Point {
        uint256[2] X;
        uint256[2] Y;
    }

    error ECAddFailed();
    error ECMulFailed();
    error ECPairingFailed();
    error ExpModFailed();

    // -----------------------------------------------------------------
    // Generators
    // -----------------------------------------------------------------

    uint256 internal constant G2x1 =
        11559732032986387107991004021392285783925812861821192530917403151452391805634;
    uint256 internal constant G2x0 =
        10857046999023057135944570762232829481370756359578518086990519993285655852781;
    uint256 internal constant G2y1 =
        4082367875863433681332203403145435568316851327593401208105741076214120093531;
    uint256 internal constant G2y0 =
        8495653923123431417604973247489272438418190587263600148770280649306958101930;

    uint256 internal constant nG2x1 =
        11559732032986387107991004021392285783925812861821192530917403151452391805634;
    uint256 internal constant nG2x0 =
        10857046999023057135944570762232829481370756359578518086990519993285655852781;
    uint256 internal constant nG2y1 =
        17805874995975841540914202342111839520379459829704422454583296818431106115052;
    uint256 internal constant nG2y0 =
        13392588948715843804641432497768002650278120570034223513918757245338268106653;

    function generatorG1() internal pure returns (G1Point memory) {
        return G1Point(1, 2);
    }

    /// @dev Mind the ordering: the EIP-197 precompile encodes `a*i + b` as `(a, b)`,
    ///      so the imaginary coefficient comes first.
    function generatorG2() internal pure returns (G2Point memory) {
        return G2Point([G2x1, G2x0], [G2y1, G2y0]);
    }

    function negGeneratorG2() internal pure returns (G2Point memory) {
        return G2Point([nG2x1, nG2x0], [nG2y1, nG2y0]);
    }

    // -----------------------------------------------------------------
    // G1 arithmetic
    // -----------------------------------------------------------------

    function negate(G1Point memory p) internal pure returns (G1Point memory) {
        if (p.X == 0 && p.Y == 0) return G1Point(0, 0);
        return G1Point(p.X, FP_MODULUS - (p.Y % FP_MODULUS));
    }

    /// @return r The sum of two G1 points, via the ecAdd precompile.
    function plus(G1Point memory p1, G1Point memory p2) internal view returns (G1Point memory r) {
        uint256[4] memory input;
        input[0] = p1.X;
        input[1] = p1.Y;
        input[2] = p2.X;
        input[3] = p2.Y;
        bool success;
        assembly {
            success := staticcall(sub(gas(), 2000), 6, input, 0x80, r, 0x40)
            switch success
            case 0 { invalid() }
        }
        if (!success) revert ECAddFailed();
    }

    /// @return r The product of a G1 point and a scalar, via the ecMul precompile.
    function scalar_mul(G1Point memory p, uint256 s) internal view returns (G1Point memory r) {
        uint256[3] memory input;
        input[0] = p.X;
        input[1] = p.Y;
        input[2] = s;
        bool success;
        assembly {
            success := staticcall(sub(gas(), 2000), 7, input, 0x60, r, 0x40)
            switch success
            case 0 { invalid() }
        }
        if (!success) revert ECMulFailed();
    }

    // -----------------------------------------------------------------
    // Pairing
    // -----------------------------------------------------------------

    /// @notice Checks e(a1, a2) * e(b1, b2) == 1.
    /// @param pairingGas Gas forwarded to the precompile. A bounded budget matters
    ///        because a reverting precompile would otherwise consume everything.
    /// @return success Whether the precompile ran (inputs were well-formed points).
    /// @return result  Whether the pairing equation holds.
    function safePairing(
        G1Point memory a1,
        G2Point memory a2,
        G1Point memory b1,
        G2Point memory b2,
        uint256 pairingGas
    ) internal view returns (bool success, bool result) {
        G1Point[2] memory p1 = [a1, b1];
        G2Point[2] memory p2 = [a2, b2];

        uint256[12] memory input;
        for (uint256 i = 0; i < 2; i++) {
            uint256 j = i * 6;
            input[j + 0] = p1[i].X;
            input[j + 1] = p1[i].Y;
            input[j + 2] = p2[i].X[0];
            input[j + 3] = p2[i].X[1];
            input[j + 4] = p2[i].Y[0];
            input[j + 5] = p2[i].Y[1];
        }

        uint256[1] memory out;
        assembly {
            success := staticcall(pairingGas, 8, input, mul(12, 0x20), out, 0x20)
        }
        return (success, out[0] != 0);
    }

    // -----------------------------------------------------------------
    // Hash to curve
    // -----------------------------------------------------------------

    /// @notice Maps a 32-byte digest onto G1 by try-and-increment.
    /// @dev Not a constant-time or standards-track hash-to-curve, but it is the
    ///      scheme EigenLayer operators sign against, so it must match exactly.
    function hashToG1(bytes32 _x) internal view returns (G1Point memory) {
        uint256 beta = 0;
        uint256 y = 0;
        uint256 x = uint256(_x) % FP_MODULUS;

        while (true) {
            (beta, y) = findYFromX(x);
            if (beta == mulmod(y, y, FP_MODULUS)) {
                return G1Point(x, y);
            }
            x = addmod(x, 1, FP_MODULUS);
        }
        return G1Point(0, 0);
    }

    /// @return beta x^3 + 3
    /// @return y    sqrt(beta), valid only when beta is a quadratic residue
    function findYFromX(uint256 x) internal view returns (uint256, uint256) {
        uint256 beta = addmod(mulmod(mulmod(x, x, FP_MODULUS), x, FP_MODULUS), 3, FP_MODULUS);
        // p ≡ 3 (mod 4), so sqrt(beta) = beta^((p+1)/4)
        uint256 y = expMod(beta, 0xc19139cb84c680a6e14116da060561765e05aa45a1c72a34f082305b61f3f52, FP_MODULUS);
        return (beta, y);
    }

    function expMod(uint256 _base, uint256 _exponent, uint256 _modulus) internal view returns (uint256) {
        bool success;
        uint256[1] memory output;
        uint256[6] memory input;
        input[0] = 0x20; // baseLen
        input[1] = 0x20; // expLen
        input[2] = 0x20; // modLen
        input[3] = _base;
        input[4] = _exponent;
        input[5] = _modulus;
        assembly {
            success := staticcall(sub(gas(), 2000), 5, input, 0xc0, output, 0x20)
            switch success
            case 0 { invalid() }
        }
        if (!success) revert ExpModFailed();
        return output[0];
    }

    // -----------------------------------------------------------------
    // Hashing helpers
    // -----------------------------------------------------------------

    function hashG1Point(G1Point memory p) internal pure returns (bytes32 hashedG1) {
        assembly {
            mstore(0, mload(p))
            mstore(0x20, mload(add(0x20, p)))
            hashedG1 := keccak256(0, 0x40)
        }
    }

    function hashG2Point(G2Point memory p) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(p.X[0], p.X[1], p.Y[0], p.Y[1]));
    }
}
