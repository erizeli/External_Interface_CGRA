// link_offramp.sv
//
// Chip off-ramp: wraps bsg_link_ddr_upstream.
//
// The physical link has 16 data wires.  DDR delivers 2 × 16 = 32 bits per
// core clock cycle.  This module accepts a 32-bit valid-ready stream from
// the chip core and sends it out over the DDR IO pins to a remote
// bsg_link_ddr_downstream (typically on the host FPGA/ASIC).
//
//   Chip core (32-bit valid-ready)
//       │
//   ┌───▼────────────────────────┐
//   │  bsg_link_ddr_upstream     │  width_p=32, channel_width_p=16
//   └───────────────┬────────────┘
//                   │  16 data pins, DDR
//                   ▼  to host
//
// ---------------------------------------------------------------------------
// Sizing
// ---------------------------------------------------------------------------
//   channel_width_p = 16  (physical data pins per channel)
//   num_channels_p  = 1
//   ddr_width       = 16 × 2 = 32 bits per cycle
//   piso_ratio      = width_p / ddr_width = 32 / 32 = 1
//   → bypass_gearbox_p=1 skips the PISOF entirely (minimum latency)
//
//   lg_fifo_depth_p and lg_credit_to_token_decimation_p MUST match the
//   paired bsg_link_ddr_downstream on the host side.
//
// ---------------------------------------------------------------------------
// Reset sequence (driven by an external reset controller, NOT tied to rst_n)
// ---------------------------------------------------------------------------
//   1. Assert io_link_reset_i and core_link_reset_i.
//   2. Toggle async_token_reset_i (0→1→0) at least once.
//      token_clk_i must NOT toggle during this step.
//   3. Toggle io_clk_i posedge ≥ 4 times.
//   4. Deassert io_link_reset_i.
//   5. Deassert core_link_reset_i.

`include "bsg_defines.sv"

module link_offramp #(
    parameter int channel_width_p                 = 16   // physical data pins
   ,parameter int num_channels_p                  = 1
   ,parameter int lg_fifo_depth_p                 = 6
   ,parameter int lg_credit_to_token_decimation_p = 3
   ,parameter int use_extra_data_bit_p            = 0
   ,parameter int use_encode_p                    = 0
   ,parameter int bypass_twofer_fifo_p            = 0
   ,parameter int bypass_gearbox_p                = 1    // ratio=1; no PISOF
   ,localparam int link_width_lp =
        (channel_width_p * 2 + use_extra_data_bit_p) * num_channels_p  // = 32
)(
    // ---- Core clock domain ----
    input  logic core_clk_i
   ,input  logic core_link_reset_i

    // ---- IO clock domain ----
    // io_clk_i drives the ODDR PHY; typically a PLL output at the DDR line rate.
   ,input  logic io_clk_i
   ,input  logic io_link_reset_i        // synchronous to io_clk_i

    // ---- Token credit reset (async; must be toggled during reset step 2) ----
   ,input  logic async_token_reset_i

    // ---- Token credit return (from remote bsg_link_ddr_downstream on host) ----
   ,input  logic [num_channels_p-1:0] token_clk_i

    // ---- Core-side input ← chip core (32-bit valid-ready) ----
   ,input  logic [link_width_lp-1:0] core_data_i
   ,input  logic                     core_valid_i
   ,output logic                     core_ready_o

    // ---- Physical DDR IO pins (to remote bsg_link_ddr_downstream on host) ----
   ,output logic [num_channels_p-1:0]                       io_clk_r_o
   ,output logic [num_channels_p-1:0][channel_width_p-1:0]  io_data_r_o
   ,output logic [num_channels_p-1:0]                       io_valid_r_o
);

    bsg_link_ddr_upstream #(
        .width_p                         (link_width_lp              )
       ,.channel_width_p                 (channel_width_p             )
       ,.num_channels_p                  (num_channels_p              )
       ,.lg_fifo_depth_p                 (lg_fifo_depth_p             )
       ,.lg_credit_to_token_decimation_p (lg_credit_to_token_decimation_p)
       ,.use_extra_data_bit_p            (use_extra_data_bit_p        )
       ,.use_encode_p                    (use_encode_p                )
       ,.bypass_twofer_fifo_p            (bypass_twofer_fifo_p        )
       ,.bypass_gearbox_p                (bypass_gearbox_p            )
    ) u_upstream (
        .core_clk_i          (core_clk_i         )
       ,.core_link_reset_i   (core_link_reset_i  )

       ,.core_data_i         (core_data_i        )
       ,.core_valid_i        (core_valid_i       )
       ,.core_ready_o        (core_ready_o       )

       ,.io_clk_i            (io_clk_i           )
       ,.io_link_reset_i     (io_link_reset_i    )
       ,.async_token_reset_i (async_token_reset_i)

       ,.io_clk_r_o          (io_clk_r_o         )
       ,.io_data_r_o         (io_data_r_o        )
       ,.io_valid_r_o        (io_valid_r_o       )
       ,.token_clk_i         (token_clk_i        )
    );

endmodule
