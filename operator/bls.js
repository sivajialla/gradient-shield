// BLS (BN254) primitives matching EigenLayer's on-chain conventions.
//
// Scheme: public keys in G2, signatures in G1.
//   pkG1  = sk · G1        (used for on-chain aggregation — G1 add is a precompile)
//   pkG2  = sk · G2        (used as the pairing key)
//   sigma = sk · H(msg)    (H = EigenLayer's try-and-increment hashToG1)
//
// Verification on-chain (BLSQuorumTaskManager._verifyAggregate) is the
// gamma-randomised pairing that simultaneously proves the signature is valid
// AND that apkG1 and apkG2 encode the same aggregate key.

import { bn254 } from "@noble/curves/bn254.js";

export const FP_MODULUS =
  21888242871839275222246405745257275088696311157297823662689037894645226208583n;
export const FR_MODULUS =
  21888242871839275222246405745257275088548364400416034343698204186575808495617n;

// ---------------------------------------------------------------------------
// EigenLayer's hashToG1 — try-and-increment, NOT standard hash-to-curve.
// Mirrors BN254.hashToG1 / findYFromX in eigenlayer-middleware.
// ---------------------------------------------------------------------------

function expmod(base, exp, mod) {
  let result = 1n;
  base %= mod;
  while (exp > 0n) {
    if (exp & 1n) result = (result * base) % mod;
    base = (base * base) % mod;
    exp >>= 1n;
  }
  return result;
}

/** sqrt in F_p via p ≡ 3 (mod 4): y = beta^((p+1)/4) */
function findYFromX(x) {
  const beta = (((x * x) % FP_MODULUS) * x + 3n) % FP_MODULUS;
  const y = expmod(beta, (FP_MODULUS + 1n) / 4n, FP_MODULUS);
  return [beta, y];
}

/** @param {bigint} msgHash 32-byte hash as a bigint */
export function hashToG1(msgHash) {
  let x = msgHash % FP_MODULUS;
  for (;;) {
    const [beta, y] = findYFromX(x);
    if (beta === (y * y) % FP_MODULUS) return { X: x, Y: y };
    x = (x + 1n) % FP_MODULUS;
  }
}

// ---------------------------------------------------------------------------
// Point conversion to the Solidity struct layout
// ---------------------------------------------------------------------------

/** BN254.G1Point { X, Y } */
export function g1ToSol(point) {
  const a = point.toAffine();
  return { X: a.x, Y: a.y };
}

/**
 * BN254.G2Point { X: [x1, x0], Y: [y1, y0] }
 * NOTE the reversed ordering — the EIP-197 pairing precompile encodes
 * `a*i + b` as `(a, b)`, so the imaginary coefficient comes FIRST.
 */
export function g2ToSol(point) {
  const a = point.toAffine();
  return {
    X: [a.x.c1, a.x.c0],
    Y: [a.y.c1, a.y.c0],
  };
}

function g1FromSol(p) {
  return bn254.G1.Point.fromAffine({ x: p.X, y: p.Y });
}

// ---------------------------------------------------------------------------
// Keys and signing
// ---------------------------------------------------------------------------

export function derivePrivateKey(seed) {
  // Deterministic, non-zero scalar in [1, FR_MODULUS)
  let sk = BigInt(seed) % FR_MODULUS;
  if (sk === 0n) sk = 1n;
  return sk;
}

export function publicKeys(sk) {
  return {
    sk,
    pkG1: g1ToSol(bn254.G1.Point.BASE.multiply(sk)),
    pkG2: g2ToSol(bn254.G2.Point.BASE.multiply(sk)),
  };
}

/** sigma = sk · H(msgHash), returned in Solidity G1 form. */
export function sign(sk, msgHash) {
  const h = hashToG1(msgHash);
  const hPoint = bn254.G1.Point.fromAffine({ x: h.X, y: h.Y });
  return g1ToSol(hPoint.multiply(sk));
}

/** Sum G1 points (aggregate signature or aggregate G1 pubkey). */
export function aggregateG1(points) {
  let acc = null;
  for (const p of points) {
    const pt = g1FromSol(p);
    acc = acc === null ? pt : acc.add(pt);
  }
  return g1ToSol(acc);
}

/** Sum G2 points (aggregate pubkey used in the pairing). */
export function aggregateG2(solPoints) {
  let acc = null;
  for (const p of solPoints) {
    // Undo the reversed ordering to rebuild the Fp2 coefficients.
    const pt = bn254.G2.Point.fromAffine({
      x: { c0: p.X[1], c1: p.X[0] },
      y: { c0: p.Y[1], c1: p.Y[0] },
    });
    acc = acc === null ? pt : acc.add(pt);
  }
  return g2ToSol(acc);
}

// ---------------------------------------------------------------------------
// Message hash — must match BLSQuorumTaskManager.scoreMessageHash
// ---------------------------------------------------------------------------

/** keccak256(abi.encode(taskIndex, subject, score)) */
export function scoreMessageHash(ethers, taskIndex, subject, score) {
  return BigInt(
    ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ["uint32", "address", "uint16"],
        [taskIndex, subject, score]
      )
    )
  );
}
