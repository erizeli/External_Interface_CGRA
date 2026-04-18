// depacketizer_top.sv
//
// Top-level integration of the chip on-ramp depacketizer chain:
//
//   DDR IO pins (from host)
//       │
//   ┌───▼──────────────┐
//   │   link_onramp    │  (bsg_link_ddr_downstream wrapper)
//   └───────────┬──────┘
//               │  16-bit valid-ready
//   ┌───────────▼────────┐
//   │  depacketizer_fsm  │  ─── instruction words ──► instr_fifo ──► decoder
//   └───────────────────┬┘
//                       └────── MMIO data words ──────────────────► mmio_* ports
//
// ---------------------------------------------------------------------------
// Port groups
// ---------------------------------------------------------------------------
//
//  Core clock / reset
//    clk, rst_n         Chip core clock and active-low reset.
//                       These are separate from the link resets (see below).
//
//  On-ramp link clocks and resets
//    onramp_core_link_reset_i   Core-domain reset for the DDR link.
//    onramp_io_clk_i            Per-channel forwarded IO clock from remote upstream.
//    onramp_io_link_reset_i     Per-channel IO-domain reset (sync to onramp_io_clk_i).
//
//    Reset sequence (must be driven by an external reset controller):
//      1. Assert onramp_io_link_reset_i and onramp_core_link_reset_i.
//      2. Wait for onramp_io_clk_i to toggle ≥ 4 times.
//      3. Deassert onramp_io_link_reset_i.
//      4. Deassert onramp_core_link_reset_i.
//
//  On-ramp physical DDR IO pins
//    onramp_io_data_i           DDR data from host (8 bits/channel, DDR = 16 bits/cycle)
//    onramp_io_valid_i          DDR valid from host (1 bit/channel)
//    onramp_core_token_r_o      Token credit return to host
//
//  Chip status registers
//    load_addr [15:0]   LOAD_ADDR register; sampled at data-packet header time.
//
//  MMIO write (data packets routed here)
//    mmio_addr/wdata/wr_en/wr_ready
//
//  Decoded instruction output
//    dec_stall, dec_*   See decoder.sv for full field descriptions.
//
// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------
//   FIFO_DEPTH       Instruction FIFO depth in words (default 16)
//   CHANNEL_WIDTH    IO bits per physical channel (default 8; must match host)
//   NUM_CHANNELS     Number of physical channels   (default 1; must match host)
//   LG_FIFO_DEPTH    log2 link elastic buffer depth (default 6; must match host)
//   LG_CREDIT_DEC    log2 credit decimation ratio   (default 3; must match host)

