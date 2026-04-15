// decoder.sv
//
// One-stage pipelined instruction decoder for the CGRA/systolic-array ISA.
//
// Reads 32-bit instructions from the instruction FIFO and presents fully
// decoded fields one cycle later.  A 'stall' input freezes the pipeline:
// the current decoded instruction is held and no new fetch is issued until
// stall is de-asserted.
//
// ---------------------------------------------------------------------------
// Interface summary
// ---------------------------------------------------------------------------
//
//  Fetch / FIFO
//    instr_data  [31:0]   – FIFO read-data (combinatorial head of queue)
//    instr_rd_en          – pop enable to FIFO
//    instr_empty          – FIFO empty flag
//
//  Pipeline control
//    stall                – freeze: hold current decoded word, suspend fetch
//
//  Decoded output (registered, valid one cycle after fetch)
//    dec_valid            – a valid instruction is on the output
//    dec_opcode  [3:0]    – raw opcode for muxing downstream
//    dec_<instr>          – one-hot instruction qualifiers
//    dec_<field>          – extracted operand fields

module decoder (
    input  logic        clk,
    input  logic        rst_n,

    // ---- Instruction FIFO ----
    input  logic [31:0] instr_data,
    output logic        instr_rd_en,
    input  logic        instr_empty,

    // ---- Pipeline control ----
    input  logic        stall,

    // ---- Decoded output ----
    output logic        dec_valid,
    output logic [3:0]  dec_opcode,

    // Control group
    output logic        dec_nop,
    output logic        dec_set_mode,
    output logic        dec_reset,
    output logic        dec_wait,

    // Memory group
    output logic        dec_load,
    output logic        dec_store,
    output logic        dec_set_scratch_port,
    output logic        dec_set_port_port,
    output logic        dec_store_port_scratch,

    // Config group
    output logic        dec_cfg_load,
    output logic        dec_cfg_set,
    output logic        dec_cfg_clr,

    // System / Exec
    output logic        dec_load_weights,
    output logic        dec_run,

    // ---- Operand fields (valid when dec_valid) ----

    // SET_MODE
    output logic        dec_mode,           // 0=CGRA  1=Systolic

    // RESET
    output logic [5:0]  dec_subsys_mask,    // one-hot subsystem select

    // WAIT
    output logic [4:0]  dec_condition,      // one-hot condition bits

    // LOAD / STORE  (shared field layout)
    output logic [15:0] dec_ls_addr,
    output logic [11:0] dec_ls_length,

    // SET_SCRATCH_PORT  (0x6)
    output logic [15:0] dec_scratch_addr,
    output logic [3:0]  dec_sport_port,
    output logic [7:0]  dec_sport_num_cycles,

    // SET_PORT_PORT  (0x7)
    output logic [3:0]  dec_out_port,
    output logic [3:0]  dec_in_port,
    output logic [15:0] dec_pp_num_cycles,

    // STORE_PORT_SCRATCH  (0x8)
    output logic [3:0]  dec_sps_port,
    output logic [15:0] dec_sps_scratch_addr,

    // CFG_LOAD / CFG_SET / CFG_CLR  (shared)
    output logic [1:0]  dec_context,

    // RUN  (0xD)
    output logic [15:0] dec_run_count,
    output logic [3:0]  dec_run_i_port,
    output logic [3:0]  dec_run_o_port
);

    // -----------------------------------------------------------------------
    // Fetch: read from FIFO when pipeline is free
    // -----------------------------------------------------------------------
    assign instr_rd_en = !instr_empty && !stall;

    // -----------------------------------------------------------------------
    // Pipeline register
    // -----------------------------------------------------------------------
    logic [31:0] instr_r;
    logic        valid_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            instr_r <= 32'h0;
            valid_r <= 1'b0;
        end else if (!stall) begin
            // Load new instruction when reading, invalidate on drain
            instr_r <= instr_rd_en ? instr_data : 32'h0;
            valid_r <= instr_rd_en;
        end
        // else: stall – hold instr_r and valid_r
    end

    // -----------------------------------------------------------------------
    // Decode (combinatorial from pipeline register)
    // -----------------------------------------------------------------------
    logic [3:0]  opc;
    logic [27:0] pl;      // payload bits [27:0]

    assign opc = instr_r[31:28];
    assign pl  = instr_r[27:0];

    // Top-level validity + opcode
    assign dec_valid  = valid_r;
    assign dec_opcode = opc;

    // One-hot instruction qualifiers
    assign dec_nop               = valid_r && (opc == 4'h0);
    assign dec_set_mode          = valid_r && (opc == 4'h1);
    assign dec_reset             = valid_r && (opc == 4'h2);
    assign dec_wait              = valid_r && (opc == 4'h3);
    assign dec_load              = valid_r && (opc == 4'h4);
    assign dec_store             = valid_r && (opc == 4'h5);
    assign dec_set_scratch_port  = valid_r && (opc == 4'h6);
    assign dec_set_port_port     = valid_r && (opc == 4'h7);
    assign dec_store_port_scratch= valid_r && (opc == 4'h8);
    assign dec_cfg_load          = valid_r && (opc == 4'h9);
    assign dec_cfg_set           = valid_r && (opc == 4'hA);
    assign dec_cfg_clr           = valid_r && (opc == 4'hB);
    assign dec_load_weights      = valid_r && (opc == 4'hC);
    assign dec_run               = valid_r && (opc == 4'hD);

    // -----------------------------------------------------------------------
    // Field extraction – per ISA encoding table in CLAUDE.md
    // -----------------------------------------------------------------------

    // SET_MODE (0x1): [0] = mode
    assign dec_mode            = pl[0];

    // RESET (0x2): [5:0] = subsystem_mask
    assign dec_subsys_mask     = pl[5:0];

    // WAIT (0x3): [4:0] = condition
    assign dec_condition       = pl[4:0];

    // LOAD (0x4) / STORE (0x5): [27:12]=addr, [11:0]=length
    assign dec_ls_addr         = pl[27:12];
    assign dec_ls_length       = pl[11:0];

    // SET_SCRATCH_PORT (0x6): [27:12]=scratch_addr, [11:8]=port, [7:0]=num_cycles
    assign dec_scratch_addr        = pl[27:12];
    assign dec_sport_port          = pl[11:8];
    assign dec_sport_num_cycles    = pl[7:0];

    // SET_PORT_PORT (0x7): [27:24]=out_port, [23:20]=in_port, [19:4]=num_cycles, [3:0]=rsvd
    assign dec_out_port        = pl[27:24];
    assign dec_in_port         = pl[23:20];
    assign dec_pp_num_cycles   = pl[19:4];

    // STORE_PORT_SCRATCH (0x8): [27:24]=port, [23:8]=scratch_addr, [7:0]=rsvd
    assign dec_sps_port        = pl[27:24];
    assign dec_sps_scratch_addr= pl[23:8];

    // CFG_LOAD (0x9) / CFG_SET (0xA) / CFG_CLR (0xB): [1:0]=context
    assign dec_context         = pl[1:0];

    // RUN (0xD): [27:12]=count, [11:8]=i_port, [7:4]=o_port, [3:0]=rsvd
    assign dec_run_count       = pl[27:12];
    assign dec_run_i_port      = pl[11:8];
    assign dec_run_o_port      = pl[7:4];

endmodule
