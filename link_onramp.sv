// link_onramp.sv
//
// Chip on-ramp: wraps bsg_link_ddr_downstream.
//
// The physical link has 16 data wires.  DDR delivers 2 × 16 = 32 bits per
// core clock cycle.  bsg_link_ddr_downstream is configured for width_p=32
// and the 32-bit output word is presented directly to the depacketizer FSM.
//
//   Host (16 data pins, DDR)
//       │  32 bits / cycle
//   ┌───▼────────────────────────┐
//   │  bsg_link_ddr_downstream   │  width_p=32, channel_width_p=16
//   └───────────────┬────────────┘
//                   │  32-bit valid-ready  →  depacketizer_fsm.bus_data[31:0]
//
// ---------------------------------------------------------------------------
// Sizing
// ---------------------------------------------------------------------------
//   channel_width_p = 16  (physical data pins per channel)
//   num_channels_p  = 1
//   ddr_width       = 16 × 2 = 32 bits per cycle
//   sipo_ratio      = width_p / ddr_width = 32 / 32 = 1
//   → bypass_gearbox_p=1 skips the SIPOF entirely (minimum latency)
//
//   lg_fifo_depth_p and lg_credit_to_token_decimation_p MUST match the
//   paired bsg_link_ddr_upstream on the host side.
//
// ---------------------------------------------------------------------------
// Handshake translation
// ---------------------------------------------------------------------------
//   bsg_link_ddr_downstream uses valid-yumi on its core output:
//     core_yumi_i = core_valid_o & core_ready_i
//
// ---------------------------------------------------------------------------
// Reset sequence (driven by an external reset controller, NOT tied to rst_n)
// ---------------------------------------------------------------------------
//   1. Assert io_link_reset_i and core_link_reset_i.
//   2. Wait for io_clk_i to toggle ≥ 4 times.
//   3. Deassert io_link_reset_i.
//   4. Deassert core_link_reset_i.

`include "bsg_defines.sv"

module link_onramp #(
    parameter int channel_width_p                 = 16   // physical data pins
   ,parameter int num_channels_p                  = 1
   ,parameter int lg_fifo_depth_p                 = 6
   ,parameter int lg_credit_to_token_decimation_p = 3
   ,parameter int use_extra_data_bit_p            = 0
   ,parameter int use_encode_p                    = 0
   ,parameter int bypass_twofer_fifo_p            = 0
   ,parameter int bypass_gearbox_p                = 1    // ratio=1; no SIPOF
   ,parameter int use_hardened_fifo_p             = 0
   ,localparam int link_width_lp =
        (channel_width_p * 2 + use_extra_data_bit_p) * num_channels_p  // = 32
)(
    // ---- Core clock domain ----
    input  logic core_clk_i
   ,input  logic core_link_reset_i

    // ---- IO clock domain (one per physical channel) ----
    // Forwarded by the remote bsg_link_ddr_upstream alongside the data.
   ,input  logic [num_channels_p-1:0]                       io_clk_i
   ,input  logic [num_channels_p-1:0]                       io_link_reset_i

    // ---- Physical DDR IO pins (from remote bsg_link_ddr_upstream on host) ----
   ,input  logic [num_channels_p-1:0][channel_width_p-1:0]  io_data_i
   ,input  logic [num_channels_p-1:0]                       io_valid_i

    // ---- Token credit return (to remote upstream) ----
   ,output logic [num_channels_p-1:0]                       core_token_r_o

    // ---- Core-side output → depacketizer_fsm (32-bit valid-ready) ----
   ,output logic [link_width_lp-1:0] core_data_o   // 32-bit DDR word
   ,output logic                     core_valid_o
   ,input  logic                     core_ready_i
);

    // Translate valid-ready → yumi for bsg_link_ddr_downstream
    logic core_yumi;
    assign core_yumi = core_valid_o & core_ready_i;

    bsg_link_ddr_downstream #(
        .width_p                         (link_width_lp              )
       ,.channel_width_p                 (channel_width_p             )
       ,.num_channels_p                  (num_channels_p              )
       ,.lg_fifo_depth_p                 (lg_fifo_depth_p             )
       ,.lg_credit_to_token_decimation_p (lg_credit_to_token_decimation_p)
       ,.use_extra_data_bit_p            (use_extra_data_bit_p        )
       ,.use_encode_p                    (use_encode_p                )
       ,.bypass_twofer_fifo_p            (bypass_twofer_fifo_p        )
       ,.bypass_gearbox_p                (bypass_gearbox_p            )
       ,.use_hardened_fifo_p             (use_hardened_fifo_p         )
    ) u_downstream (
        .core_clk_i        (core_clk_i       )
       ,.core_link_reset_i (core_link_reset_i)
       ,.io_link_reset_i   (io_link_reset_i  )
       ,.io_clk_i          (io_clk_i         )
       ,.io_data_i         (io_data_i        )
       ,.io_valid_i        (io_valid_i       )
       ,.core_token_r_o    (core_token_r_o   )
       ,.core_data_o       (core_data_o      )
       ,.core_valid_o      (core_valid_o     )
       ,.core_yumi_i       (core_yumi        )
    );

endmodule
