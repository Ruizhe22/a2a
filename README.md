# A2A: In-Network All-to-All Collective Communication

A P4 implementation of All-to-All collective communication with in-network aggregation for Intel Tofino switches, targeting RoCEv2/RDMA traffic.

## Overview

This project implements an optimized All-to-All collective operation that leverages programmable switches for:

- **Bitmap-based multicast routing** for efficient data distribution
- **In-network aggregation** to reduce network traffic and host CPU overhead
- **Per-receiver PSN/address tracking** for reliable RDMA semantics

The implementation uses the Intel Tofino Native Architecture (TNA) and is designed for 8 endpoints (configurable via `EP_SIZE`).

## Architecture

### Two-Phase Operation

```
┌─────────────────────────────────────────────────────────────────────┐
│                         DISPATCH PHASE                               │
│  TX endpoints scatter data to RX endpoints via bitmap multicast      │
│                                                                      │
│  [TX0] ──┐                                    ┌──▶ [RX0]            │
│  [TX1] ──┼──▶ [Tofino Switch] ──multicast────┼──▶ [RX1]            │
│  [TX2] ──┤    (PSN tracking)                 ├──▶ [RX2]            │
│   ...    │    (Addr management)              │    ...               │
│  [TX7] ──┘                                   └──▶ [RX7]            │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                          COMBINE PHASE                               │
│  Data aggregated in-switch, result sent to root via loopback        │
│                                                                      │
│  [TX0] ──┐                                                          │
│  [TX1] ──┼──▶ [Tofino Switch] ──▶ aggregate ──▶ [Root RX]          │
│  [TX2] ──┤    (bitmap tracking)                                     │
│   ...    │    (in-switch sum)                                       │
│  [TX7] ──┘                                                          │
└─────────────────────────────────────────────────────────────────────┘
```

### File Structure

```
a2a/
├── a2a.p4                    # Main program entry point
├── a2a_types.p4              # Type definitions, headers, metadata
├── std_types.p4              # Standard protocol types and constants
├── a2a_ingress_parser.p4     # Ingress packet parser
├── a2a_ingress_control.p4    # Ingress control logic
├── a2a_egress_parser.p4      # Egress packet parser
├── a2a_egress_control.p4     # Egress control logic
├── dispatch_control.p4       # Dispatch phase implementation
├── combine_control.p4        # Combine phase implementation
├── combine_macros.p4         # Macros for register management
└── README.md                 # This file
```

### Module Descriptions

| File | Description |
|------|-------------|
| `a2a.p4` | Main entry point; instantiates the pipeline |
| `std_types.p4` | Standard Ethernet/IP/UDP/RDMA header definitions and constants |
| `a2a_types.p4` | A2A-specific types: bridge header, metadata structures, enums |
| `a2a_ingress_parser.p4` | Parses L2-L4 headers and RDMA headers based on opcode |
| `a2a_ingress_control.p4` | Traffic classification and dispatch to sub-controls |
| `a2a_egress_parser.p4` | Conditional parsing based on bridge header flags |
| `a2a_egress_control.p4` | Metadata extraction and sub-control dispatch |
| `dispatch_control.p4` | PSN/MSN tracking, bitmap multicast, per-RX state |
| `combine_control.p4` | Aggregation buffer, bitmap completion tracking |
| `combine_macros.p4` | Queue pointer, bitmap, and address slot macros |

## Key Data Structures

### Bridge Header

Carries metadata from ingress to egress pipeline:

```p4
header bridge_h {
    bit<32>        ing_rank_id;      // Source rank identifier
    bit<1>         has_reth;         // RETH header present
    bit<1>         has_aeth;         // AETH header present
    bit<1>         has_payload;      // Payload present
    bit<1>         is_loopback;      // Loopback packet flag
    CONN_PHASE     conn_phase;       // DISPATCH or COMBINE
    CONN_SEMANTICS conn_semantics;   // CONTROL, TX, RX, BITMAP, LOOPBACK
    bit<32>        channel_id;       // Communication channel
    bitmap_tofino_t bitmap;          // Destination bitmap (32 bits)
    bit<32>        tx_loc_val;       // Token location
    bit<32>        tx_offset_val;    // Packet offset within token
    bit<32>        root_rank_id;     // Root for aggregation
    bit<64>        next_token_addr;  // Next token address
    bit<8>         agg_op;           // Aggregation operation
}
```

### Connection Semantics

```p4
enum bit<3> CONN_SEMANTICS {
    CONN_CONTROL  = 0,  // Initialization/control messages
    CONN_TX       = 1,  // Data transmission path
    CONN_RX       = 2,  // Data reception path
    CONN_BITMAP   = 3,  // Bitmap updates (combine only)
    CONN_LOOPBACK = 4   // Loopback for aggregation completion
}
```

## Configuration

### Constants (in `a2a_types.p4` and `combine_control.p4`)

