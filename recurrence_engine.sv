// recurrence_engine.sv
//
// Routes output tile values to scratchpad addresses or input ports according
// to a two-phase programmable schedule.
//
// ---------------------------------------------------------------------------
// Architecture
// ---------------------------------------------------------------------------
//
// One routing slot exists per output port.  Each slot holds:
//
//   PHASE REGISTERS (two entries, index 0 and 1):
//     dest_addr  [15:0]  – scratchpad base address OR zero-extended input port ID
//     dest_type  [0]     – 0 = PORT destination, 1 = SCRATCH destination
//     count      [15:0]  – count_remaining; 0 means phase is inactive
//
//   CONTROL (per slot):
//     current_phase [0]  – which phase register is active (0 or 1)
//     phase_counter [15:0] – increments per element produced in current phase;
//                          resets to 0 when current_phase advances.
//                          For SCRATCH routes: effective_addr = dest_addr + phase_counter
//                          For PORT  routes:   dest_addr is the fixed port ID (unchanged)
//
// On each cycle that out_valid_i[n] is asserted AND count > 0:
//   1. Route out_data_i[n] to the destination indicated by current_phase's registers.
//        SCRATCH: scratchpad[dest_addr + phase_counter] ← out_data_i[n]
//        PORT:    in_data_o[dest_addr[PORT_W-1:0]]     ← out_data_i[n]
//   2. Decrement count_remaining.
//   3. Increment phase_counter.
//   4. If count_remaining == 1 (last element): advance current_phase, reset phase_counter.
//
// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------
//
// SET_SCRATCH_PORT (0x6):
//   cfg_valid_i=1, cfg_port_port_i=0
//   cfg_out_port_i  = port  (output port to configure)
//   cfg_dest_addr_i = scratch_addr (base scratchpad address)
//   cfg_count_i     = zero-extended num_cycles (8-bit field)
//
// SET_PORT_PORT (0x7):
//   cfg_valid_i=1, cfg_port_port_i=1
//   cfg_out_port_i  = out_port
//   cfg_dest_addr_i = zero-extended in_port (4-bit field)
//   cfg_count_i     = num_cycles (16-bit field)
//
// Each configuration write targets wr_phase_r[cfg_out_port_i] and then
// toggles wr_phase_r.  After a RESET, wr_phase_r=0 so the first write fills
// phase 0, the second fills phase 1, and so on.
//
// Recommended programming sequence:
//   1. RESET (subsystem_mask bit 3) to clear all state.
//   2. Issue SET_SCRATCH_PORT / SET_PORT_PORT for each port as needed.
//   3. RUN.  While a phase is active, the next phase can be pre-loaded.
//   4. WAIT (condition bit 3) for recurrence engine idle before reprogramming.
//
// ---------------------------------------------------------------------------
// Scratchpad arbitration
// ---------------------------------------------------------------------------
// Multiple output ports may route to the scratchpad simultaneously.
// Fixed-priority arbitration: lowest port index wins.
// Simultaneous writes to *different* scratchpad addresses from multiple ports
// are silently dropped for all but the winner — the programmer must avoid this.
//
// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------
//   NUM_PORTS   Number of output (and input) tile ports; port IDs are
//               log2(NUM_PORTS) bits wide.  Default 16 (4-bit port ID).
//   DATA_WIDTH  Bit width of each port value.  Default 32.

