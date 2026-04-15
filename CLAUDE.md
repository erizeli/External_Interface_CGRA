The ISA for our dual-mode CGRA/systolic array is shown below. We have a 16 bit on-ramp and 16-bit offramp bus for  shared instruction and data. I am looking to design a 1. depacketizer FSM that routes instructions to a 2. Instruction FIFO that goes to a 3. Decoder, or routes data to a memory address (MMIO). Also, a recurrence engine that consists like the following: 

**Per output tile routing slot:**

PHASE REGISTERS:
  - \[phase 0]  dest_addr, dest_type, count_remaining
  - \[phase 1]  dest_addr, dest_type, count_remaining

CONTROL:
  - current_phase   - 0 or 1
  - phase_counter   - increments per element produced

On each cycle that output_tile[n] produces a value:
  1. read current_phase
  2. decrement count_remaining for that phase
  3. route value to dest for current_phase
  4. if count_remaining == 0: increment current_phase


  The ISA is below:

## 1. Overview

- **Instruction Width:** 32 bits, fixed-length
- **Address Width:** 16 bits
- **Modes:** CGRA, Systolic Array
- **Contexts:** 4 (2-bit context ID)
- **Host Interface:** Memory-Mapped I/O (MMIO)
- **Opcode Field:** bits [31:28] (4 bits, 16 instruction slots)

## 2. Instruction Encoding Summary

| Opcode | Mnemonic           | Category | Encoding (bits 27:0)                                                |
| ------ | ------------------ | -------- | ------------------------------------------------------------------- |
| 0x0    | NOP                | Control  | `[27:0] reserved`                                                   |
| 0x1    | SET_MODE           | Control  | `[0] mode`                                                          |
| 0x2    | RESET              | Control  | `[5:0] subsystem_mask`                                              |
| 0x3    | WAIT               | Control  | `[4:0] condition`                                                   |
| 0x4    | LOAD               | Memory   | `[27:12] addr [11:0] length`                                        |
| 0x5    | STORE              | Memory   | `[27:12] addr [11:0] length`                                        |
| 0x6    | SET_SCRATCH_PORT   | Memory   | `[27:12] scratch_addr [11:8] port [7:0] num_cycles`                 |
| 0x7    | SET_PORT_PORT      | Memory   | `[27:24] out_port [23:20] in_port [19:4] num_cycles [3:0] reserved` |
| 0x8    | STORE_PORT_SCRATCH | Memory   | `[27:24] port [23:8] scratch_addr [7:0] reserved`                   |
| 0x9    | CFG_LOAD           | Config   | `[1:0] context`                                                     |
| 0xA    | CFG_SET            | Config   | `[1:0] context`                                                     |
| 0xB    | CFG_CLR            | Config   | `[1:0] context`                                                     |
| 0xC    | LOAD_WEIGHTS       | System   | `[27:0] reserved`                                                   |
| 0xD    | RUN                | Exec     | `[27:12] count [11:8] i_port [7:4] o_port [3:0] reserved`           |
| 0xE–F  | *(reserved)*       | —        | —                                                                   |

## 3. Instruction Details

### 3.1 Control Instructions

#### NOP (0x0)
```
31      28 27                              0
┌────────┬──────────────────────────────────┐
│  0000  │           reserved (0)           │
└────────┴──────────────────────────────────┘
```
No operation. Pipeline advances with no side effects.

---

#### SET_MODE (0x1)
```
31      28 27       1  0
┌────────┬───────────┬───┐
│  0001  │  reserved │ M │
└────────┴───────────┴───┘
```
| Field | Bits | Description            |
|-------|------|------------------------|
| M     | 0    | 0 = CGRA, 1 = Systolic |

**Precondition:** Must stall until `pe_idle` is asserted.

---

#### RESET (0x2)
```
31      28 27         6  5                0
┌────────┬─────────────┬──────────────────┐
│  0010  │   reserved  │  subsystem_mask  │
└────────┴─────────────┴──────────────────┘
```
| Bit | Subsystem              |
|-----|------------------------|
| 0   | PE array               |
| 1   | Scratchpad             |
| 2   | I/O tiles              |
| 3   | Recurrence engine      |
| 4   | Instruction FIFO + decoder |
| 5   | Configuration registers |

Multiple bits may be set to reset several subsystems simultaneously.

---

#### WAIT (0x3)
```
31      28 27         5  4                0
┌────────┬─────────────┬──────────────────┐
│  0011  │   reserved  │    condition     │
└────────┴─────────────┴──────────────────┘
```
| bit | Condition        |
|-----|------------------|
| 0   | Scratch write complete |
| 1   | Scratch read complete  |
| 2   | Scratch idle           |
| 3   | Recurrence engine idle |
| 4   | Output queue empty     |

Stalls instruction issue until **all** indicated conditions are true.

---

### 3.2 Memory Instructions

#### LOAD (0x4)
```
31      28 27              12 11           0
┌────────┬──────────────────┬──────────────┐
│  0100  │      addr[15:0]  │ length[11:0] │
└────────┴──────────────────┴──────────────┘
```
Host → chip transfer via MMIO write. Transfers `length` words starting at host address `addr` into the chip's memory-mapped space. LOAD_ADDR, LOAD_LENGTH,  and LOAD_READY are registers that dictate where data goes when it streams in.

