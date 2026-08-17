`timescale 1ns/1ps
//==================================================================
//  tb_rbmm_qgsp_sca.v
//  Self-checking SCA testbench for the Reconfigurable BMM (rbmm).
//   - N_TRACES modular multiplications
//   - FIXED group : A constant, B random
//     RANDOM group: A random,   B random
//   - Per-op trigger pulse for VCD segmentation
//   - Operand log for QIF labels
//==================================================================

module tb_rbmm_qgsp_sca;

    //--------------------------------------------------------------
    // ★ Compile-time switches — change per run ★
    //--------------------------------------------------------------
    parameter integer N        = 256;
    parameter integer N_TRACES = 50_000;
    parameter integer SEED     = 32'hC0FFEE;
    parameter integer FIXED_A  = 0;
    parameter integer SEC64_TOGGLE_BITS = 8192;
    parameter         VCDFILE  = "traces/traces_random_N256.vcd";
    parameter         OPFILE   = "traces/operands_random_N256.txt";

    string vcdfile_runtime;
    string opfile_runtime;

    // Matches DUT
    localparam ALPHA = 7;

    //--------------------------------------------------------------
    // DUT I/O — exact match to module rbmm(...)
    //--------------------------------------------------------------
    reg          clk = 0;
    reg          rst = 1;
    reg          start = 0;
    reg  [1:0]   mode;

    reg  [9*64-1:0]   A64,  B64,  M64;
    reg  [9*128-1:0]  MU64;
    reg  [3*128-1:0]  A128, B128, M128;
    reg  [3*256-1:0]  MU128;
    reg  [255:0]      A256, B256, M256;
    reg  [511:0]      MU256;

    wire             busy, done;
    wire [1:0]       done_mode;
    wire [9*64-1:0]  P64;
    wire [3*128-1:0] P128;
    wire [255:0]     P256;

    // SCA segmentation trigger
    reg trigger = 0;

    // 100 MHz clock
    always #5 clk = ~clk;

    //--------------------------------------------------------------
    // DUT instantiation
    //--------------------------------------------------------------
    rbmm_qgsp #(
        .SEC64_TOGGLE_BITS(SEC64_TOGGLE_BITS)
    ) dut (
        .clk(clk), .rst(rst), .start(start), .mode(mode),
        .A64 (A64 ), .B64 (B64 ), .M64 (M64 ), .MU64 (MU64 ),
        .A128(A128), .B128(B128), .M128(M128), .MU128(MU128),
        .A256(A256), .B256(B256), .M256(M256), .MU256(MU256),
        .busy(busy), .done(done), .done_mode(done_mode),
        .P64(P64), .P128(P128), .P256(P256)
    );

    //--------------------------------------------------------------
    // VCD dump
    //--------------------------------------------------------------
    initial begin
        if (!$value$plusargs("VCDFILE=%s", vcdfile_runtime)) begin
            vcdfile_runtime = VCDFILE;
        end
        if (!$value$plusargs("OPFILE=%s", opfile_runtime)) begin
            opfile_runtime = OPFILE;
        end
        $dumpfile(vcdfile_runtime);
        // Dump once from the testbench root. This includes the DUT hierarchy
        // and avoids duplicate-scope VCD warnings in Icarus Verilog.
        $dumpvars(0, tb_rbmm_qgsp_sca);
        // For a smaller VCD, replace the previous line with the specific regs:
        // $dumpvars(0, dut.state, dut.bank_a64, dut.bank_b64,
        //              dut.x64_0, dut.qm64_0, dut.P64);
    end

    //--------------------------------------------------------------
    // Reference model
    //--------------------------------------------------------------
    function [255:0] ref_modmul;
        input [255:0] a, b, m;
        reg [511:0] p;
        begin
            p          = a * b;
            ref_modmul = p % m;
        end
    endfunction

    // µ = floor(2^(2N + ALPHA) / M)   (TB-only, wide division is OK)
    function [511:0] compute_mu;
        input [255:0] m;
        input integer Nw;
        reg [1023:0] num;
        begin
            num = 1024'd1;
            num = num << (2*Nw + ALPHA);
            compute_mu = num / m;
        end
    endfunction

    //--------------------------------------------------------------
    // Per-mode constants
    //--------------------------------------------------------------
    reg [63:0]   M_N64;
    reg [127:0]  M_N128;
    reg [255:0]  M_N256;
    reg [127:0]  MU_N64;
    reg [255:0]  MU_N128;
    reg [511:0]  MU_N256;
    reg [511:0]  tmp_mu;

    initial begin
        // Known primes (top-bit set so M >= 2^(N-1))
        M_N64  = 64'hFFFFFFFFFFFFFFC5;                                          // 2^64  - 59
        M_N128 = 128'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF61;                         // 2^128 - 159
        M_N256 = 256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFE43; // 2^256 - 445

        tmp_mu = compute_mu({192'b0, M_N64}, 64);   MU_N64  = tmp_mu[127:0];
        tmp_mu = compute_mu({128'b0, M_N128}, 128); MU_N128 = tmp_mu[255:0];
        MU_N256 = compute_mu(M_N256, 256);
    end

    //--------------------------------------------------------------
    // 256-bit random helper (uses Verilog $random, seeded)
    //--------------------------------------------------------------
    integer seed_var;
    function [255:0] rand256;
        input integer dummy;
        reg [255:0] r;
        begin
            r[ 31:  0] = $random(seed_var);
            r[ 63: 32] = $random(seed_var);
            r[ 95: 64] = $random(seed_var);
            r[127: 96] = $random(seed_var);
            r[159:128] = $random(seed_var);
            r[191:160] = $random(seed_var);
            r[223:192] = $random(seed_var);
            r[255:224] = $random(seed_var);
            rand256    = r;
        end
    endfunction

    //--------------------------------------------------------------
    // Main stimulus
    //--------------------------------------------------------------
    integer       i, k;
    integer       errors;
    integer       opfile_fh;
 reg [255:0]   A_op, B_op, A_rand, A_fixed, M_curr, mask_N;
    reg [255:0]   expected_Z, actual_Z;

    initial begin
        errors   = 0;
        seed_var = SEED;

        // pick mode encoding
        mode = (N == 64)  ? 2'b00 :
               (N == 128) ? 2'b01 : 2'b10;

        // pick reference M and operand mask for golden model
        if (N == 64) begin
            M_curr = {192'b0, M_N64};
            mask_N = {192'b0, {64{1'b1}}};
        end else if (N == 128) begin
            M_curr = {128'b0, M_N128};
            mask_N = {128'b0, {128{1'b1}}};
        end else begin
            M_curr = M_N256;
            mask_N = {256{1'b1}};
        end

        // safe defaults on all input ports
        A64=0; B64=0; M64=0; MU64=0;
        A128=0; B128=0; M128=0; MU128=0;
        A256=0; B256=0; M256=0; MU256=0;
        start=0; trigger=0;

        repeat (5) @(posedge clk);
        rst = 0;
        repeat (3) @(posedge clk);

        // FIXED A operand (chosen once)
        A_fixed = (rand256(0) & mask_N) % M_curr;

        // preload M and µ into ALL parallel lanes for the chosen mode
        if (N == 64) begin
            for (k = 0; k < 9; k = k + 1) begin
                M64 [k*64  +: 64 ] = M_N64;
                MU64[k*128 +: 128] = MU_N64;
            end
        end else if (N == 128) begin
            for (k = 0; k < 3; k = k + 1) begin
                M128 [k*128 +: 128] = M_N128;
                MU128[k*256 +: 256] = MU_N128;
            end
        end else begin
            M256  = M_N256;
            MU256 = MU_N256;
        end

        if (opfile_runtime == "") begin
            if (!$value$plusargs("OPFILE=%s", opfile_runtime)) begin
                opfile_runtime = OPFILE;
            end
        end
        opfile_fh = $fopen(opfile_runtime, "w");
        if (opfile_fh == 0) $display("[TB][WARN] could not open %s", opfile_runtime);

        $display("[TB] N=%0d  FIXED_A=%0d  N_TRACES=%0d  VCD=%s",
                  N, FIXED_A, N_TRACES, vcdfile_runtime);

        // ===========================================================
        //                 Main loop : N_TRACES ops
        // ===========================================================
        for (i = 0; i < N_TRACES; i = i + 1) begin
            // pick operands
            A_rand = (rand256(0) & mask_N) % M_curr;

		if (FIXED_A) 
			A_op = A_fixed;
		else         
			A_op = A_rand;

		B_op = (rand256(0) & mask_N) % M_curr;

            // broadcast operands to all lanes (so all multiplier cores leak)
            if (N == 64) begin
                for (k = 0; k < 9; k = k + 1) begin
                    A64[k*64 +: 64] = A_op[63:0];
                    B64[k*64 +: 64] = B_op[63:0];
                end
            end else if (N == 128) begin
                for (k = 0; k < 3; k = k + 1) begin
                    A128[k*128 +: 128] = A_op[127:0];
                    B128[k*128 +: 128] = B_op[127:0];
                end
            end else begin
                A256 = A_op;
                B256 = B_op;
            end

            // log operands so Python can compute HW(A*B mod 2^N) for QIF
            $fwrite(opfile_fh, "%h %h\n", A_op, B_op);

            // ★ TRIGGER & START ★
            @(posedge clk);
            trigger = 1'b1;
            start   = 1'b1;
            @(posedge clk);
            trigger = 1'b0;
            start   = 1'b0;

            // wait until DUT finishes
            wait (done == 1'b1);
            @(posedge clk);

            // grab result from lane 0 of the active mode
            if      (N == 64 ) actual_Z = {192'b0, P64 [0*64  +: 64 ]};
            else if (N == 128) actual_Z = {128'b0, P128[0*128 +: 128]};
            else               actual_Z = P256;

            // self-check
            expected_Z = ref_modmul(A_op, B_op, M_curr);
            if (actual_Z !== expected_Z) begin
                errors = errors + 1;
                if (errors < 5) begin
                    $display("[TB][ERR] i=%0d A=%h B=%h got=%h exp=%h",
                             i, A_op, B_op, actual_Z, expected_Z);
                end
            end

            if ((i % 5000) == 0)
                $display("[TB] %0d / %0d   errors=%0d", i, N_TRACES, errors);
        end

        $fclose(opfile_fh);
        $display("[TB] DONE.  errors = %0d / %0d", errors, N_TRACES);
        if (errors == 0) $display("[TB] >>> SELF-CHECK PASSED <<<");
        else             $display("[TB] >>> SELF-CHECK FAILED <<<");
        $finish;
    end

    // safety timeout: 50k ops × ~6 cycles × 10 ns ≈ 3 ms; give 50 ms.
    initial begin
        #(N_TRACES * 1000);
        $display("[TB] TIMEOUT @ time %0t", $time);
        $finish;
    end

endmodule
