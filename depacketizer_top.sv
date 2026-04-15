// depacketizer_top.sv
//
// Top-level integration of the on-ramp depacketizer chain:
//
//   on-ramp bus
//       │
//   ┌───▼────────────────┐
//   │  depacketizer_fsm  │  ─── instruction words ──► instr_fifo ──► decoder
//   └───────────────────┬┘
//                       └────── MMIO data words ──────────────────► mmio_* ports
//
// Parameters
//   FIFO_DEPTH  – instruction FIFO depth in 32-bit words (power of 2, default 16)
//
// ---------------------------------------------------------------------------
// Port groups
// ---------------------------------------------------------------------------
//
//  On-ramp bus
//    bus_data   [15:0]   incoming 16-bit word
//    bus_valid           bus_data is valid
//    bus_ready           this module can accept bus_data (backpressure)
//
//  Chip status registers
//    load_addr  [15:0]   LOAD_ADDR register; sampled when a data-packet header
//                        is accepted; the FSM uses it as the MMIO base address
//                        and auto-increments from there for each payload word.
//
//  MMIO write (data packets routed here)
//    mmio_addr  [15:0]   word address (auto-increments per payload word)
//    mmio_wdata [15:0]   write data
//    mmio_wr_en          write strobe (combinatorial; write completes when mmio_wr_ready)
//    mmio_wr_ready       MMIO controller ready / ack
//
//  Decoded instruction output
//    All dec_* signals mirror decoder.sv outputs.
//    dec_stall           upstream stall input: freeze pipeline, suppress fetch

module depacketizer_top #(
    parameter int FIFO_DEPTH = 16
)(
    input  logic        clk,
    input  logic        rst_n,

    // ---- On-ramp bus ----
    input  logic [15:0] bus_data,
    input  logic        bus_valid,
    output logic        bus_ready,

    // ---- Chip status registers ----
    input  logic [15:0] load_addr,      // LOAD_ADDR register (set by LOAD instruction)

    // ---- MMIO write port ----
    output logic [15:0] mmio_addr,
    output logic [15:0] mmio_wdata,
    output logic        mmio_wr_en,
    input  logic        mmio_wr_ready,

    // ---- Decoded instruction outputs ----
    input  logic        dec_stall,

    output logic        dec_valid,
    output logic [3:0]  dec_opcode,

    output logic        dec_nop,
    output logic        dec_set_mode,
    output logic        dec_reset,
    output logic        dec_wait,

    output logic        dec_load,
    output logic        dec_store,
    output logic        dec_set_scratch_port,
    output logic        dec_set_port_port,
    output logic        dec_store_port_scratch,

    output logic        dec_cfg_load,
    output logic        dec_cfg_set,
    output logic        dec_cfg_clr,

    output logic        dec_load_weights,
    output logic        dec_run,

    output logic        dec_mode,
    output logic [5:0]  dec_subsys_mask,
    output logic [4:0]  dec_condition,

    output logic [15:0] dec_ls_addr,
    output logic [11:0] dec_ls_length,

    output logic [15:0] dec_scratch_addr,
    output logic [3:0]  dec_sport_port,
    output logic [7:0]  dec_sport_num_cycles,

    output logic [3:0]  dec_out_port,
    output logic [3:0]  dec_in_port,
    output logic [15:0] dec_pp_num_cycles,

    output logic [3:0]  dec_sps_port,
    output logic [15:0] dec_sps_scratch_addr,

    output logic [1:0]  dec_context,

    output logic [15:0] dec_run_count,
    output logic [3:0]  dec_run_i_port,
    output logic [3:0]  dec_run_o_port
);

    // -----------------------------------------------------------------------
    // Internal wires: FSM ↔ FIFO
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
        .clk           (clk),
        .rst_n         (rst_n),

        .bus_data      (bus_data),
        .bus_valid     (bus_valid),
        .bus_ready     (bus_ready),

        .load_addr     (load_addr),

        .fifo_wdata    (fifo_wdata),
        .fifo_wr_en    (fifo_wr_en),
        .fifo_full     (fifo_full),

        .mmio_addr     (mmio_addr),
        .mmio_wdata    (mmio_wdata),
        .mmio_wr_en    (mmio_wr_en),
        .mmio_wr_ready (mmio_wr_ready)
    );

    // -----------------------------------------------------------------------
    // instr_fifo
    // -----------------------------------------------------------------------
    instr_fifo #(
        .DEPTH (FIFO_DEPTH)
    ) u_fifo (
        .clk     (clk),
        .rst_n   (rst_n),

        .wr_data (fifo_wdata),
        .wr_en   (fifo_wr_en),
        .full    (fifo_full),

        .rd_data (fifo_rdata),
        .rd_en   (fifo_rd_en),
        .empty   (fifo_empty)
    );

    // -----------------------------------------------------------------------
    // decoder
    // -----------------------------------------------------------------------
    decoder u_decoder (
        .clk        (clk),
        .rst_n      (rst_n),

        .instr_data  (fifo_rdata),
        .instr_rd_en (fifo_rd_en),
        .instr_empty (fifo_empty),

        .stall       (dec_stall),

        .dec_valid              (dec_valid),
        .dec_opcode             (dec_opcode),

        .dec_nop                (dec_nop),
        .dec_set_mode           (dec_set_mode),
        .dec_reset              (dec_reset),
        .dec_wait               (dec_wait),

        .dec_load               (dec_load),
        .dec_store              (dec_store),
        .dec_set_scratch_port   (dec_set_scratch_port),
        .dec_set_port_port      (dec_set_port_port),
        .dec_store_port_scratch (dec_store_port_scratch),

        .dec_cfg_load           (dec_cfg_load),
        .dec_cfg_set            (dec_cfg_set),
        .dec_cfg_clr            (dec_cfg_clr),

        .dec_load_weights       (dec_load_weights),
        .dec_run                (dec_run),

        .dec_mode               (dec_mode),
        .dec_subsys_mask        (dec_subsys_mask),
        .dec_condition          (dec_condition),

        .dec_ls_addr            (dec_ls_addr),
        .dec_ls_length          (dec_ls_length),

        .dec_scratch_addr       (dec_scratch_addr),
        .dec_sport_port         (dec_sport_port),
        .dec_sport_num_cycles   (dec_sport_num_cycles),

        .dec_out_port           (dec_out_port),
        .dec_in_port            (dec_in_port),
        .dec_pp_num_cycles      (dec_pp_num_cycles),

        .dec_sps_port           (dec_sps_port),
        .dec_sps_scratch_addr   (dec_sps_scratch_addr),

        .dec_context            (dec_context),

        .dec_run_count          (dec_run_count),
        .dec_run_i_port         (dec_run_i_port),
        .dec_run_o_port         (dec_run_o_port)
    );

endmodule
