use soroban_sdk::{Env, U256};

/// Computes `floor(a * b / denominator)` without ever forming the intermediate
/// `a * b` product in `u128`. `a * b` overflows `u128` once both operands are
/// large (e.g. compounding a big balance by an accumulated rate), which is
/// exactly the case a naive `a.checked_mul(b)?.checked_div(denominator)`
/// can't handle. This delegates the multiply and divide to the host's
/// native `U256`, which carries the product at full width and only narrows
/// back down to `u128` once the division is done.
///
/// Returns `None` if `denominator` is zero or the final quotient doesn't fit
/// in a `u128`.
pub fn mul_div_floor(env: &Env, a: u128, b: u128, denominator: u128) -> Option<u128> {
    if denominator == 0 {
        return None;
    }

    let product = U256::from_u128(env, a).mul(&U256::from_u128(env, b));
    let denom = U256::from_u128(env, denominator);
    product.div(&denom).to_u128()
}

/// Reference implementation used to check `mul_div_floor` against: split the
/// multiplication around `denominator` so the intermediate values stay
/// small. This is the workaround contracts reach for today, and it's
/// mathematically exact (splitting `a = q*denominator + r` distributes
/// cleanly under floor division), but it still overflows once `r * b`
/// itself exceeds `u128`, and it costs more instructions than the `U256`
/// path because of the extra `checked_*` branching.
#[cfg(test)]
fn naive_mul_div_floor(a: u128, b: u128, denominator: u128) -> Option<u128> {
    if denominator == 0 {
        return None;
    }

    let quotient = a / denominator;
    let remainder = a % denominator;

    let whole = quotient.checked_mul(b)?;
    let partial = remainder.checked_mul(b)?.checked_div(denominator)?;
    whole.checked_add(partial)
}

#[cfg(test)]
mod test {
    use super::*;
    use soroban_sdk::Env;

    #[test]
    fn matches_naive_implementation_on_representable_inputs() {
        let env = Env::default();

        let cases: &[(u128, u128, u128)] = &[
            (0, 0, 1),
            (1, 1, 1),
            (100, 50, 3),
            (1_000_000_000, 250_000, 7),
            (u128::from(u64::MAX), u128::from(u64::MAX), 1_000_000_007),
            (u128::MAX, 1, u128::MAX),
            (u128::MAX / 2, 2, 3),
        ];

        for &(a, b, denominator) in cases {
            assert_eq!(
                mul_div_floor(&env, a, b, denominator),
                naive_mul_div_floor(a, b, denominator),
                "mismatch for a={a}, b={b}, denominator={denominator}"
            );
        }
    }

    #[test]
    fn zero_denominator_returns_none() {
        let env = Env::default();
        assert_eq!(mul_div_floor(&env, 10, 10, 0), None);
    }

    #[test]
    fn handles_products_that_overflow_u128() {
        let env = Env::default();

        // a * b here is far past u128::MAX, so `a.checked_mul(b)` alone would
        // fail. mul_div_floor should still produce the exact answer as long
        // as the final quotient fits back in a u128.
        let a = u128::MAX;
        let b = u128::MAX;
        let denominator = u128::MAX;

        assert_eq!(mul_div_floor(&env, a, b, denominator), Some(u128::MAX));
    }

    #[test]
    fn quasi_random_equivalence_sweep() {
        let env = Env::default();

        // A small deterministic LCG in place of a fuzzer dependency, so this
        // sweep doesn't need std/proptest to run inside the no_std crate.
        let mut state: u64 = 0x2545F4914F6CDD1D;
        let mut next = || {
            state = state
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            state
        };

        for _ in 0..50 {
            let a = u128::from(next());
            let b = u128::from(next());
            let denominator = (u128::from(next()) % 1_000_000_000).max(1);

            assert_eq!(
                mul_div_floor(&env, a, b, denominator),
                naive_mul_div_floor(a, b, denominator),
                "mismatch for a={a}, b={b}, denominator={denominator}"
            );
        }
    }
}
