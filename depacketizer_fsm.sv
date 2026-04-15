// depacketizer_fsm.sv
//
// Parses a 16-bit on-ramp packet stream and routes:
//   - Instruction packets → 32-bit instruction FIFO write port
//   - Data packets        → 16-bit MMIO write port (auto-incrementing address)
//
// ---------------------------------------------------------------------------
// Packet Protocol (on-ramp bus)
// ---------------------------------------------------------------------------
//
//  INSTRUCTION PACKET (3 words)
//    Word 0  [15]=0, [14:0]=don't-care          (header)
//    Word 1  instr[31:16]                        (MSW)
//    Word 2  instr[15:0]                         (LSW → FIFO write)
//
//  DATA PACKET (1 + N words, N >= 1)
//    Word 0  [15]=1, [14:12]=rsvd, [11:0]=N     (header, N = word count)
//    Word 1..N  payload words                   (written to load_addr, load_addr+1, ...)
//
//  The MMIO base address is NOT carried in the packet.  It is read from the
//  chip's LOAD_ADDR status register (load_addr input) at header-accept time.
//
// ---------------------------------------------------------------------------
// Backpressure
//   - S_INSTR_LO : stalls (bus_ready=0) when instruction FIFO is full
//   - S_DATA_WR  : stalls (bus_ready=0) when MMIO controller is not ready
//   All other states keep bus_ready=1.
// ---------------------------------------------------------------------------

module depacketizer_fsm (
    input  logic        clk,
    input  logic        rst_n,

    // ---- On-ramp bus (AXI-S subset) ----
    input  logic [15:0] bus_data,
    input  logic        bus_valid,
    output logic        bus_ready,

    // ---- Chip LOAD_ADDR status register ----
    // Sampled at data-packet header accept; held for the duration of the burst.
    input  logic [15:0] load_addr,

    // ---- Instruction FIFO write port ----
    output logic [31:0] fifo_wdata,
    output logic        fifo_wr_en,
    input  logic        fifo_full,

    // ---- MMIO write port ----
    output logic [15:0] mmio_addr,
    output logic [15:0] mmio_wdata,
    output logic        mmio_wr_en,
    input  logic        mmio_wr_ready
);

    // -----------------------------------------------------------------------
    // FSM state encoding
    // -----------------------------------------------------------------------
    typedef enum logic [1:0] {
        S_HEADER   = 2'd0,   // awaiting / parsing header word
        S_INSTR_HI = 2'd1,   // collecting instr[31:16]
        S_INSTR_LO = 2'd2,   // collecting instr[15:0], then writing FIFO
        S_DATA_WR  = 2'd3    // streaming payload words to MMIO
    } state_t;

    state_t state, next_state;

    // -----------------------------------------------------------------------
    // Data-path registers
    // -----------------------------------------------------------------------
    logic [15:0] instr_hi_r;     // instr[31:16] captured in S_INSTR_HI
    logic [15:0] mmio_addr_r;    // current MMIO write address
    logic [11:0] data_count_r;   // remaining data words (down-counter)

    // Qualified transfer pulse: a word is accepted this cycle
    logic xfer;
    assign xfer = bus_valid & bus_ready;

    // -----------------------------------------------------------------------
    // State register
    // -----------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_HEADER;
        else        state <= next_state;
    end

    // -----------------------------------------------------------------------
    // Data-path register updates
    // -----------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            instr_hi_r   <= 16'h0;
            mmio_addr_r  <= 16'h0;
            data_count_r <= 12'h0;
        end else begin
            if (xfer) begin
                case (state)
                    S_HEADER: begin
                        if (bus_data[15]) begin
                            // Data packet: snapshot word count and base address now.
                            // load_addr is the chip's LOAD_ADDR status register.
                            data_count_r <= bus_data[11:0];
                            mmio_addr_r  <= load_addr;
                        end
                    end
                    S_INSTR_HI: instr_hi_r <= bus_data;
                    S_DATA_WR: begin
                        mmio_addr_r  <= mmio_addr_r + 16'd1;        // auto-increment
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
            S_HEADER: begin
                if (xfer) begin
                    if (bus_data[15])
                        // Data packet: go straight to payload (no address word).
                        // Skip entirely if length field is zero.
                        next_state = (bus_data[11:0] == 12'd0) ? S_HEADER : S_DATA_WR;
                    else
                        next_state = S_INSTR_HI;
                end
            end

            S_INSTR_HI: begin
                if (xfer) next_state = S_INSTR_LO;
            end

            S_INSTR_LO: begin
                // xfer only when ~fifo_full (bus_ready = ~fifo_full)
                if (xfer) next_state = S_HEADER;
            end

            S_DATA_WR: begin
                // xfer only when mmio_wr_ready (bus_ready = mmio_wr_ready)
                if (xfer)
                    next_state = (data_count_r == 12'd1) ? S_HEADER : S_DATA_WR;
            end

            default: next_state = S_HEADER;
        endcase
    end

    // -----------------------------------------------------------------------
    // Backpressure / bus_ready
    // -----------------------------------------------------------------------
    always_comb begin
        case (state)
            S_INSTR_LO: bus_ready = ~fifo_full;
            S_DATA_WR:  bus_ready = mmio_wr_ready;
            default:    bus_ready = 1'b1;
        endcase
    end

    // -----------------------------------------------------------------------
    // FIFO write (instruction reassembly)
    // -----------------------------------------------------------------------
    assign fifo_wdata = {instr_hi_r, bus_data};   // combinatorial; stable when wr_en
    assign fifo_wr_en = (state == S_INSTR_LO) && xfer;

    // -----------------------------------------------------------------------
    // MMIO write
    // -----------------------------------------------------------------------
    // Assert wr_en whenever we have a valid data word to push; the MMIO
    // controller gates the actual write with mmio_wr_ready.
    assign mmio_addr  = mmio_addr_r;
    assign mmio_wdata = bus_data;
    assign mmio_wr_en = (state == S_DATA_WR) && bus_valid;

endmodule