---

#### STORE (0x5)
```
31      28 27              12 11           0
┌────────┬──────────────────┬──────────────┐
│  0101  │      addr[15:0]  │ length[11:0] │
└────────┴──────────────────┴──────────────┘
```
Chip → host transfer via MMIO read. Reads `length` words from the chip starting at address `addr` back to the host.

---

#### SET_SCRATCH_PORT (0x6)
```
31      28 27              12 11    8 7            0
┌────────┬──────────────────┬───────┬──────────────┐
│  0110  │ scratch_addr[15:0]│ port  │  num_cycles  │
└────────┴──────────────────┴───────┴──────────────┘
```
Creates a recurrence engine entry binding `scratch_addr` to vector `port` for `num_cycles` cycles. Data flows between scratchpad and the CGRA/systolic port.

---

#### SET_PORT_PORT (0x7)
```
31      28 27    24 23    20 19                4 3    0
┌────────┬────────┬────────┬───────────────────┬──────┐
│  0111  │out_port│in_port │   num_cycles[15:0]│ rsvd │
└────────┴────────┴────────┴───────────────────┴──────┘
```
Creates a recurrence engine entry connecting `out_port` to `in_port` for `num_cycles` cycles (port-to-port forwarding without scratchpad).

---

#### STORE_PORT_SCRATCH (0x8)
```
31      28 27    24 23               8 7            0
┌────────┬────────┬──────────────────┬──────────────┐
│  1000  │  port  │ scratch_addr[15:0]│   reserved   │
└────────┴────────┴──────────────────┴──────────────┘
```
Writes the current value on output `port` into scratchpad at `scratch_addr`.

---

### 3.3 Configuration Instructions

#### CFG_LOAD (0x9)
```
31      28 27          2 1  0
┌────────┬──────────────┬────┐
│  1001  │   reserved   │ cx │
└────────┴──────────────┴────┘
```
Loads configuration bitstream into context register `cx` (0–3). Configuration memory is memory-mapped, so no explicit address field is needed.

---

#### CFG_SET (0xA)
```
31      28 27          2 1  0
┌────────┬──────────────┬────┐
│  1010  │   reserved   │ cx │
└────────┴──────────────┴────┘
```
Applies configuration from context `cx` to the CGRA fabric.

**Precondition:** Must stall until `pe_idle` is asserted.

---

#### CFG_CLR (0xB)
```
31      28 27          2 1  0
┌────────┬──────────────┬────┐
│  1011  │   reserved   │ cx │
└────────┴──────────────┴────┘
```
Invalidates context `cx` by clearing its valid bit.

---

### 3.4 System Instructions

#### LOAD_WEIGHTS (0xC)
```
31      28 27                              0
┌────────┬──────────────────────────────────┐
│  1100  │           reserved (0)           │
└────────┴──────────────────────────────────┘
```
Loads weights from scratchpad into the systolic array weight registers. Weight memory is memory-mapped.

---

### 3.5 Execution Instructions

#### RUN (0xD)
```
31      28 27              12 11    8 7     4 3    0
┌────────┬──────────────────┬───────┬───────┬──────┐
│  1101  │   count[15:0]    │i_port │o_port │ rsvd │
└────────┴──────────────────┴───────┴───────┴──────┘
```
| Field  | Bits  | Description                          |
|--------|-------|--------------------------------------|
| count  | 27:12 | Number of compute iterations (16-bit)|
| i_port | 11:8  | Input vector port                    |
| o_port | 7:4   | Output vector port                   |

**Preconditions:** Must stall until `pe_idle` is asserted and a valid configuration has been applied via `CFG_SET`.

---

## 4. Field Summary

| Field         | Width  | Range / Values                        |
|---------------|--------|---------------------------------------|
| opcode        | 4 bits | 0x0 – 0xD (0xE–0xF reserved)         |
| addr          | 16 bits| 0x0000 – 0xFFFF                       |
| length        | 12 bits| 1 – 4095 words                        |
| port          | 4 bits | 0 – 15                                |
| context (cx)  | 2 bits | 0 – 3                                 |
| mode          | 1 bit  | 0 = CGRA, 1 = Systolic               |
| subsystem_mask| 6 bits | bitmask                               |
| condition     | 5 bits | bitmask                               |
| count         | 16 bits| iteration count for RUN               |
| num_cycles    | 8 or 16 bits | recurrence duration              |

## 5. MMIO Address Map

| Region               | Purpose                                   |
|----------------------|-------------------------------------------|
| Configuration memory | CFG_LOAD target (context bitstreams)       |
| Weight memory        | LOAD_WEIGHTS source (systolic weights)     |
| Input ports          | CGRA/systolic input data via host writes   |
| Output ports         | CGRA/systolic output data via host reads   |
| Scratchpad           | On-chip reuse buffer                       |

## 6. Execution Constraints

1. **SET_MODE** — must wait for `pe_idle` before switching mode.
2. **CFG_SET** — must wait for `pe_idle` before applying configuration.
3. **RUN** — must wait for `pe_idle` and requires a prior `CFG_SET` with a valid context.
4. **LOAD_WEIGHTS** — scratchpad must contain valid weight data before issuing.
5. Reserved bits should be written as 0; behavior is undefined otherwise.