module recurrence_engine #(
    parameter int NUM_PORTS  = 16
   ,parameter int DATA_WIDTH = 32
   ,localparam int PORT_W    = $clog2(NUM_PORTS)
)(
    input  logic clk,
    input  logic rst_n,

    // ---- Subsystem reset (RESET instruction, subsystem_mask[3]) ----
    // Synchronous active-high; clears all phase registers and counters.
    input  logic reset_i,

    // ---- Configuration from decoder ----
    input  logic              cfg_valid_i,
    input  logic              cfg_port_port_i,      // 1=SET_PORT_PORT, 0=SET_SCRATCH_PORT
    input  logic [PORT_W-1:0] cfg_out_port_i,       // output port being configured
    input  logic [15:0]       cfg_dest_addr_i,      // scratch base addr or zero-ext in_port
    input  logic [15:0]       cfg_count_i,          // num_cycles (zero-extended if 8-bit)

    // ---- Output tile values (from PE array / systolic array) ----
    input  logic [NUM_PORTS-1:0]                  out_valid_i,
    input  logic [NUM_PORTS-1:0][DATA_WIDTH-1:0]  out_data_i,

    // ---- Routed values to input ports ----
    // Assumes no two output ports are simultaneously routed to the same
    // input port.  Lowest port index wins on conflict.
    output logic [NUM_PORTS-1:0]                  in_valid_o,
    output logic [NUM_PORTS-1:0][DATA_WIDTH-1:0]  in_data_o,

    // ---- Routed values to scratchpad (lowest port index wins on conflict) ----
    output logic [15:0]           scratch_addr_o,
    output logic [DATA_WIDTH-1:0] scratch_wdata_o,
    output logic                  scratch_wr_en_o,

    // ---- Status ----
    // Asserted when all ports have count_remaining == 0 for their current phase.
    // Used by WAIT instruction (condition bit 3).
    output logic idle_o
);

    // -----------------------------------------------------------------------
    // Phase register type
    // -----------------------------------------------------------------------
    typedef struct packed {
        logic [15:0] dest_addr;   // scratchpad base addr (SCRATCH) or port ID (PORT)
        logic        dest_type;   // 0 = PORT destination, 1 = SCRATCH destination
        logic [15:0] count;       // count_remaining; 0 = phase inactive
    } phase_reg_t;

    // -----------------------------------------------------------------------
    // State arrays
    // -----------------------------------------------------------------------
    phase_reg_t   phase_regs    [NUM_PORTS-1:0][1:0]; // [port][phase]
    logic         current_phase [NUM_PORTS-1:0];       // active phase per port
    logic [15:0]  phase_counter [NUM_PORTS-1:0];       // elements produced in current phase
    logic         wr_phase_r    [NUM_PORTS-1:0];       // next-write phase tracker per port

    // -----------------------------------------------------------------------
    // Per-port combinatorial routing signals
    // -----------------------------------------------------------------------
    logic [NUM_PORTS-1:0]        route_active;      // out_valid & count > 0
    logic [NUM_PORTS-1:0]        route_to_port;     // active AND dest is a port
    logic [NUM_PORTS-1:0]        route_to_scratch;  // active AND dest is scratchpad
    logic [NUM_PORTS-1:0][15:0]  route_eff_addr;    // effective destination address

    genvar gn;
    generate
        for (gn = 0; gn < NUM_PORTS; gn++) begin : g_route_sig
            assign route_active[gn] =
                out_valid_i[gn] &
                (phase_regs[gn][current_phase[gn]].count != 16'h0);

            assign route_to_port[gn] =
                route_active[gn] &
                (phase_regs[gn][current_phase[gn]].dest_type == 1'b0);

            assign route_to_scratch[gn] =
                route_active[gn] &
                (phase_regs[gn][current_phase[gn]].dest_type == 1'b1);

            // Effective address:
            //   PORT   -> dest_addr is the fixed input port ID (no offset needed)
            //   SCRATCH -> dest_addr is base; phase_counter provides element offset
            assign route_eff_addr[gn] =
                (phase_regs[gn][current_phase[gn]].dest_type == 1'b1)
                ? (phase_regs[gn][current_phase[gn]].dest_addr + phase_counter[gn])
                :  phase_regs[gn][current_phase[gn]].dest_addr;
        end
    endgenerate

    // -----------------------------------------------------------------------
    // Input port routing
    // Iterates high-to-low so the lowest-indexed source wins on conflict.
    // -----------------------------------------------------------------------
    always_comb begin
        in_valid_o = '0;
        in_data_o  = '0;
        for (int s = NUM_PORTS-1; s >= 0; s--) begin
            if (route_to_port[s]) begin
                in_valid_o[route_eff_addr[s][PORT_W-1:0]] = 1'b1;
                in_data_o [route_eff_addr[s][PORT_W-1:0]] = out_data_i[s];
            end
        end
    end

    // -----------------------------------------------------------------------
    // Scratchpad write arbitration
    // Iterates high-to-low so the lowest-indexed port wins on conflict.
    // -----------------------------------------------------------------------
    always_comb begin
        scratch_wr_en_o  = 1'b0;
        scratch_addr_o   = 16'h0;
        scratch_wdata_o  = '0;
        for (int s = NUM_PORTS-1; s >= 0; s--) begin
            if (route_to_scratch[s]) begin
                scratch_wr_en_o  = 1'b1;
                scratch_addr_o   = route_eff_addr[s];
                scratch_wdata_o  = out_data_i[s];
            end
        end
    end

    // -----------------------------------------------------------------------
    // Idle: no port has an active phase
    // -----------------------------------------------------------------------
    logic [NUM_PORTS-1:0] port_has_count;
    generate
        for (gn = 0; gn < NUM_PORTS; gn++) begin : g_idle
            assign port_has_count[gn] =
                (phase_regs[gn][current_phase[gn]].count != 16'h0);
        end
    endgenerate
    assign idle_o = ~(|port_has_count);

    // -----------------------------------------------------------------------
    // Sequential state update
    // -----------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int p = 0; p < NUM_PORTS; p++) begin
                phase_regs[p][0] <= '0;
                phase_regs[p][1] <= '0;
                current_phase[p] <= 1'b0;
                phase_counter[p] <= 16'h0;
                wr_phase_r[p]    <= 1'b0;
            end
        end else if (reset_i) begin
            // Synchronous subsystem reset
            for (int p = 0; p < NUM_PORTS; p++) begin
                phase_regs[p][0] <= '0;
                phase_regs[p][1] <= '0;
                current_phase[p] <= 1'b0;
                phase_counter[p] <= 16'h0;
                wr_phase_r[p]    <= 1'b0;
            end
        end else begin

            // ------------------------------------------------------------------
            // Per-port count decrement, phase_counter increment, phase advance
            // ------------------------------------------------------------------
            for (int p = 0; p < NUM_PORTS; p++) begin
                if (route_active[p]) begin
                    phase_regs[p][current_phase[p]].count <=
                        phase_regs[p][current_phase[p]].count - 16'd1;
                    phase_counter[p] <= phase_counter[p] + 16'd1;

                    if (phase_regs[p][current_phase[p]].count == 16'd1) begin
                        // Last element this phase: advance and reset counter
                        current_phase[p] <= ~current_phase[p];
                        phase_counter[p] <= 16'h0;   // overrides the +1 above
                    end
                end
            end

            // ------------------------------------------------------------------
            // Configuration write (SET_SCRATCH_PORT or SET_PORT_PORT)
            // Targets wr_phase_r for the addressed port; toggles wr_phase_r.
            //
            // Note: if cfg targets the same port+phase that route_active is
            // currently updating, the cfg write takes precedence (later
            // assignment in always_ff wins).  Use WAIT (condition[3]) before
            // reprogramming an active port to avoid this race.
            // ------------------------------------------------------------------
            if (cfg_valid_i) begin
                phase_regs[cfg_out_port_i][wr_phase_r[cfg_out_port_i]].dest_addr
                    <= cfg_dest_addr_i;
                // dest_type: 0 = PORT (SET_PORT_PORT), 1 = SCRATCH (SET_SCRATCH_PORT)
                phase_regs[cfg_out_port_i][wr_phase_r[cfg_out_port_i]].dest_type
                    <= ~cfg_port_port_i;
                phase_regs[cfg_out_port_i][wr_phase_r[cfg_out_port_i]].count
                    <= cfg_count_i;
                wr_phase_r[cfg_out_port_i] <= ~wr_phase_r[cfg_out_port_i];
            end

        end
    end

    // -----------------------------------------------------------------------
    // Simulation checks (excluded from synthesis)
    // -----------------------------------------------------------------------
`ifndef BSG_HIDE_FROM_SYNTHESIS
    always_ff @(posedge clk) begin
        if (rst_n && !reset_i) begin
            // Warn if multiple ports compete for the scratchpad in the same cycle
            if ($countones(route_to_scratch) > 1)
                $display("%m WARNING: %0d ports routing to scratchpad simultaneously at t=%0t",
                         $countones(route_to_scratch), $time);

            // Warn if multiple sources route to the same input port
            for (int d = 0; d < NUM_PORTS; d++) begin
                automatic int cnt = 0;
                for (int s = 0; s < NUM_PORTS; s++) begin
                    if (route_to_port[s] &&
                        (route_eff_addr[s][PORT_W-1:0] == PORT_W'(d)))
                        cnt++;
                end
                if (cnt > 1)
                    $display("%m WARNING: %0d ports routing to in_port[%0d] simultaneously at t=%0t",
                             cnt, d, $time);
            end
        end
    end
`endif

endmodule
