`timescale 1ns/1ps

// ================================================================
// Fully Mode-Reconfigurable Barrett Modular Multiplier
//
// alpha = 7
// beta  = 8
//
// mode = 2'b00 : 9 parallel 64-bit modular multiplications
// mode = 2'b01 : 3 parallel 128-bit modular multiplications
// mode = 2'b10 : 1 parallel 256-bit modular multiplication
//
// Fully reconfigurable meaning:
//   Same physical 9 x 128-bit multiplier cores are reused.
//   Only input mapping, grouping, recombination, shifts,
//   and output selection change based on mode.
//
// Algorithm:
//   P  = A * B
//   PS = P >> (N - beta)
//   q  = (PS * mu) >> (N + alpha + beta)
//   Z  = P - q*M
//   if Z >= M, Z = Z - M
//
// mu = floor(2^(2N + alpha) / M)
//
// ================================================================

(* use_dsp = "no" *)
module rbmm_qgsp #(
    parameter [31:0] QGSP_SEED = 32'h1ACE_B00C,
    // Tunable 64-bit security equalization bank. Must be a multiple of 32.
    // Increase to 16384 or 32768 if 64-bit second-order TVLA still fails.
    parameter integer SEC64_TOGGLE_BITS = 8192
)(

    input  wire clk,
    input  wire rst,
    input  wire start,
    input  wire [1:0] mode,

    // ------------------------------------------------------------
    // 64-bit mode: 9 parallel lanes
    // ------------------------------------------------------------
    input  wire [9*64-1:0]   A64,
    input  wire [9*64-1:0]   B64,
    input  wire [9*64-1:0]   M64,
    input  wire [9*128-1:0]  MU64,

    // ------------------------------------------------------------
    // 128-bit mode: 3 parallel lanes
    // ------------------------------------------------------------
    input  wire [3*128-1:0]  A128,
    input  wire [3*128-1:0]  B128,
    input  wire [3*128-1:0]  M128,
    input  wire [3*256-1:0]  MU128,

    // ------------------------------------------------------------
    // 256-bit mode: 1 lane
    // ------------------------------------------------------------
    input  wire [255:0]      A256,
    input  wire [255:0]      B256,
    input  wire [255:0]      M256,
    input  wire [511:0]      MU256,

    output reg busy,
    output reg done,

    output reg [1:0]         done_mode,

    output reg [9*64-1:0]    P64,
    output reg [3*128-1:0]   P128,
    output reg [255:0]       P256
);

    // ============================================================
    // Algorithm parameters
    // ============================================================

    localparam ALPHA = 7;
    localparam BETA  = 8;

    // ============================================================
    // FSM states
    // ============================================================

    localparam S_IDLE    = 3'd0;
    localparam S_MUL_AB  = 3'd1;
    localparam S_MUL_QMU = 3'd2;
    localparam S_MUL_QM  = 3'd3;
    localparam S_REDUCE  = 3'd4;
    localparam S_DONE    = 3'd5;
    // 64-bit-only random precharge/balancing state.
    // This extra cycle is used only in mode=00 to reduce HD/HW leakage.
    localparam S_PRE64   = 3'd6;

    reg [2:0] state;

    // Latched mode.
    // This makes the design safely reconfigurable between operations.
    reg [1:0] mode_r;

    // ============================================================
    // QGSP lightweight protection state
    // - perm_sel randomizes logical-to-physical multiplier-core use
    // - qgsp_dummy_* creates mode-independent uncorrelated switching
    //   for simulation/synthesis-visible balancing.
    // ============================================================
    reg [31:0] qgsp_lfsr;
    reg [1:0]  perm_sel;
    reg [127:0] qgsp_dummy0, qgsp_dummy1, qgsp_dummy2;
    wire qgsp_fb = qgsp_lfsr[31] ^ qgsp_lfsr[21] ^ qgsp_lfsr[1] ^ qgsp_lfsr[0];

    // ----------------------------------------------------------------
    // Mode-adaptive second-order balancing for the fully-parallel 64-bit
    // mode. The previous QGSP version only permuted physical lanes; that
    // hides location but not total activity. These registers add random,
    // secret-independent switching only when mode=00 is active. They are
    // kept as real hardware so VCD, SAIF, and synthesis see the overhead.
    // ----------------------------------------------------------------
    (* keep = "true", dont_touch = "true" *) reg [31:0] sec64_noise [0:255];
    (* keep = "true", dont_touch = "true" *) reg [63:0] sec64_a_comp [0:8];
    (* keep = "true", dont_touch = "true" *) reg [63:0] sec64_b_comp [0:8];
    (* keep = "true", dont_touch = "true" *) reg [127:0] sec64_pseudo_prod [0:8];
    (* keep = "true", dont_touch = "true" *) reg [31:0] sec64_sink;
    reg [31:0] sec64_rng;
    wire sec64_fb = sec64_rng[31] ^ sec64_rng[28] ^ sec64_rng[19] ^ sec64_rng[3];
    localparam integer SEC64_WORDS = (SEC64_TOGGLE_BITS/32);

    // Same-cycle complementary balancing masks for 64-bit mode.
    // The mask is saved during precharge and reused during the real-load cycle,
    // so one companion register has HD(A) and the other has HD(~A).
    (* keep = "true", dont_touch = "true" *) reg [63:0] sec64_a_real [0:8];
    (* keep = "true", dont_touch = "true" *) reg [63:0] sec64_b_real [0:8];
    (* keep = "true", dont_touch = "true" *) reg [63:0] sec64_a_mask [0:8];
    (* keep = "true", dont_touch = "true" *) reg [63:0] sec64_b_mask [0:8];

    // Large fixed-amplitude activity equalizer for the 64-bit mode. This is
    // secret-independent and is intended to equalize the fixed/random variance
    // used by second-order TVLA.
    (* keep = "true", dont_touch = "true" *) reg [SEC64_TOGGLE_BITS-1:0] sec64_toggle_bank;
    integer sec_i;


    // ============================================================
    // Shared multiplier-bank operands
    // ============================================================

    reg  [9*128-1:0]  bank_a64;
    reg  [9*128-1:0]  bank_b64;
    wire [9*256-1:0]  bank_p64;

    reg  [3*256-1:0]  bank_a128;
    reg  [3*256-1:0]  bank_b128;
    wire [3*512-1:0]  bank_p128;

    reg  [511:0]      bank_a256;
    reg  [511:0]      bank_b256;
    wire [1023:0]     bank_p256;

    // ============================================================
    // Intermediate registers
    // ============================================================

    reg [127:0] x64_0, x64_1, x64_2, x64_3, x64_4, x64_5, x64_6, x64_7, x64_8;
    reg [128:0] qm64_0, qm64_1, qm64_2, qm64_3, qm64_4, qm64_5, qm64_6, qm64_7, qm64_8;

    reg [255:0] x128_0, x128_1, x128_2;
    reg [256:0] qm128_0, qm128_1, qm128_2;

    reg [511:0] x256;
    reg [512:0] qm256;

    // ============================================================
    // One physical reconfigurable multiplier bank
    // ============================================================

    rbmm_bank_9core_qgsp u_bank (
        .mode(mode_r),
        .perm_sel(perm_sel),

        .a64(bank_a64),
        .b64(bank_b64),
        .p64(bank_p64),

        .a128(bank_a128),
        .b128(bank_b128),
        .p128(bank_p128),

        .a256(bank_a256),
        .b256(bank_b256),
        .p256(bank_p256)
    );

    // ============================================================
    // Final correction functions
    //
    // Robust form:
    //   z = P - qM
    //   if qM > P, add one modulus once
    //   then subtract modulus while z >= M
    //
    // For the selected alpha/beta, correction should be small.
    // Two subtractions are kept for safety.
    // ============================================================

    function [63:0] reduce64_alg2;
        input [127:0] p;
        input [128:0] qm;
        input [63:0]  m;

        reg [129:0] p_ext;
        reg [129:0] qm_ext;
        reg [129:0] m_ext;
        reg [129:0] z;

        begin
            p_ext  = {2'b00, p};
            qm_ext = {1'b0, qm};
            m_ext  = {66'b0, m};

            if (p_ext >= qm_ext)
                z = p_ext - qm_ext;
            else
                z = p_ext + m_ext - qm_ext;

            if (z >= m_ext) z = z - m_ext;
            if (z >= m_ext) z = z - m_ext;

            reduce64_alg2 = z[63:0];
        end
    endfunction


    function [127:0] reduce128_alg2;
        input [255:0] p;
        input [256:0] qm;
        input [127:0] m;

        reg [257:0] p_ext;
        reg [257:0] qm_ext;
        reg [257:0] m_ext;
        reg [257:0] z;

        begin
            p_ext  = {2'b00, p};
            qm_ext = {1'b0, qm};
            m_ext  = {130'b0, m};

            if (p_ext >= qm_ext)
                z = p_ext - qm_ext;
            else
                z = p_ext + m_ext - qm_ext;

            if (z >= m_ext) z = z - m_ext;
            if (z >= m_ext) z = z - m_ext;

            reduce128_alg2 = z[127:0];
        end
    endfunction


    function [255:0] reduce256_alg2;
        input [511:0] p;
        input [512:0] qm;
        input [255:0] m;

        reg [513:0] p_ext;
        reg [513:0] qm_ext;
        reg [513:0] m_ext;
        reg [513:0] z;

        begin
            p_ext  = {2'b00, p};
            qm_ext = {1'b0, qm};
            m_ext  = {258'b0, m};

            if (p_ext >= qm_ext)
                z = p_ext - qm_ext;
            else
                z = p_ext + m_ext - qm_ext;

            if (z >= m_ext) z = z - m_ext;
            if (z >= m_ext) z = z - m_ext;

            reduce256_alg2 = z[255:0];
        end
    endfunction

    // ============================================================
    // Main FSM
    // ============================================================

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= S_IDLE;
            mode_r <= 2'b00;
            qgsp_lfsr <= QGSP_SEED;
            perm_sel <= 2'b00;
            qgsp_dummy0 <= 128'h0;
            qgsp_dummy1 <= 128'h0;
            qgsp_dummy2 <= 128'h0;
            sec64_rng <= QGSP_SEED ^ 32'hA5A5_5A5A;
            sec64_sink <= 32'h0;
            sec64_toggle_bank <= {SEC64_WORDS{QGSP_SEED}};
            for (sec_i = 0; sec_i < 256; sec_i = sec_i + 1) begin
                sec64_noise[sec_i] <= (QGSP_SEED ^ (32'h9E37_79B9 + sec_i));
            end
            for (sec_i = 0; sec_i < 9; sec_i = sec_i + 1) begin
                sec64_a_real[sec_i] <= 64'h0;
                sec64_b_real[sec_i] <= 64'h0;
                sec64_a_comp[sec_i] <= 64'h0;
                sec64_b_comp[sec_i] <= 64'h0;
                sec64_a_mask[sec_i] <= 64'h0;
                sec64_b_mask[sec_i] <= 64'h0;
                sec64_pseudo_prod[sec_i] <= 128'h0;
            end

            busy <= 1'b0;
            done <= 1'b0;
            done_mode <= 2'b00;

            P64  <= 0;
            P128 <= 0;
            P256 <= 0;

            bank_a64  <= 0;
            bank_b64  <= 0;
            bank_a128 <= 0;
            bank_b128 <= 0;
            bank_a256 <= 0;
            bank_b256 <= 0;

            x64_0 <= 0; x64_1 <= 0; x64_2 <= 0; x64_3 <= 0; x64_4 <= 0;
            x64_5 <= 0; x64_6 <= 0; x64_7 <= 0; x64_8 <= 0;

            qm64_0 <= 0; qm64_1 <= 0; qm64_2 <= 0; qm64_3 <= 0; qm64_4 <= 0;
            qm64_5 <= 0; qm64_6 <= 0; qm64_7 <= 0; qm64_8 <= 0;

            x128_0 <= 0; x128_1 <= 0; x128_2 <= 0;
            qm128_0 <= 0; qm128_1 <= 0; qm128_2 <= 0;

            x256  <= 0;
            qm256 <= 0;

        end else begin
            done <= 1'b0;

            // Update QGSP state once per active cycle. The dummy registers
            // are intentionally driven only by the LFSR so their switching is
            // independent of secret operands.
            if (start || busy) begin
                qgsp_lfsr <= {qgsp_lfsr[30:0], qgsp_fb};
                perm_sel <= qgsp_lfsr[1:0];
                qgsp_dummy0 <= qgsp_dummy0 ^ {4{qgsp_lfsr}};
                qgsp_dummy1 <= {qgsp_dummy1[126:0], qgsp_dummy1[127]} ^ {qgsp_lfsr, qgsp_lfsr, qgsp_lfsr, qgsp_lfsr};
                qgsp_dummy2 <= ~qgsp_dummy2 ^ {qgsp_lfsr[15:0], qgsp_lfsr[31:16], qgsp_lfsr[7:0], qgsp_lfsr[31:8], qgsp_lfsr[23:0], qgsp_lfsr[31:24], qgsp_lfsr};

                // 64-bit protection v4:
                //   1) keep the old small noise bank for local randomization,
                //   2) add a large secret-independent toggle bank to equalize
                //      the second-order fixed/random variance,
                //   3) update in the same operation window as the real datapath.
                if ((mode_r == 2'b00) || (start && mode == 2'b00)) begin
                    sec64_rng <= {sec64_rng[30:0], sec64_fb} ^ qgsp_lfsr ^ 32'h6C8E_9CF5;
                    sec64_toggle_bank <= {sec64_toggle_bank[SEC64_TOGGLE_BITS-2:0], sec64_toggle_bank[SEC64_TOGGLE_BITS-1]} ^
                                         {SEC64_WORDS{(sec64_rng ^ qgsp_lfsr ^ 32'hD251_1F53)}};
                    sec64_sink <= sec64_sink ^ sec64_noise[0] ^ sec64_noise[37] ^ sec64_noise[101] ^
                                  sec64_noise[173] ^ sec64_noise[255] ^ {31'b0, ^sec64_toggle_bank};
                    for (sec_i = 0; sec_i < 256; sec_i = sec_i + 1) begin
                        if (sec64_rng[sec_i % 32] ^ sec64_noise[sec_i][0]) begin
                            sec64_noise[sec_i] <= {sec64_noise[sec_i][30:0], sec64_noise[sec_i][31]} ^
                                                  (32'hD00D_F00D ^ (sec_i * 32'h0001_0121) ^ sec64_rng);
                        end else begin
                            sec64_noise[sec_i] <= sec64_noise[sec_i] ^ (32'h1357_9BDF + sec_i) ^ qgsp_lfsr;
                        end
                    end
                end
            end

            case (state)

                // ------------------------------------------------
                // IDLE: latch mode and load A,B for first multiply
                // ------------------------------------------------
                S_IDLE: begin
                    busy <= 1'b0;

                    if (start) begin
                        busy  <= 1'b1;
                        mode_r <= mode;

                        if (mode == 2'b00) begin
                            // 64-bit hardened entry: first drive random
                            // precharge values into the physical bank. The real
                            // operands are loaded in S_PRE64 one cycle later.
                            bank_a64[0*128 +: 128] <= {64'h0, sec64_noise[  0], sec64_noise[  1]};
                            bank_a64[1*128 +: 128] <= {64'h0, sec64_noise[  2], sec64_noise[  3]};
                            bank_a64[2*128 +: 128] <= {64'h0, sec64_noise[  4], sec64_noise[  5]};
                            bank_a64[3*128 +: 128] <= {64'h0, sec64_noise[  6], sec64_noise[  7]};
                            bank_a64[4*128 +: 128] <= {64'h0, sec64_noise[  8], sec64_noise[  9]};
                            bank_a64[5*128 +: 128] <= {64'h0, sec64_noise[ 10], sec64_noise[ 11]};
                            bank_a64[6*128 +: 128] <= {64'h0, sec64_noise[ 12], sec64_noise[ 13]};
                            bank_a64[7*128 +: 128] <= {64'h0, sec64_noise[ 14], sec64_noise[ 15]};
                            bank_a64[8*128 +: 128] <= {64'h0, sec64_noise[ 16], sec64_noise[ 17]};

                            bank_b64[0*128 +: 128] <= {64'h0, ~sec64_noise[ 18], ~sec64_noise[ 19]};
                            bank_b64[1*128 +: 128] <= {64'h0, ~sec64_noise[ 20], ~sec64_noise[ 21]};
                            bank_b64[2*128 +: 128] <= {64'h0, ~sec64_noise[ 22], ~sec64_noise[ 23]};
                            bank_b64[3*128 +: 128] <= {64'h0, ~sec64_noise[ 24], ~sec64_noise[ 25]};
                            bank_b64[4*128 +: 128] <= {64'h0, ~sec64_noise[ 26], ~sec64_noise[ 27]};
                            bank_b64[5*128 +: 128] <= {64'h0, ~sec64_noise[ 28], ~sec64_noise[ 29]};
                            bank_b64[6*128 +: 128] <= {64'h0, ~sec64_noise[ 30], ~sec64_noise[ 31]};
                            bank_b64[7*128 +: 128] <= {64'h0, ~sec64_noise[ 32], ~sec64_noise[ 33]};
                            bank_b64[8*128 +: 128] <= {64'h0, ~sec64_noise[ 34], ~sec64_noise[ 35]};

                            // Store same-cycle masks and precharge both real and
                            // complement balancing registers to the same mask.
                            // In S_PRE64, one path moves to A^r and the other
                            // to ~A^r, so their combined HD is close to constant.
                            for (sec_i = 0; sec_i < 9; sec_i = sec_i + 1) begin
                                sec64_a_mask[sec_i] <= {sec64_noise[sec_i*2], sec64_noise[sec_i*2+1]};
                                sec64_b_mask[sec_i] <= {sec64_noise[sec_i*2+36], sec64_noise[sec_i*2+37]};
                                sec64_a_real[sec_i] <= {sec64_noise[sec_i*2], sec64_noise[sec_i*2+1]};
                                sec64_a_comp[sec_i] <= {sec64_noise[sec_i*2], sec64_noise[sec_i*2+1]};
                                sec64_b_real[sec_i] <= {sec64_noise[sec_i*2+36], sec64_noise[sec_i*2+37]};
                                sec64_b_comp[sec_i] <= {sec64_noise[sec_i*2+36], sec64_noise[sec_i*2+37]};
                            end
                        end

                        else if (mode == 2'b01) begin
                            // 3 independent 128-bit BMM lanes.
                            // Each operand is zero-extended to 256 bits.
                            bank_a128[0*256 +: 256] <= {128'b0, A128[0*128 +: 128]};
                            bank_a128[1*256 +: 256] <= {128'b0, A128[1*128 +: 128]};
                            bank_a128[2*256 +: 256] <= {128'b0, A128[2*128 +: 128]};

                            bank_b128[0*256 +: 256] <= {128'b0, B128[0*128 +: 128]};
                            bank_b128[1*256 +: 256] <= {128'b0, B128[1*128 +: 128]};
                            bank_b128[2*256 +: 256] <= {128'b0, B128[2*128 +: 128]};
                        end

                        else begin
                            // One 256-bit BMM lane.
                            // Operand is zero-extended to 512 bits.
                            bank_a256 <= {256'b0, A256};
                            bank_b256 <= {256'b0, B256};
                        end

                        if (mode == 2'b00)
                            state <= S_PRE64;
                        else
                            state <= S_MUL_AB;
                    end
                end

                // ------------------------------------------------
                // 64-bit precharge completion: load real operands and
                // complementary balancing registers. This state is skipped
                // in 128-bit and 256-bit modes.
                // ------------------------------------------------
                S_PRE64: begin
                    bank_a64[0*128 +: 128] <= {64'b0, A64[0*64 +: 64]};
                    bank_a64[1*128 +: 128] <= {64'b0, A64[1*64 +: 64]};
                    bank_a64[2*128 +: 128] <= {64'b0, A64[2*64 +: 64]};
                    bank_a64[3*128 +: 128] <= {64'b0, A64[3*64 +: 64]};
                    bank_a64[4*128 +: 128] <= {64'b0, A64[4*64 +: 64]};
                    bank_a64[5*128 +: 128] <= {64'b0, A64[5*64 +: 64]};
                    bank_a64[6*128 +: 128] <= {64'b0, A64[6*64 +: 64]};
                    bank_a64[7*128 +: 128] <= {64'b0, A64[7*64 +: 64]};
                    bank_a64[8*128 +: 128] <= {64'b0, A64[8*64 +: 64]};

                    bank_b64[0*128 +: 128] <= {64'b0, B64[0*64 +: 64]};
                    bank_b64[1*128 +: 128] <= {64'b0, B64[1*64 +: 64]};
                    bank_b64[2*128 +: 128] <= {64'b0, B64[2*64 +: 64]};
                    bank_b64[3*128 +: 128] <= {64'b0, B64[3*64 +: 64]};
                    bank_b64[4*128 +: 128] <= {64'b0, B64[4*64 +: 64]};
                    bank_b64[5*128 +: 128] <= {64'b0, B64[5*64 +: 64]};
                    bank_b64[6*128 +: 128] <= {64'b0, B64[6*64 +: 64]};
                    bank_b64[7*128 +: 128] <= {64'b0, B64[7*64 +: 64]};
                    bank_b64[8*128 +: 128] <= {64'b0, B64[8*64 +: 64]};

                    for (sec_i = 0; sec_i < 9; sec_i = sec_i + 1) begin
                        // Same-mask complementary balancing. The real and
                        // complement paths are updated in the same VCD window
                        // as the physical bank load.
                        sec64_a_real[sec_i] <= (A64[sec_i*64 +: 64])  ^ sec64_a_mask[sec_i];
                        sec64_a_comp[sec_i] <= ~(A64[sec_i*64 +: 64]) ^ sec64_a_mask[sec_i];
                        sec64_b_real[sec_i] <= (B64[sec_i*64 +: 64])  ^ sec64_b_mask[sec_i];
                        sec64_b_comp[sec_i] <= ~(B64[sec_i*64 +: 64]) ^ sec64_b_mask[sec_i];
                        sec64_pseudo_prod[sec_i] <= {sec64_a_real[sec_i] ^ sec64_a_comp[sec_i],
                                                     sec64_b_real[sec_i] ^ sec64_b_comp[sec_i]} ^ {4{sec64_rng}};
                    end

                    state <= S_MUL_AB;
                end

                // ------------------------------------------------
                // Stage 1:
                //   P  = A * B
                //   PS = P >> (N - beta)
                // Prepare PS * mu
                // ------------------------------------------------
                S_MUL_AB: begin
                    if (mode_r == 2'b00) begin
                        x64_0 <= bank_p64[0*256 +: 128];
                        x64_1 <= bank_p64[1*256 +: 128];
                        x64_2 <= bank_p64[2*256 +: 128];
                        x64_3 <= bank_p64[3*256 +: 128];
                        x64_4 <= bank_p64[4*256 +: 128];
                        x64_5 <= bank_p64[5*256 +: 128];
                        x64_6 <= bank_p64[6*256 +: 128];
                        x64_7 <= bank_p64[7*256 +: 128];
                        x64_8 <= bank_p64[8*256 +: 128];

                        bank_a64[0*128 +: 128] <= bank_p64[0*256 +: 128] >> (64-BETA);
                        bank_a64[1*128 +: 128] <= bank_p64[1*256 +: 128] >> (64-BETA);
                        bank_a64[2*128 +: 128] <= bank_p64[2*256 +: 128] >> (64-BETA);
                        bank_a64[3*128 +: 128] <= bank_p64[3*256 +: 128] >> (64-BETA);
                        bank_a64[4*128 +: 128] <= bank_p64[4*256 +: 128] >> (64-BETA);
                        bank_a64[5*128 +: 128] <= bank_p64[5*256 +: 128] >> (64-BETA);
                        bank_a64[6*128 +: 128] <= bank_p64[6*256 +: 128] >> (64-BETA);
                        bank_a64[7*128 +: 128] <= bank_p64[7*256 +: 128] >> (64-BETA);
                        bank_a64[8*128 +: 128] <= bank_p64[8*256 +: 128] >> (64-BETA);

                        bank_b64 <= MU64;
                    end

                    else if (mode_r == 2'b01) begin
                        x128_0 <= bank_p128[0*512 +: 256];
                        x128_1 <= bank_p128[1*512 +: 256];
                        x128_2 <= bank_p128[2*512 +: 256];

                        bank_a128[0*256 +: 256] <= bank_p128[0*512 +: 256] >> (128-BETA);
                        bank_a128[1*256 +: 256] <= bank_p128[1*512 +: 256] >> (128-BETA);
                        bank_a128[2*256 +: 256] <= bank_p128[2*512 +: 256] >> (128-BETA);

                        bank_b128 <= MU128;
                    end

                    else begin
                        x256 <= bank_p256[511:0];

                        bank_a256 <= bank_p256[511:0] >> (256-BETA);
                        bank_b256 <= MU256;
                    end

                    state <= S_MUL_QMU;
                end

                // ------------------------------------------------
                // Stage 2:
                //   q2 = PS * mu
                //   q  = q2 >> (N + alpha + beta)
                // Prepare q * M
                // ------------------------------------------------
                S_MUL_QMU: begin
                    if (mode_r == 2'b00) begin
                        bank_a64[0*128 +: 128] <= bank_p64[0*256 +: 256] >> (64+ALPHA+BETA);
                        bank_a64[1*128 +: 128] <= bank_p64[1*256 +: 256] >> (64+ALPHA+BETA);
                        bank_a64[2*128 +: 128] <= bank_p64[2*256 +: 256] >> (64+ALPHA+BETA);
                        bank_a64[3*128 +: 128] <= bank_p64[3*256 +: 256] >> (64+ALPHA+BETA);
                        bank_a64[4*128 +: 128] <= bank_p64[4*256 +: 256] >> (64+ALPHA+BETA);
                        bank_a64[5*128 +: 128] <= bank_p64[5*256 +: 256] >> (64+ALPHA+BETA);
                        bank_a64[6*128 +: 128] <= bank_p64[6*256 +: 256] >> (64+ALPHA+BETA);
                        bank_a64[7*128 +: 128] <= bank_p64[7*256 +: 256] >> (64+ALPHA+BETA);
                        bank_a64[8*128 +: 128] <= bank_p64[8*256 +: 256] >> (64+ALPHA+BETA);

                        bank_b64[0*128 +: 128] <= {64'b0, M64[0*64 +: 64]};
                        bank_b64[1*128 +: 128] <= {64'b0, M64[1*64 +: 64]};
                        bank_b64[2*128 +: 128] <= {64'b0, M64[2*64 +: 64]};
                        bank_b64[3*128 +: 128] <= {64'b0, M64[3*64 +: 64]};
                        bank_b64[4*128 +: 128] <= {64'b0, M64[4*64 +: 64]};
                        bank_b64[5*128 +: 128] <= {64'b0, M64[5*64 +: 64]};
                        bank_b64[6*128 +: 128] <= {64'b0, M64[6*64 +: 64]};
                        bank_b64[7*128 +: 128] <= {64'b0, M64[7*64 +: 64]};
                        bank_b64[8*128 +: 128] <= {64'b0, M64[8*64 +: 64]};
                    end

                    else if (mode_r == 2'b01) begin
                        bank_a128[0*256 +: 256] <= bank_p128[0*512 +: 512] >> (128+ALPHA+BETA);
                        bank_a128[1*256 +: 256] <= bank_p128[1*512 +: 512] >> (128+ALPHA+BETA);
                        bank_a128[2*256 +: 256] <= bank_p128[2*512 +: 512] >> (128+ALPHA+BETA);

                        bank_b128[0*256 +: 256] <= {128'b0, M128[0*128 +: 128]};
                        bank_b128[1*256 +: 256] <= {128'b0, M128[1*128 +: 128]};
                        bank_b128[2*256 +: 256] <= {128'b0, M128[2*128 +: 128]};
                    end

                    else begin
                        bank_a256 <= bank_p256 >> (256+ALPHA+BETA);
                        bank_b256 <= {256'b0, M256};
                    end

                    state <= S_MUL_QM;
                end

                // ------------------------------------------------
                // Stage 3:
                //   qM = q * M
                // ------------------------------------------------
                S_MUL_QM: begin
                    if (mode_r == 2'b00) begin
                        qm64_0 <= bank_p64[0*256 +: 129];
                        qm64_1 <= bank_p64[1*256 +: 129];
                        qm64_2 <= bank_p64[2*256 +: 129];
                        qm64_3 <= bank_p64[3*256 +: 129];
                        qm64_4 <= bank_p64[4*256 +: 129];
                        qm64_5 <= bank_p64[5*256 +: 129];
                        qm64_6 <= bank_p64[6*256 +: 129];
                        qm64_7 <= bank_p64[7*256 +: 129];
                        qm64_8 <= bank_p64[8*256 +: 129];
                    end

                    else if (mode_r == 2'b01) begin
                        qm128_0 <= bank_p128[0*512 +: 257];
                        qm128_1 <= bank_p128[1*512 +: 257];
                        qm128_2 <= bank_p128[2*512 +: 257];
                    end

                    else begin
                        qm256 <= bank_p256[512:0];
                    end

                    state <= S_REDUCE;
                end

                // ------------------------------------------------
                // Final reduction:
                //   Z = P - qM
                //   correction by subtracting M
                // ------------------------------------------------
                S_REDUCE: begin
                    if (mode_r == 2'b00) begin
                        P64[0*64 +: 64] <= reduce64_alg2(x64_0, qm64_0, M64[0*64 +: 64]);
                        P64[1*64 +: 64] <= reduce64_alg2(x64_1, qm64_1, M64[1*64 +: 64]);
                        P64[2*64 +: 64] <= reduce64_alg2(x64_2, qm64_2, M64[2*64 +: 64]);
                        P64[3*64 +: 64] <= reduce64_alg2(x64_3, qm64_3, M64[3*64 +: 64]);
                        P64[4*64 +: 64] <= reduce64_alg2(x64_4, qm64_4, M64[4*64 +: 64]);
                        P64[5*64 +: 64] <= reduce64_alg2(x64_5, qm64_5, M64[5*64 +: 64]);
                        P64[6*64 +: 64] <= reduce64_alg2(x64_6, qm64_6, M64[6*64 +: 64]);
                        P64[7*64 +: 64] <= reduce64_alg2(x64_7, qm64_7, M64[7*64 +: 64]);
                        P64[8*64 +: 64] <= reduce64_alg2(x64_8, qm64_8, M64[8*64 +: 64]);
                    end

                    else if (mode_r == 2'b01) begin
                        P128[0*128 +: 128] <= reduce128_alg2(x128_0, qm128_0, M128[0*128 +: 128]);
                        P128[1*128 +: 128] <= reduce128_alg2(x128_1, qm128_1, M128[1*128 +: 128]);
                        P128[2*128 +: 128] <= reduce128_alg2(x128_2, qm128_2, M128[2*128 +: 128]);
                    end

                    else begin
                        P256 <= reduce256_alg2(x256, qm256, M256);
                    end

                    done_mode <= mode_r;
                    state <= S_DONE;
                end

                // ------------------------------------------------
                // DONE
                // ------------------------------------------------
                S_DONE: begin
                    done  <= 1'b1;
                    busy  <= 1'b0;
                    state <= S_IDLE;
                end

                default: begin
                    state <= S_IDLE;
                end

            endcase
        end
    end

endmodule


// ================================================================
// Reconfigurable 9-core multiplier bank
//
// Contains exactly:
//      9 physical 128-bit multiplier cores
//
// mode = 00:
//      9 independent 128-bit multipliers
//
// mode = 01:
//      3 independent 256-bit Karatsuba multipliers
//
// mode = 10:
//      1 independent 512-bit Karatsuba multiplier
//
// ================================================================

(* use_dsp = "no" *)
module rbmm_bank_9core_qgsp (
    input  wire [1:0] mode,
    input  wire [1:0] perm_sel,

    input  wire [9*128-1:0]  a64,
    input  wire [9*128-1:0]  b64,
    output wire [9*256-1:0]  p64,

    input  wire [3*256-1:0]  a128,
    input  wire [3*256-1:0]  b128,
    output wire [3*512-1:0]  p128,

    input  wire [511:0]      a256,
    input  wire [511:0]      b256,
    output wire [1023:0]     p256
);

    wire [127:0] ca0, ca1, ca2, ca3, ca4, ca5, ca6, ca7, ca8;
    wire [127:0] cb0, cb1, cb2, cb3, cb4, cb5, cb6, cb7, cb8;

    wire [255:0] cp0, cp1, cp2, cp3, cp4, cp5, cp6, cp7, cp8;

    function [127:0] absdiff128;
        input [127:0] x;
        input [127:0] y;
        begin
            absdiff128 = (x >= y) ? (x - y) : (y - x);
        end
    endfunction

    function [255:0] absdiff256;
        input [255:0] x;
        input [255:0] y;
        begin
            absdiff256 = (x >= y) ? (x - y) : (y - x);
        end
    endfunction

    function [511:0] combine256;
        input sign_a;
        input sign_b;
        input [255:0] z0;
        input [255:0] z2;
        input [255:0] zd;

        reg [256:0] middle;
        reg [511:0] temp;

        begin
            if (sign_a == sign_b)
                middle = {1'b0, z0} + {1'b0, z2} - {1'b0, zd};
            else
                middle = {1'b0, z0} + {1'b0, z2} + {1'b0, zd};

            temp = {256'b0, z0};
            temp = temp + ({255'b0, middle} << 128);
            temp = temp + ({z2, 256'b0});

            combine256 = temp;
        end
    endfunction

    function [1023:0] combine512;
        input sign_a;
        input sign_b;
        input [511:0] z0;
        input [511:0] z2;
        input [511:0] zd;

        reg [512:0] middle;
        reg [1023:0] temp;

        begin
            if (sign_a == sign_b)
                middle = {1'b0, z0} + {1'b0, z2} - {1'b0, zd};
            else
                middle = {1'b0, z0} + {1'b0, z2} + {1'b0, zd};

            temp = {512'b0, z0};
            temp = temp + ({511'b0, middle} << 256);
            temp = temp + ({z2, 512'b0});

            combine512 = temp;
        end
    endfunction

    wire [255:0] a256_l = a256[255:0];
    wire [255:0] a256_h = a256[511:256];

    wire [255:0] b256_l = b256[255:0];
    wire [255:0] b256_h = b256[511:256];

    wire [255:0] da256 = absdiff256(a256_h, a256_l);
    wire [255:0] db256 = absdiff256(b256_h, b256_l);

    wire [255:0] a128_0 = a128[0*256 +: 256];
    wire [255:0] a128_1 = a128[1*256 +: 256];
    wire [255:0] a128_2 = a128[2*256 +: 256];

    wire [255:0] b128_0 = b128[0*256 +: 256];
    wire [255:0] b128_1 = b128[1*256 +: 256];
    wire [255:0] b128_2 = b128[2*256 +: 256];

    assign ca0 = (mode == 2'b00) ? a64[0*128 +: 128] :
                 (mode == 2'b01) ? a128_0[127:0] :
                                    a256_l[127:0];

    assign cb0 = (mode == 2'b00) ? b64[0*128 +: 128] :
                 (mode == 2'b01) ? b128_0[127:0] :
                                    b256_l[127:0];

    assign ca1 = (mode == 2'b00) ? a64[1*128 +: 128] :
                 (mode == 2'b01) ? a128_0[255:128] :
                                    a256_l[255:128];

    assign cb1 = (mode == 2'b00) ? b64[1*128 +: 128] :
                 (mode == 2'b01) ? b128_0[255:128] :
                                    b256_l[255:128];

    assign ca2 = (mode == 2'b00) ? a64[2*128 +: 128] :
                 (mode == 2'b01) ? absdiff128(a128_0[255:128], a128_0[127:0]) :
                                    absdiff128(a256_l[255:128], a256_l[127:0]);

    assign cb2 = (mode == 2'b00) ? b64[2*128 +: 128] :
                 (mode == 2'b01) ? absdiff128(b128_0[255:128], b128_0[127:0]) :
                                    absdiff128(b256_l[255:128], b256_l[127:0]);

    assign ca3 = (mode == 2'b00) ? a64[3*128 +: 128] :
                 (mode == 2'b01) ? a128_1[127:0] :
                                    a256_h[127:0];

    assign cb3 = (mode == 2'b00) ? b64[3*128 +: 128] :
                 (mode == 2'b01) ? b128_1[127:0] :
                                    b256_h[127:0];

    assign ca4 = (mode == 2'b00) ? a64[4*128 +: 128] :
                 (mode == 2'b01) ? a128_1[255:128] :
                                    a256_h[255:128];

    assign cb4 = (mode == 2'b00) ? b64[4*128 +: 128] :
                 (mode == 2'b01) ? b128_1[255:128] :
                                    b256_h[255:128];

    assign ca5 = (mode == 2'b00) ? a64[5*128 +: 128] :
                 (mode == 2'b01) ? absdiff128(a128_1[255:128], a128_1[127:0]) :
                                    absdiff128(a256_h[255:128], a256_h[127:0]);

    assign cb5 = (mode == 2'b00) ? b64[5*128 +: 128] :
                 (mode == 2'b01) ? absdiff128(b128_1[255:128], b128_1[127:0]) :
                                    absdiff128(b256_h[255:128], b256_h[127:0]);

    assign ca6 = (mode == 2'b00) ? a64[6*128 +: 128] :
                 (mode == 2'b01) ? a128_2[127:0] :
                                    da256[127:0];

    assign cb6 = (mode == 2'b00) ? b64[6*128 +: 128] :
                 (mode == 2'b01) ? b128_2[127:0] :
                                    db256[127:0];

    assign ca7 = (mode == 2'b00) ? a64[7*128 +: 128] :
                 (mode == 2'b01) ? a128_2[255:128] :
                                    da256[255:128];

    assign cb7 = (mode == 2'b00) ? b64[7*128 +: 128] :
                 (mode == 2'b01) ? b128_2[255:128] :
                                    db256[255:128];

    assign ca8 = (mode == 2'b00) ? a64[8*128 +: 128] :
                 (mode == 2'b01) ? absdiff128(a128_2[255:128], a128_2[127:0]) :
                                    absdiff128(da256[255:128], da256[127:0]);

    assign cb8 = (mode == 2'b00) ? b64[8*128 +: 128] :
                 (mode == 2'b01) ? absdiff128(b128_2[255:128], b128_2[127:0]) :
                                    absdiff128(db256[255:128], db256[127:0]);

    // ------------------------------------------------------------
    // QGSP logical-to-physical permutation layer.
    // The mathematical operation is unchanged because the inverse
    // permutation below maps physical results back to logical slots.
    // ------------------------------------------------------------
    wire [127:0] la [0:8];
    wire [127:0] lb [0:8];
    wire [255:0] lp [0:8];
    wire [127:0] pa0, pa1, pa2, pa3, pa4, pa5, pa6, pa7, pa8;
    wire [127:0] pb0, pb1, pb2, pb3, pb4, pb5, pb6, pb7, pb8;

    assign la[0]=ca0; assign la[1]=ca1; assign la[2]=ca2;
    assign la[3]=ca3; assign la[4]=ca4; assign la[5]=ca5;
    assign la[6]=ca6; assign la[7]=ca7; assign la[8]=ca8;

    assign lb[0]=cb0; assign lb[1]=cb1; assign lb[2]=cb2;
    assign lb[3]=cb3; assign lb[4]=cb4; assign lb[5]=cb5;
    assign lb[6]=cb6; assign lb[7]=cb7; assign lb[8]=cb8;

    assign pa0 = (perm_sel==2'd0) ? la[0] : (perm_sel==2'd1) ? la[1] : (perm_sel==2'd2) ? la[3] : la[8];
    assign pa1 = (perm_sel==2'd0) ? la[1] : (perm_sel==2'd1) ? la[2] : (perm_sel==2'd2) ? la[4] : la[7];
    assign pa2 = (perm_sel==2'd0) ? la[2] : (perm_sel==2'd1) ? la[3] : (perm_sel==2'd2) ? la[5] : la[6];
    assign pa3 = (perm_sel==2'd0) ? la[3] : (perm_sel==2'd1) ? la[4] : (perm_sel==2'd2) ? la[6] : la[5];
    assign pa4 = (perm_sel==2'd0) ? la[4] : (perm_sel==2'd1) ? la[5] : (perm_sel==2'd2) ? la[7] : la[4];
    assign pa5 = (perm_sel==2'd0) ? la[5] : (perm_sel==2'd1) ? la[6] : (perm_sel==2'd2) ? la[8] : la[3];
    assign pa6 = (perm_sel==2'd0) ? la[6] : (perm_sel==2'd1) ? la[7] : (perm_sel==2'd2) ? la[0] : la[2];
    assign pa7 = (perm_sel==2'd0) ? la[7] : (perm_sel==2'd1) ? la[8] : (perm_sel==2'd2) ? la[1] : la[1];
    assign pa8 = (perm_sel==2'd0) ? la[8] : (perm_sel==2'd1) ? la[0] : (perm_sel==2'd2) ? la[2] : la[0];

    assign pb0 = (perm_sel==2'd0) ? lb[0] : (perm_sel==2'd1) ? lb[1] : (perm_sel==2'd2) ? lb[3] : lb[8];
    assign pb1 = (perm_sel==2'd0) ? lb[1] : (perm_sel==2'd1) ? lb[2] : (perm_sel==2'd2) ? lb[4] : lb[7];
    assign pb2 = (perm_sel==2'd0) ? lb[2] : (perm_sel==2'd1) ? lb[3] : (perm_sel==2'd2) ? lb[5] : lb[6];
    assign pb3 = (perm_sel==2'd0) ? lb[3] : (perm_sel==2'd1) ? lb[4] : (perm_sel==2'd2) ? lb[6] : lb[5];
    assign pb4 = (perm_sel==2'd0) ? lb[4] : (perm_sel==2'd1) ? lb[5] : (perm_sel==2'd2) ? lb[7] : lb[4];
    assign pb5 = (perm_sel==2'd0) ? lb[5] : (perm_sel==2'd1) ? lb[6] : (perm_sel==2'd2) ? lb[8] : lb[3];
    assign pb6 = (perm_sel==2'd0) ? lb[6] : (perm_sel==2'd1) ? lb[7] : (perm_sel==2'd2) ? lb[0] : lb[2];
    assign pb7 = (perm_sel==2'd0) ? lb[7] : (perm_sel==2'd1) ? lb[8] : (perm_sel==2'd2) ? lb[1] : lb[1];
    assign pb8 = (perm_sel==2'd0) ? lb[8] : (perm_sel==2'd1) ? lb[0] : (perm_sel==2'd2) ? lb[2] : lb[0];

    // Inverse mapping: lp[k] is product for logical slot k.
    assign lp[0] = (perm_sel==2'd0) ? cp0 : (perm_sel==2'd1) ? cp8 : (perm_sel==2'd2) ? cp6 : cp8;
    assign lp[1] = (perm_sel==2'd0) ? cp1 : (perm_sel==2'd1) ? cp0 : (perm_sel==2'd2) ? cp7 : cp7;
    assign lp[2] = (perm_sel==2'd0) ? cp2 : (perm_sel==2'd1) ? cp1 : (perm_sel==2'd2) ? cp8 : cp6;
    assign lp[3] = (perm_sel==2'd0) ? cp3 : (perm_sel==2'd1) ? cp2 : (perm_sel==2'd2) ? cp0 : cp5;
    assign lp[4] = (perm_sel==2'd0) ? cp4 : (perm_sel==2'd1) ? cp3 : (perm_sel==2'd2) ? cp1 : cp4;
    assign lp[5] = (perm_sel==2'd0) ? cp5 : (perm_sel==2'd1) ? cp4 : (perm_sel==2'd2) ? cp2 : cp3;
    assign lp[6] = (perm_sel==2'd0) ? cp6 : (perm_sel==2'd1) ? cp5 : (perm_sel==2'd2) ? cp3 : cp2;
    assign lp[7] = (perm_sel==2'd0) ? cp7 : (perm_sel==2'd1) ? cp6 : (perm_sel==2'd2) ? cp4 : cp1;
    assign lp[8] = (perm_sel==2'd0) ? cp8 : (perm_sel==2'd1) ? cp7 : (perm_sel==2'd2) ? cp5 : cp0;

    // 9 physical 128-bit multiplier cores
    mult #(128, 4, 32) u0 (.A({1'b0, pa0}), .B({1'b0, pb0}), .P(cp0));
    mult #(128, 4, 32) u1 (.A({1'b0, pa1}), .B({1'b0, pb1}), .P(cp1));
    mult #(128, 4, 32) u2 (.A({1'b0, pa2}), .B({1'b0, pb2}), .P(cp2));
    mult #(128, 4, 32) u3 (.A({1'b0, pa3}), .B({1'b0, pb3}), .P(cp3));
    mult #(128, 4, 32) u4 (.A({1'b0, pa4}), .B({1'b0, pb4}), .P(cp4));
    mult #(128, 4, 32) u5 (.A({1'b0, pa5}), .B({1'b0, pb5}), .P(cp5));
    mult #(128, 4, 32) u6 (.A({1'b0, pa6}), .B({1'b0, pb6}), .P(cp6));
    mult #(128, 4, 32) u7 (.A({1'b0, pa7}), .B({1'b0, pb7}), .P(cp7));
    mult #(128, 4, 32) u8 (.A({1'b0, pa8}), .B({1'b0, pb8}), .P(cp8));

    assign p64[0*256 +: 256] = lp[0];
    assign p64[1*256 +: 256] = lp[1];
    assign p64[2*256 +: 256] = lp[2];
    assign p64[3*256 +: 256] = lp[3];
    assign p64[4*256 +: 256] = lp[4];
    assign p64[5*256 +: 256] = lp[5];
    assign p64[6*256 +: 256] = lp[6];
    assign p64[7*256 +: 256] = lp[7];
    assign p64[8*256 +: 256] = lp[8];

    assign p128[0*512 +: 512] = combine256(
        a128_0[255:128] >= a128_0[127:0],
        b128_0[255:128] >= b128_0[127:0],
        lp[0], lp[1], lp[2]
    );

    assign p128[1*512 +: 512] = combine256(
        a128_1[255:128] >= a128_1[127:0],
        b128_1[255:128] >= b128_1[127:0],
        lp[3], lp[4], lp[5]
    );

    assign p128[2*512 +: 512] = combine256(
        a128_2[255:128] >= a128_2[127:0],
        b128_2[255:128] >= b128_2[127:0],
        lp[6], lp[7], lp[8]
    );

    wire [511:0] z0_512;
    wire [511:0] z2_512;
    wire [511:0] zd_512;

    assign z0_512 = combine256(
        a256_l[255:128] >= a256_l[127:0],
        b256_l[255:128] >= b256_l[127:0],
        lp[0], lp[1], lp[2]
    );

    assign z2_512 = combine256(
        a256_h[255:128] >= a256_h[127:0],
        b256_h[255:128] >= b256_h[127:0],
        lp[3], lp[4], lp[5]
    );

    assign zd_512 = combine256(
        da256[255:128] >= da256[127:0],
        db256[255:128] >= db256[127:0],
        lp[6], lp[7], lp[8]
    );

    assign p256 = combine512(
        a256_h >= a256_l,
        b256_h >= b256_l,
        z0_512,
        z2_512,
        zd_512
    );

endmodule


// ================================================================
// 128-bit matrix/Karatsuba multiplier core
// Uses 4-term decomposition and 9 small Booth multipliers.
// ================================================================

(* use_dsp = "no" *)
module mult #(
    parameter N = 128,
    parameter k = 4,
    parameter m = 32
)(
    input  [N:0]       A,
    input  [N:0]       B,
    output reg [2*N-1:0] P
);

    localparam W = N/k;

    reg [N-1:0] A_reg;
    reg [N-1:0] B_reg;

    reg sign_a;
    reg sign_b;
    reg sign;

    reg [W-1:0] A0, A1, A2, A3;
    reg [W-1:0] B0, B1, B2, B3;

    wire signed [W+1:0] aa0, aa1, aa2, aa3, aa4, aa5, aa6, aa7, aa8;
    wire signed [W+1:0] bb0, bb1, bb2, bb3, bb4, bb5, bb6, bb7, bb8;

    wire signed [2*W+3:0] e0, e1, e2, e3, e4, e5, e6, e7, e8;

    reg signed [2*W+4:0] c0, c1, c2, c3, c4, c5, c6;

    reg [2*N-1:0] temp0;
    reg [2*N-1:0] temp1;
    reg [2*N-1:0] temp2;
    reg [2*N-1:0] temp3;
    reg [2*N-1:0] temp4;
    reg [2*N-1:0] temp5;
    reg [2*N-1:0] temp6;

    assign aa0 = $signed({1'b0, A0});
    assign aa1 = $signed({1'b0, A1});
    assign aa2 = $signed({1'b0, A2});
    assign aa3 = $signed({1'b0, A3});

    assign aa4 = $signed({1'b0, A0}) - $signed({1'b0, A2});
    assign aa5 = $signed({1'b0, A0}) - $signed({1'b0, A1});
    assign aa6 = $signed({1'b0, A0}) - $signed({1'b0, A1}) - $signed({1'b0, A2}) + $signed({1'b0, A3});
    assign aa7 = $signed({1'b0, A1}) - $signed({1'b0, A3});
    assign aa8 = $signed({1'b0, A2}) - $signed({1'b0, A3});

    assign bb0 = $signed({1'b0, B0});
    assign bb1 = $signed({1'b0, B1});
    assign bb2 = $signed({1'b0, B2});
    assign bb3 = $signed({1'b0, B3});

    assign bb4 = $signed({1'b0, B2}) - $signed({1'b0, B0});
    assign bb5 = $signed({1'b0, B1}) - $signed({1'b0, B0});
    assign bb6 = $signed({1'b0, B0}) - $signed({1'b0, B1}) - $signed({1'b0, B2}) + $signed({1'b0, B3});
    assign bb7 = $signed({1'b0, B3}) - $signed({1'b0, B1});
    assign bb8 = $signed({1'b0, B3}) - $signed({1'b0, B2});

    booth #(W+2) inst0 (aa0, bb0, e0);
    booth #(W+2) inst1 (aa1, bb1, e1);
    booth #(W+2) inst2 (aa2, bb2, e2);
    booth #(W+2) inst3 (aa3, bb3, e3);
    booth #(W+2) inst4 (aa4, bb4, e4);
    booth #(W+2) inst5 (aa5, bb5, e5);
    booth #(W+2) inst6 (aa6, bb6, e6);
    booth #(W+2) inst7 (aa7, bb7, e7);
    booth #(W+2) inst8 (aa8, bb8, e8);

    always @(*) begin
        sign_a = 1'b0;
        sign_b = 1'b0;
        sign   = 1'b0;

        A_reg = A[N-1:0];
        B_reg = B[N-1:0];

        if (A[N] == 1'b1) begin
            sign_a = 1'b1;
            A_reg = (~A[N-1:0]) + 1'b1;
        end

        if (B[N] == 1'b1) begin
            sign_b = 1'b1;
            B_reg = (~B[N-1:0]) + 1'b1;
        end

        sign = sign_a ^ sign_b;

        A0 = A_reg[W-1:0];
        A1 = A_reg[2*W-1:W];
        A2 = A_reg[3*W-1:2*W];
        A3 = A_reg[4*W-1:3*W];

        B0 = B_reg[W-1:0];
        B1 = B_reg[2*W-1:W];
        B2 = B_reg[3*W-1:2*W];
        B3 = B_reg[4*W-1:3*W];

        c0 = e0;
        c1 = e0 + e1 + e5;
        c2 = e0 + e1 + e2 + e4;
        c3 = e0 + e1 + e2 + e3 + e4 + e5 + e6 + e7 + e8;
        c4 = e1 + e2 + e3 + e7;
        c5 = e2 + e3 + e8;
        c6 = e3;

        temp0 = {{(2*N-(2*W+5)){c0[2*W+4]}}, c0};
        temp1 = {{(2*N-(2*W+5)){c1[2*W+4]}}, c1} << W;
        temp2 = {{(2*N-(2*W+5)){c2[2*W+4]}}, c2} << (2*W);
        temp3 = {{(2*N-(2*W+5)){c3[2*W+4]}}, c3} << (3*W);
        temp4 = {{(2*N-(2*W+5)){c4[2*W+4]}}, c4} << (4*W);
        temp5 = {{(2*N-(2*W+5)){c5[2*W+4]}}, c5} << (5*W);
        temp6 = {{(2*N-(2*W+5)){c6[2*W+4]}}, c6} << (6*W);

        P = temp0 + temp1 + temp2 + temp3 + temp4 + temp5 + temp6;

        if (sign == 1'b1)
            P = (~P) + 1'b1;
    end

endmodule

(* use_dsp = "no" *)
module booth #(
    parameter N = 33
)(
    input  signed [N-1:0] A,
    input  signed [N-1:0] B,
    output reg signed [2*N-1:0] P
);

    localparam NE = (N % 2 == 0) ? N : (N + 1);

    integer i;

    reg signed [NE-1:0] A_ext;
    reg signed [NE-1:0] B_ext;

    reg signed [2*NE:0] acc;
    reg signed [2*NE:0] A_big;

    reg [NE:0] booth_bits;

    always @(*) begin
        A_ext = {{(NE-N){A[N-1]}}, A};
        B_ext = {{(NE-N){B[N-1]}}, B};

        A_big = {{(NE+1){A_ext[NE-1]}}, A_ext};

        acc = {((2*NE)+1){1'b0}};

        booth_bits = {B_ext, 1'b0};

        for (i = 0; i < NE/2; i = i + 1) begin
            case (booth_bits[2*i +: 3])

                3'b000,
                3'b111: begin
                    acc = acc;
                end

                3'b001,
                3'b010: begin
                    acc = acc + (A_big <<< (2*i));
                end

                3'b011: begin
                    acc = acc + (A_big <<< (2*i + 1));
                end

                3'b100: begin
                    acc = acc - (A_big <<< (2*i + 1));
                end

                3'b101,
                3'b110: begin
                    acc = acc - (A_big <<< (2*i));
                end

                default: begin
                    acc = acc;
                end

            endcase
        end

        P = acc[2*N-1:0];
    end

endmodule