`include "bsg_defines.sv"

module depacketizer_top #(
    parameter int FIFO_DEPTH    = 16
   ,parameter int CHANNEL_WIDTH = 16
   ,parameter int NUM_CHANNELS  = 1
   ,parameter int LG_FIFO_DEPTH = 6
   ,parameter int LG_CREDIT_DEC = 3
   // LINK_WIDTH: bits delivered per core clock cycle (channel_width × 2 × channels)
   // With defaults channel_width=16, num_channels=1 → LINK_WIDTH=32
   ,localparam int LINK_WIDTH   = CHANNEL_WIDTH * 2 * NUM_CHANNELS
)(
    // ---- Core clock / reset ----
    input  logic        clk
   ,input  logic        rst_n

    // ---- On-ramp link resets / clocks ----
   ,input  logic                          onramp_core_link_reset_i
   ,input  logic [NUM_CHANNELS-1:0]       onramp_io_clk_i
   ,input  logic [NUM_CHANNELS-1:0]       onramp_io_link_reset_i

    // ---- On-ramp physical DDR IO pins ----
   ,input  logic [NUM_CHANNELS-1:0][CHANNEL_WIDTH-1:0] onramp_io_data_i
   ,input  logic [NUM_CHANNELS-1:0]                    onramp_io_valid_i
   ,output logic [NUM_CHANNELS-1:0]                    onramp_core_token_r_o

    // ---- Chip status registers ----
   ,input  logic [15:0] load_addr          // LOAD_ADDR register (written by LOAD decode)

    // ---- MMIO write port ----
   ,output logic [15:0] mmio_addr
   ,output logic [31:0] mmio_wdata
   ,output logic        mmio_wr_en
   ,input  logic        mmio_wr_ready

    // ---- Decoded instruction outputs ----
   ,input  logic        dec_stall

   ,output logic        dec_valid
   ,output logic [3:0]  dec_opcode

   ,output logic        dec_nop
   ,output logic        dec_set_mode
   ,output logic        dec_reset
   ,output logic        dec_wait

   ,output logic        dec_load
   ,output logic        dec_store
   ,output logic        dec_set_scratch_port
   ,output logic        dec_set_port_port
   ,output logic        dec_store_port_scratch

   ,output logic        dec_cfg_load
   ,output logic        dec_cfg_set
   ,output logic        dec_cfg_clr

   ,output logic        dec_load_weights
   ,output logic        dec_run

   ,output logic        dec_mode
   ,output logic [5:0]  dec_subsys_mask
   ,output logic [4:0]  dec_condition

   ,output logic [15:0] dec_ls_addr
   ,output logic [11:0] dec_ls_length

   ,output logic [15:0] dec_scratch_addr
   ,output logic [3:0]  dec_sport_port
   ,output logic [7:0]  dec_sport_num_cycles

   ,output logic [3:0]  dec_out_port
   ,output logic [3:0]  dec_in_port
   ,output logic [15:0] dec_pp_num_cycles

   ,output logic [3:0]  dec_sps_port
   ,output logic [15:0] dec_sps_scratch_addr

   ,output logic [1:0]  dec_context

   ,output logic [15:0] dec_run_count
   ,output logic [3:0]  dec_run_i_port
   ,output logic [3:0]  dec_run_o_port
);

    // -----------------------------------------------------------------------
    // On-ramp link → depacketizer FSM (16-bit valid-ready)
    // -----------------------------------------------------------------------
    logic [LINK_WIDTH-1:0] bus_data;
    logic                  bus_valid;
    logic                  bus_ready;

    link_onramp #(
        .channel_width_p                 (CHANNEL_WIDTH )
       ,.num_channels_p                  (NUM_CHANNELS  )
       ,.lg_fifo_depth_p                 (LG_FIFO_DEPTH )
       ,.lg_credit_to_token_decimation_p (LG_CREDIT_DEC )
       ,.bypass_gearbox_p                (1             )
    ) u_onramp (
        .core_clk_i         (clk                       )
       ,.core_link_reset_i  (onramp_core_link_reset_i  )

       ,.io_clk_i           (onramp_io_clk_i           )
       ,.io_link_reset_i    (onramp_io_link_reset_i    )

       ,.io_data_i          (onramp_io_data_i          )
       ,.io_valid_i         (onramp_io_valid_i         )
       ,.core_token_r_o     (onramp_core_token_r_o     )

       ,.core_data_o        (bus_data                  )
       ,.core_valid_o       (bus_valid                 )
       ,.core_ready_i       (bus_ready                 )
    );

    // -----------------------------------------------------------------------
    // Internal wires: depacketizer FSM ↔ FIFO
    // -----------------------------------------------------------------------
    logic [31:0] fifo_wdata;
    logic        fifo_wr_en;
    logic        fifo_full;

    logic [31:0] fifo_rdata;
    logic        fifo_rd_en;
    logic        fifo_empty;

    // -----------------------------------------------------------------------
    // depacketizer_fsm
    // -----------------------------------------------------------------------
    depacketizer_fsm u_fsm (
        .clk           (clk          )
       ,.rst_n         (rst_n        )

       ,.bus_data      (bus_data     )
       ,.bus_valid     (bus_valid    )
       ,.bus_ready     (bus_ready    )

       ,.load_addr     (load_addr    )

       ,.fifo_wdata    (fifo_wdata   )
       ,.fifo_wr_en    (fifo_wr_en   )
       ,.fifo_full     (fifo_full    )

       ,.mmio_addr     (mmio_addr    )
       ,.mmio_wdata    (mmio_wdata   )
       ,.mmio_wr_en    (mmio_wr_en   )
       ,.mmio_wr_ready (mmio_wr_ready)
    );

    // -----------------------------------------------------------------------
    // instr_fifo
    // -----------------------------------------------------------------------
    instr_fifo #(
        .DEPTH (FIFO_DEPTH)
    ) u_fifo (
        .clk     (clk        )
       ,.rst_n   (rst_n      )

       ,.wr_data (fifo_wdata )
       ,.wr_en   (fifo_wr_en )
       ,.full    (fifo_full  )

       ,.rd_data (fifo_rdata )
       ,.rd_en   (fifo_rd_en )
       ,.empty   (fifo_empty )
    );

    // -----------------------------------------------------------------------
    // decoder
    // -----------------------------------------------------------------------
    decoder u_decoder (
        .clk         (clk       )
       ,.rst_n       (rst_n     )

       ,.instr_data  (fifo_rdata)
       ,.instr_rd_en (fifo_rd_en)
       ,.instr_empty (fifo_empty)

       ,.stall       (dec_stall )

       ,.dec_valid              (dec_valid              )
       ,.dec_opcode             (dec_opcode             )

       ,.dec_nop                (dec_nop                )
       ,.dec_set_mode           (dec_set_mode           )
       ,.dec_reset              (dec_reset              )
       ,.dec_wait               (dec_wait               )

       ,.dec_load               (dec_load               )
       ,.dec_store              (dec_store              )
       ,.dec_set_scratch_port   (dec_set_scratch_port   )
       ,.dec_set_port_port      (dec_set_port_port      )
       ,.dec_store_port_scratch (dec_store_port_scratch )

       ,.dec_cfg_load           (dec_cfg_load           )
       ,.dec_cfg_set            (dec_cfg_set            )
       ,.dec_cfg_clr            (dec_cfg_clr            )

       ,.dec_load_weights       (dec_load_weights       )
       ,.dec_run                (dec_run                )

       ,.dec_mode               (dec_mode               )
       ,.dec_subsys_mask        (dec_subsys_mask        )
       ,.dec_condition          (dec_condition          )

       ,.dec_ls_addr            (dec_ls_addr            )
       ,.dec_ls_length          (dec_ls_length          )

       ,.dec_scratch_addr       (dec_scratch_addr       )
       ,.dec_sport_port         (dec_sport_port         )
       ,.dec_sport_num_cycles   (dec_sport_num_cycles   )

       ,.dec_out_port           (dec_out_port           )
       ,.dec_in_port            (dec_in_port            )
       ,.dec_pp_num_cycles      (dec_pp_num_cycles      )

       ,.dec_sps_port           (dec_sps_port           )
       ,.dec_sps_scratch_addr   (dec_sps_scratch_addr   )

       ,.dec_context            (dec_context            )

       ,.dec_run_count          (dec_run_count          )
       ,.dec_run_i_port         (dec_run_i_port         )
       ,.dec_run_o_port         (dec_run_o_port         )
    );

endmodule
