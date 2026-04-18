// depacketizer_fsm.sv
//
// Parses a 32-bit on-ramp word stream (16-bit physical DDR bus) and routes:
//   - Instruction words → 32-bit instruction FIFO
//   - Data payload words → 32-bit MMIO write port (auto-incrementing address)
//
// ---------------------------------------------------------------------------
// Packet Protocol (32-bit DDR bus)
// ---------------------------------------------------------------------------
//
//  INSTRUCTION (1 word):
//    bits[31:28] = 0x0–0xD  →  word IS the instruction; push to FIFO.
//    All ISA opcodes are 32-bit fixed-width and arrive complete in one cycle.
//
//  DATA PACKET (1 + N words):
//    Word 0  bits[31:28]=0xF, bits[27:16]=N, bits[15:0]=don't-care   (header)
//    Word 1..N  32-bit payload words (written to load_addr, load_addr+1, …)
//
//    The MMIO base address comes from the chip's LOAD_ADDR status register
//    (load_addr input), sampled when the header word is accepted.
//
//  RESERVED (opcode 0xE):
//    Silently discarded; bus_ready is always asserted for these words.
//
// ---------------------------------------------------------------------------
// FSM states (2 states)
// ---------------------------------------------------------------------------
//
//  S_FETCH   Normal decode state.
//    - Instruction  (opcode < 0xE): bus_ready = ~fifo_full; push to FIFO.
//    - Data header  (opcode == 0xF): bus_ready = 1; latch count + addr;
//                   → S_DATA_WR (or stay if count == 0).
//    - Reserved     (opcode == 0xE): bus_ready = 1; discard.
//
//  S_DATA_WR  Streaming data payload to MMIO.
//    - bus_ready = mmio_wr_ready  (stall when MMIO controller is busy)
//    - Auto-increment mmio_addr each accepted word.
//    - Return to S_FETCH when the last word is accepted.

module depacketizer_fsm (
    input  logic        clk,
    input  logic        rst_n,

    // ---- On-ramp bus (32-bit, one DDR word per cycle) ----
    input  logic [31:0] bus_data,
    input  logic        bus_valid,
    output logic        bus_ready,

    // ---- Chip LOAD_ADDR status register ----
    // Sampled at data-packet header accept; held for the burst duration.
    input  logic [15:0] load_addr,

    // ---- Instruction FIFO write port ----
    output logic [31:0] fifo_wdata,
    output logic        fifo_wr_en,
    input  logic        fifo_full,

    // ---- MMIO write port ----
    output logic [15:0] mmio_addr,
    output logic [31:0] mmio_wdata,
    output logic        mmio_wr_en,
    input  logic        mmio_wr_ready
);

    // -----------------------------------------------------------------------
    // FSM state encoding
    // -----------------------------------------------------------------------
    typedef enum logic {
        S_FETCH   = 1'b0,   // instruction decode / data header
        S_DATA_WR = 1'b1    // streaming payload words to MMIO
    } state_t;

    state_t state, next_state;

    // -----------------------------------------------------------------------
    // Data-path registers
    // -----------------------------------------------------------------------
    logic [15:0] mmio_addr_r;    // current MMIO write address (auto-increments)
    logic [11:0] data_count_r;   // remaining payload words (down-counter)

    // Qualified transfer pulse
    logic xfer;
    assign xfer = bus_valid & bus_ready;

    // Opcode decode (used in S_FETCH only)
    logic [3:0]  opcode;
    logic        is_instr;     // opcode 0x0–0xD: valid instruction
    logic        is_data_hdr;  // opcode 0xF:     data packet header
    assign opcode      = bus_data[31:28];
    assign is_instr    = (opcode < 4'hE);
    assign is_data_hdr = (opcode == 4'hF);

    // -----------------------------------------------------------------------
    // State register
    // -----------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_FETCH;
        else        state <= next_state;
    end

    // -----------------------------------------------------------------------
    // Data-path register updates
    // -----------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mmio_addr_r  <= 16'h0;
            data_count_r <= 12'h0;
        end else begin
            if (xfer) begin
                case (state)
                    S_FETCH: begin
                        if (is_data_hdr) begin
                            data_count_r <= bus_data[27:16];
                            mmio_addr_r  <= load_addr;       // snapshot LOAD_ADDR
                        end
                    end
                    S_DATA_WR: begin
                        mmio_addr_r  <= mmio_addr_r + 16'd1;
                        data_count_r <= data_count_r - 12'd1;
                    end
                    default: ;
                endcase
            end
        end
    end

    // -----------------------------------------------------------------------
    // Next-state logic
    // -----------------------------------------------------------------------
    always_comb begin
        next_state = state;
        case (state)
            S_FETCH: begin
                if (xfer && is_data_hdr)
                    next_state = (bus_data[27:16] == 12'd0) ? S_FETCH : S_DATA_WR;
            end
            S_DATA_WR: begin
                if (xfer)
                    next_state = (data_count_r == 12'd1) ? S_FETCH : S_DATA_WR;
            end
            default: next_state = S_FETCH;
        endcase
    end

    // -----------------------------------------------------------------------
    // Backpressure / bus_ready
    // -----------------------------------------------------------------------
    //   S_FETCH:
    //     Instructions  (opcode < 0xE): stall when FIFO is full.
    //     Data header   (opcode == 0xF): always accept (just latches registers).
    //     Reserved      (opcode == 0xE): always accept (discard).
    //   S_DATA_WR:
    //     Stall when MMIO controller is not ready.
    always_comb begin
        case (state)
            S_FETCH:   bus_ready = is_instr ? ~fifo_full : 1'b1;
            S_DATA_WR: bus_ready = mmio_wr_ready;
            default:   bus_ready = 1'b1;
        endcase
    end

    // -----------------------------------------------------------------------
    // FIFO write — instruction arrives complete in one word
    // -----------------------------------------------------------------------
    assign fifo_wdata = bus_data;
    assign fifo_wr_en = (state == S_FETCH) && xfer && is_instr;

    // -----------------------------------------------------------------------
    // MMIO write
    // -----------------------------------------------------------------------
    assign mmio_addr  = mmio_addr_r;
    assign mmio_wdata = bus_data;
    assign mmio_wr_en = (state == S_DATA_WR) && bus_valid;

endmodule
