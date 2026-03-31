`timescale 1ns/1ps

// ============================================================================
//  sha512_tb.sv  ─  Functional testbench for sha512_top
//
//  Reads two pre-padded 1024-bit message blocks from "input_vectors.hex",
//  loads them via the 32-bit CPU bus, waits for intr_o, then reads and
//  checks the 512-bit digest.
//
//  ─── Address map (sha512_top) ─────────────────────────────────────────────
//  0x00-0x1F  message schedule  addr[4:1]=word-index, addr[0]=0→low/1→high
//  0x20       control           write: bit0=start, bit1=init
//  0x21       status             read:  bit0=ready
//  0x22-0x31  digest H[0..7]   same addr[0] half-word convention
// ============================================================================

import sha512_pkg::*;

module testbench;

    // ------------------------------------------------------------------ //
    //  1.  DUT Signals                                                   //
    // ------------------------------------------------------------------ //
    logic        clk;
    logic        rst_n;
    logic [6:0]  addr_i;
    logic        wr_en_i;
    logic [31:0] wdata_i;
    logic [31:0] rdata_o;
    logic        intr_o;

    // ------------------------------------------------------------------ //
    //  2.  DUT Instance                                                  //
    // ------------------------------------------------------------------ //
    sha512_top dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .addr_i  (addr_i),
        .wr_en_i (wr_en_i),
        .wdata_i (wdata_i),
        .rdata_o (rdata_o),
        .intr_o  (intr_o)
    );

    // ------------------------------------------------------------------ //
    //  3.  Clock  ─  100 MHz (10 ns period)                              //
    // ------------------------------------------------------------------ //
    localparam real HALF = 5.0;
    initial  clk = 1'b0;
    always  #HALF clk = ~clk;

    // ------------------------------------------------------------------ //
    //  4.  Bus Tasks                                                     //
    // ------------------------------------------------------------------ //

    // Registered write: drives stable signals before the rising edge.
    task automatic do_write (input logic [6:0]  addr,
                             input logic [31:0] data);
        @(negedge clk);
        addr_i  = addr;
        wdata_i = data;
        wr_en_i = 1'b1;
        @(posedge clk);    // DUT FFs capture here
        #1;
        wr_en_i = 1'b0;
    endtask

    // Combinational read: rdata_o is a pure function of addr_i in the DUT.
    task automatic do_read (input  logic [6:0]  addr,
                            output logic [31:0] data);
        @(negedge clk);
        addr_i  = addr;
        wr_en_i = 1'b0;
        #1;                // let the combinational mux settle
        data = rdata_o;
    endtask

    // ------------------------------------------------------------------ //
    //  5.  Test Data                                                     //
    // ------------------------------------------------------------------ //

    // 64 × 32-bit words = TWO 1024-bit message blocks, big-endian MSW first.
    logic [31:0] msg32 [0:63];

    // Golden reference for the 2-block zero message
    localparam logic [63:0] EXPECTED [0:7] = '{
        64'hab942f526272e456,
        64'hed68a979f5020290,
        64'h5ca903a141ed9844,
        64'h3567b11ef0bf25a5,
        64'h52d639051a01be58,
        64'h558122c58e3de07d,
        64'h749ee59ded36acf0,
        64'hc55cd91924d6ba11
    };

    // ------------------------------------------------------------------ //
    //  6.  Main Test Thread                                              //
    // ------------------------------------------------------------------ //
    int          b, i;
    logic [6:0]  raddr;
    logic [31:0] rd_hi, rd_lo;
    logic [63:0] result [0:7];
    int          matchess;

    initial begin : tb_main

        // ── Default bus state ──────────────────────────────────────────
        rst_n   = 1'b0;
        wr_en_i = 1'b0;
        addr_i  = 7'h00;
        wdata_i = 32'h0;

        // ── Load pre-padded message from file (2 blocks) ───────────────
        $readmemh("input_vectors1.hex", msg32);

        // ── Reset: hold 4 cycles, then release ─────────────────────────
        repeat(4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        $display("[TB %6t ns] Reset released.", $time);
        repeat(2) @(posedge clk);

        // ── Process 2 Blocks ───────────────────────────────────────────
        for (b = 0; b < 2; b++) begin
            $display("[TB %6t ns] Loading message block %0d ...", $time, b);
            
            // Write 16 × 64-bit message words to the scheduler
            for (i = 0; i < 16; i++) begin
                do_write(7'(2*i + 1), msg32[(b*32) + 2*i]);     // high half
                do_write(7'(2*i),     msg32[(b*32) + 2*i + 1]); // low  half
            end
            $display("[TB %6t ns] Message block %0d loaded.", $time, b);

            // ── Issue Control Signals ──────────────────────────────────
            if (b == 0) begin
                // Block 0: INIT (bit 1) + START (bit 0)
                do_write(7'h20, 32'h0000_0003);
                $display("[TB %6t ns] INIT+START issued.  Waiting for intr_o ...", $time);
            end else begin
                // Subsequent Blocks: START (bit 0) ONLY to chain the hash
                do_write(7'h20, 32'h0000_0001);
                $display("[TB %6t ns] START issued.  Waiting for intr_o ...", $time);
            end

            // ── Wait for completion interrupt ──────────────────────────
            @(posedge intr_o);
            @(negedge clk);    // step to the safe read window between edges
            $display("[TB %6t ns] intr_o asserted for block %0d.", $time, b);
        end

        $display("[TB %6t ns] All blocks processed. Reading digest ...", $time);

        // ── Read the 8 × 64-bit hash words ────────────────────────────
        for (i = 0; i < 8; i++) begin
            raddr = 7'h22 + 7'(2*i + 1);
            do_read(raddr, rd_hi);
            raddr = 7'h22 + 7'(2*i);
            do_read(raddr, rd_lo);
            result[i] = {rd_hi, rd_lo};
        end

        // ── Print & compare ────────────────────────────────────────────
        $display("");
        $display("==============================================");
        $display("  DUT output:");
        $display("----------------------------------------------");
        for (i = 0; i < 8; i++)
            $display("  H[%0d] = %016h", i, result[i]);

        $display("----------------------------------------------");
        $display("  Expected SHA-512:");
        $display("----------------------------------------------");
        for (i = 0; i < 8; i++)
            $display("  E[%0d] = %016h", i, EXPECTED[i]);

        $display("----------------------------------------------");
        matchess = 0;
        for (i = 0; i < 8; i++)
            if (result[i] === EXPECTED[i]) matchess++;

        if (matchess == 8)
            $display("  RESULT : PASS  (8/8 words match)");
        else
            $display("  RESULT : FAIL  (%0d/8 words match)", matchess);
        $display("==============================================");
        $display("");

        $finish;
    end

    // ------------------------------------------------------------------ //
    //  7.  Watchdog  ─  Increased to 4000 cycles for multi-block test    //
    // ------------------------------------------------------------------ //
    initial begin : watchdog
        repeat(4000) @(posedge clk);
        $error("[TB] WATCHDOG: intr_o never fired. FSM may be stuck.");
        $finish;
    end

endmodule