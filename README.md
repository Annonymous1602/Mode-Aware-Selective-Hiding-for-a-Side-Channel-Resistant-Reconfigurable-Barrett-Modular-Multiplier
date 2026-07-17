# Mode-Aware-Selective-Hiding-for-a-Side-Channel-Resistant-Reconfigurable-Barrett-Modular-Multiplier

Reconfigurable Barrett modular multipliers let a
single datapath serve multiple operand widths for public-key
and post-quantum cryptography by time-sharing one physical
multiplier array, but this resource reuse funnels several secret-
dependent computations through shared logic and creates a
side-channel attack surface that has not been systematically
evaluated. This work presents the first side-channel analysis of
a reconfigurable Barrett multiplier and a lightweight counter-
measure that protects it across all operating modes. Building on
the reuse-driven architecture of R-BMM, an improved baseline
based on a single shared nine-core 128-bit Karatsuba multiplier
bank supporting 9 × 64-, 3 × 128-, and 1 × 256-bit modes is
shown, through a reproducible register-transfer-level evaluation
flow, to exhibit strong data-dependent leakage in every mode. To
mitigate this, a mode-aware selective hiding countermeasure is
proposed that allocates protection by concurrency and combines
logical-to-physical core permutation, complementary operand
balancing, and a tunable secret-independent activity-equalisation
bank, while leaving the arithmetic result bit-exact. Evaluated
over 50,000 traces per group using first- and second-order Test
Vector Leakage Assessment (TVLA) and correlation analysis, the
protected design passes both first- and second-order TVLA in all
three modes and reduces the maximum absolute correlation by
up to 94% (from 0.28 to 0.017), at an area, power, and latency
overhead of [XX]%, [XX]%, and [XX]% on a Kintex UltraScale+
FPGA, confined to the most leakage-prone 64-bit mode.