| Constant | Default | Description |
|----------|---------|-------------|
| `EP_SIZE` | 8 | Number of endpoints |
| `LOOPBACK_PORT` | 192 | Port for loopback packets |
| `LOOPBACK_MCAST_GRP` | 200 | Multicast group for loopback |
| `COMBINE_QUEUE_LENGTH` | 64 | Tokens per queue |
| `TOKEN_SIZE` | 7168 | Bytes per token |
| `PAYLOAD_LEN` | 1024 | Bytes per packet payload |

### Table Sizes

| Table | Size | Description |
|-------|------|-------------|
| `traffic_classify` | 128 | Traffic classification entries |
| `dispatch_rank_info` | 1024 | Rank ID lookup |
| `dispatch_rx_info` | 1024 | RX connection info |
| `tbl_in_bitmap` | 64 | Bitmap membership check |
| `tbl_rx_info` | 128 | Combine RX info lookup |

## Building and Running

### Prerequisites

- Intel P4 Studio (SDE) version 9.x or later
- Tofino ASIC or model

### Compilation

```bash
# Set up environment
source /path/to/bf-sde/install/set_sde.bash

# Compile the P4 program
bf-p4c a2a.p4 \
    --target tofino \
    --arch tna \
    -o build/ \
    --p4runtime-files build/a2a.p4info.pb.txt
```

### Running on Tofino Model

```bash
# Start the Tofino model
$SDE/run_tofino_model.sh -p a2a

# In another terminal, start the driver
$SDE/run_switchd.sh -p a2a
```

### Running on Hardware

```bash
# Start the driver on hardware
$SDE/run_switchd.sh -p a2a -- --background

# Load the program
bfshell -b /path/to/setup_script.py
```

## Control Plane Setup

The following tables must be populated by the control plane:

### 1. Traffic Classification

```python
# Example: classify traffic from TX endpoint 0 on channel 0
traffic_classify.add_with_set_a2a_traffic(
    src_addr=0x0A000001,        # TX IP
    dst_addr=0x0A000010,        # Switch IP
    dst_qp=0x00001000,          # QP number
    ingress_port=128,           # Physical port
    conn_phase=CONN_PHASE.CONN_DISPATCH,
    conn_semantics=CONN_SEMANTICS.CONN_TX,
    channel_id=0,
    channel_class=0,
    ing_rank_id=0,
    root_rank_id=0,
    reg_idx=0
)
```

### 2. Dispatch RX Info

```python
# Map channel + rank to destination RX endpoint
dispatch_rx_info.add_with_set_rx_info(
    channel_id=0,
    eg_rank_id=1,
    dst_mac=0x001122334456,
    dst_ip=0x0A000002,
    dst_qp=0x00002000,
    rkey=0x12345678
)
```

### 3. Bitmap Membership

```python
# Configure which ranks are in each bitmap
tbl_in_bitmap.add_with_set_in_bitmap(
    bitmap=0x0000000F,  # Ranks 0-3
    eg_rank_id=0,
    cmp=0               # 0 = in bitmap
)
```

### 4. Multicast Groups

```bash
# Create multicast group 100 for all-to-all broadcast
mc_mgrp_create 100
mc_node_create 100 128 129 130 131 132 133 134 135
mc_associate_node 100 100
```

## Performance Considerations

- **Register Access**: Each endpoint uses dedicated register slots to avoid conflicts
- **Macro-based Design**: Uses macros instead of sub-controls to avoid Tofino compiler variable duplication issues
- **64-bit Address Split**: Addresses stored as two 32-bit registers due to Tofino ALU limitations
- **Circular Queue**: Token queues wrap around at `COMBINE_QUEUE_LENGTH`

## Limitations

- Maximum 32 endpoints (limited by `bitmap_tofino_t` width)
- Currently configured for 8 endpoints
- Single aggregation operation (sum) implemented
- Fixed token and payload sizes

## Troubleshooting

### Common Issues

1. **Compilation errors about duplicate variables**: Ensure macros are used correctly in `combine_control.p4`

2. **Packets dropped unexpectedly**: Check `tbl_in_bitmap` entries and bitmap values

3. **PSN sequence errors**: Verify register initialization via control connection

4. **Missing ACKs**: Ensure `traffic_classify` entries exist for both TX and RX directions

### Debug Tips

```bash
# Check table entries
bfshell> bfrt.a2a.pipe.A2AIngress.traffic_classify.dump()

# Check register values
bfshell> bfrt.a2a.pipe.DispatchIngress.reg_tx_epsn.dump()

# Monitor counters
bfshell> bfrt.a2a.pipe.A2AIngress.$COUNTER_SPEC.dump()
```

## License

[Add your license here]

## References

- [P4_16 Language Specification](https://p4.org/p4-spec/docs/P4-16-v1.2.4.html)
- [Tofino Native Architecture (TNA)](https://github.com/barefootnetworks/Open-Tofino)
- [RoCEv2 Specification](https://cw.infinibandta.org/document/dl/7781)
