//! Groth16 proof verification, built on the BLS12-381 pairing host functions
//! that `soroban-env-host` exposes (`Env::crypto().bls12_381()`).
//!
//! The equation being checked is the standard Groth16 pairing check:
//!
//!   e(A, B) == e(alpha, beta) * e(vk_x, gamma) * e(C, delta)
//!
//! where `vk_x = ic[0] + sum(ic[i+1] * public_input[i])`. The host only
//! exposes a "product of pairings equals the identity" primitive
//! (`pairing_check`), so the equation above is rearranged into that form by
//! negating `A`:
//!
//!   e(-A, B) * e(alpha, beta) * e(vk_x, gamma) * e(C, delta) == 1

use soroban_sdk::crypto::bls12_381::{Fr, G1Affine, G2Affine};
use soroban_sdk::{contracttype, Env, Vec, U256};

#[contracttype]
#[derive(Clone)]
pub struct VerifyingKey {
    pub alpha: G1Affine,
    pub beta: G2Affine,
    pub gamma: G2Affine,
    pub delta: G2Affine,
    /// `ic[0]` is the constant term; `ic[1..]` pair one-to-one with the
    /// public inputs, in the order the circuit declares them.
    pub ic: Vec<G1Affine>,
}

#[contracttype]
#[derive(Clone)]
pub struct Groth16Proof {
    pub a: G1Affine,
    pub b: G2Affine,
    pub c: G1Affine,
}

/// Returns `true` if `proof` is a valid Groth16 proof of `public_inputs`
/// under `vk`, `false` otherwise (including a public-input count mismatch).
pub fn verify_groth16(
    env: &Env,
    vk: &VerifyingKey,
    proof: &Groth16Proof,
    public_inputs: &Vec<Fr>,
) -> bool {
    if public_inputs.len() as usize + 1 != vk.ic.len() as usize {
        return false;
    }

    let bls = env.crypto().bls12_381();

    let mut vk_x = vk.ic.get(0).unwrap();
    for i in 0..public_inputs.len() {
        let term = bls.g1_mul(&vk.ic.get(i + 1).unwrap(), &public_inputs.get(i).unwrap());
        vk_x = bls.g1_add(&vk_x, &term);
    }

    let zero = Fr::from_u256(U256::from_u32(env, 0));
    let one = Fr::from_u256(U256::from_u32(env, 1));
    let neg_one = bls.fr_sub(&zero, &one);
    let neg_a = bls.g1_mul(&proof.a, &neg_one);

    let g1_points = Vec::from_array(env, [neg_a, vk.alpha.clone(), vk_x, proof.c.clone()]);
    let g2_points = Vec::from_array(
        env,
        [proof.b.clone(), vk.beta.clone(), vk.gamma.clone(), vk.delta.clone()],
    );

    bls.pairing_check(g1_points, g2_points)
}

/// Same check as [`verify_groth16`], but panics instead of returning `false`
/// so it can be used directly as a contract entrypoint that reverts on an
/// invalid proof.
pub fn require_valid_groth16(
    env: &Env,
    vk: &VerifyingKey,
    proof: &Groth16Proof,
    public_inputs: &Vec<Fr>,
) {
    assert!(verify_groth16(env, vk, proof, public_inputs), "invalid proof");
}

#[cfg(test)]
mod test {
    use super::*;

    fn zero_g1(env: &Env) -> G1Affine {
        G1Affine::from_array(env, &[0u8; 96])
    }

    fn zero_g2(env: &Env) -> G2Affine {
        G2Affine::from_array(env, &[0u8; 192])
    }

    #[test]
    fn rejects_public_input_length_mismatch() {
        let env = Env::default();
        let g1 = zero_g1(&env);
        let g2 = zero_g2(&env);

        let vk = VerifyingKey {
            alpha: g1.clone(),
            beta: g2.clone(),
            gamma: g2.clone(),
            delta: g2.clone(),
            // ic has room for exactly 1 public input (constant term + 1).
            ic: Vec::from_array(&env, [g1.clone(), g1.clone()]),
        };
        let proof = Groth16Proof {
            a: g1.clone(),
            b: g2,
            c: g1,
        };

        // The mismatch check must short-circuit before any pairing math
        // runs, so this needs to hold regardless of whether the points
        // above are valid curve points.
        let too_few = Vec::new(&env);
        assert!(!verify_groth16(&env, &vk, &proof, &too_few));

        let too_many = Vec::from_array(
            &env,
            [Fr::from_u256(U256::from_u32(&env, 1)), Fr::from_u256(U256::from_u32(&env, 2))],
        );
        assert!(!verify_groth16(&env, &vk, &proof, &too_many));
    }
}
