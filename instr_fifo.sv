// instr_fifo.sv
//
// Thin adapter wrapping bsg_fifo_1r1w_small for 32-bit instruction storage.
//
// ---------------------------------------------------------------------------
// Why bsg_fifo_1r1w_small?
// ---------------------------------------------------------------------------
//
//  bsg_one_fifo / bsg_two_fifo
//    Too small (1–2 elements) for instruction bursts.
//
//  bsg_fifo_1r1w_small_hardened
//    Uses a synchronous-read memory (1-cycle read latency) plus a bypass DFF
//    to handle read/write address collisions.  The extra latency and bypass
//    logic are only worthwhile when mapping to hardened SRAM macros; for a
//    small register-file FIFO they add area and a pipeline stage for no gain.
//
//  bsg_fifo_1r1w_large / pseudo_large / 1rw_large
//    All built around a single-port 1RW backend: simultaneous enqueue and
//    dequeue in the same cycle is impossible (one port).  They also carry
//    4–7 elements of structural overhead and variable read latency — wrong
//    size class entirely.
//
//  bsg_fifo_1r1w_small (unhardened, default)   ← chosen
//    - Async-read 1R1W: rd_data is a combinatorial head of the queue.
//      The decoder's registered-input pipeline absorbs this with zero extra
//      latency, and simultaneous enqueue+dequeue is fully supported.
//    - bsg_fifo_tracker handles pointer arithmetic; uses BSG_SAFE_CLOG2 so
//      any depth works, not just powers of two.
//    - Automatically selects bsg_two_fifo for els_p == 2.
//    - harden_p = 1 upgrades to a sync-read BRAM-friendly version later
//      without touching this file.
//
// ---------------------------------------------------------------------------
// Interface notes
// ---------------------------------------------------------------------------
//
//  This module preserves the same external port names used by the rest of
//  the design (wr_en/full, rd_en/empty) and translates them to BSG's
//  valid/ready-yumi convention internally.
//
//  BSG uses an active-high reset_i; the active-low rst_n is inverted here.
//
// Parameters
//   DEPTH    – FIFO depth in 32-bit words; any value >= 2 (default 16)
//   HARDEN   – 0: async-read register file (default)
//              1: sync-read hardened memory (add BRAM path later)

`include "bsg_defines.sv"

module instr_fifo #(
    parameter int DEPTH  = 16,
    parameter int HARDEN = 0
)(
    input  logic        clk,
    input  logic        rst_n,

    // ---- Write port (from depacketizer) ----
    input  logic [31:0] wr_data,
    input  logic        wr_en,
    output logic        full,

    // ---- Read port (to decoder) ----
    output logic [31:0] rd_data,
    input  logic        rd_en,
    output logic        empty
);

    logic ready_param;   // BSG name for ~full
    logic v_o;           // BSG name for ~empty

    bsg_fifo_1r1w_small #(
        .width_p            (32    ),
        .els_p              (DEPTH ),
        .harden_p           (HARDEN),
        .ready_THEN_valid_p (0     )   // standard valid-AND-ready on input
    ) u_fifo (
        .clk_i         (clk        ),
        .reset_i       (~rst_n     ),   // BSG uses active-high reset

        // Write side
        .v_i           (wr_en      ),
        .ready_param_o (ready_param),
        .data_i        (wr_data    ),

        // Read side
        .v_o           (v_o        ),
        .data_o        (rd_data    ),
        .yumi_i        (rd_en      )    // yumi = valid consumer handshake
    );

    assign full  = ~ready_param;
    assign empty = ~v_o;

endmodule
