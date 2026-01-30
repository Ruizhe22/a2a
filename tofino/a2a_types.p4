/**
 * @file a2a_types.p4
 * @brief Type definitions and structures for All-to-All communication
 *
 * This file defines the headers, metadata structures, and enumerations
 * specific to the A2A (All-to-All) collective communication pipeline.
 */

#include "std_types.p4"

/* =============================================================================
 * Configuration Constants
 * ============================================================================= */

#define EP_SIZE       8    // Number of endpoints
#define LOOPBACK_PORT 192  // Port used for loopback packets

/* Payload header length in bytes */
#define PAYLOAD_HEADER_LEN 128

/* Multicast group for loopback traffic */
#define LOOPBACK_MCAST_GRP 200

/* =============================================================================
 * Type Definitions
 * ============================================================================= */

/** Bitmap type for Tofino (limited to 32 ports) */
typedef bit<32> bitmap_tofino_t;

/** 64-bit address type for Tofino registers */
typedef bit<64> addr_tofino_t;

/** 32-bit address half for split address storage */
typedef bit<32> addr_half_t;

/* =============================================================================
 * Enumerations
 * ============================================================================= */

/**
 * Aggregation operation types
 */
enum bit<8> AGG_OP {
    STORE     = 0,  // Store value without aggregation
    AGGREGATE = 1   // Add to existing value
}

/**
 * Connection phase in the A2A pipeline
 */
enum bit<1> CONN_PHASE {
    CONN_DISPATCH = 0,  // Dispatch phase: scatter data to receivers
    CONN_COMBINE  = 1   // Combine phase: aggregate data from senders
}

/**
 * Connection semantics (traffic type)
 */
enum bit<3> CONN_SEMANTICS {
    CONN_CONTROL  = 0,  // Control messages for initialization
    CONN_TX       = 1,  // Transmit data path
    CONN_RX       = 2,  // Receive data path
    CONN_BITMAP   = 3,  // Bitmap updates (combine phase only)
    CONN_LOOPBACK = 4   // Loopback for aggregation completion
}

/**
 * Dispatch register operations
 */
enum bit<2> DISPATCH_REG_OP {
    OP_INIT     = 0,  // Initialize register to zero
    OP_READ_INC = 1,  // Read and increment by 1
    OP_READ_ADD = 2   // Read and add a value
}

/**
 * Combine queue pointer register operations
 */
enum bit<2> COMBINE_QUEUE_POINTER_REG_OP {
    OP_INIT     = 0,  // Initialize to zero
    OP_READ     = 1,  // Read current value
    OP_INC      = 2,  // Increment by 1
    OP_READ_ADD = 3   // Read and add fixed value 8 (circular)
}

/**
 * Combine bitmap register operations
 */
enum bit<2> COMBINE_BITMAP_REG_OP {
    OP_RESET     = 0,  // Reset to zero
    OP_READ      = 1,  // Read current value
    OP_WRITE     = 2,  // Write new value
    OP_CLEAR_BIT = 3   // XOR to clear bit(s), return result
}

/**
 * Combine address register operations
 */
enum bit<2> COMBINE_ADDR_REG_OP {
    OP_RESET = 0,  // Reset to zero
    OP_READ  = 1,  // Read current value
    OP_WRITE = 2   // Write new value
}

/* =============================================================================
 * Header Definitions
 * ============================================================================= */

/**
 * Payload header for in-switch processing
 *
 * Contains a partial payload (96 bytes / 24 words) that can be processed
 * by Tofino stages while the remaining payload stays in the packet body.
 */
header payload_h {
    bit<32> data00;
    bit<32> data01;
    bit<32> data02;
    bit<32> data03;
    bit<32> data04;
    bit<32> data05;
    bit<32> data06;
    bit<32> data07;
    bit<32> data08;
    bit<32> data09;
    bit<32> data0a;
    bit<32> data0b;
    bit<32> data0c;
    bit<32> data0d;
    bit<32> data0e;
    bit<32> data0f;
    bit<32> data10;
    bit<32> data11;
    bit<32> data12;
    bit<32> data13;
    bit<32> data14;
    bit<32> data15;
    bit<32> data16;
    bit<32> data17;
}

/**
 * Single payload word header
 */
header payload_word_h {
    bit<32> data;
}

/**
 * Bridge header for ingress-to-egress metadata passing
 *
 * This header carries metadata from ingress to egress pipeline,
 * including connection information and aggregation state.
 */
header bridge_h {
    /* Dispatch/Combine common fields (8 bytes) */
    bit<32>        ing_rank_id;      // Ingress rank identifier
    bit<1>         has_reth;         // RETH header present
    bit<1>         has_aeth;         // AETH header present
    bit<1>         has_payload;      // Payload present
    bit<1>         is_loopback;      // Loopback packet flag
    CONN_PHASE     conn_phase;       // Dispatch or Combine
    CONN_SEMANTICS conn_semantics;   // Traffic type
    bit<32>        channel_id;       // Communication channel
    bitmap_tofino_t bitmap;          // Destination bitmap

    /* Combine-specific fields */
    bit<32> tx_loc_val;              // Token location value
    bit<32> tx_offset_val;           // Packet offset within token

    bit<32> root_rank_id;            // Root rank for aggregation

    /* Token address (8 bytes) */
    bit<64> next_token_addr;         // Address for next token
    bit<8>  agg_op;                  // Aggregation operation
}

/* =============================================================================
 * Header Stack Definition
 * ============================================================================= */

/**
 * Complete header stack for A2A packets
 */
struct a2a_headers_t {
    eth_h          eth;
    ipv4_h         ipv4;
    udp_h          udp;
    bth_h          bth;
    bridge_h       bridge;
    aeth_h         aeth;
    reth_h         reth;
    payload_word_h payload_first_word;
    payload_h      payload;
    icrc_h         icrc;
}

/* =============================================================================
 * Metadata Structures
 * ============================================================================= */

/**
 * Ingress pipeline metadata
 */
struct a2a_ingress_metadata_t {
    /* PSN comparison state */
    bit<32> psn_diff;    // PSN difference for comparison
    bit<8>  psn_cmp;     // Comparison result: 0=equal, 1=greater, 2=less

    /* Packet state */
    bit<32> psn;         // Packet Sequence Number
    bit<32> msn;         // Message Sequence Number
    bit<32> syndrome;    // AETH syndrome value
    bit<32> channel_class; // Channel classification

    /* Temporary variables for computation */
    bit<32> tmp_a;
    bit<32> tmp_b;
    bit<32> tmp_c;
    bit<32> tmp_d;
    bit<32> tmp_e;

    /* Bridge header fields */
    bit<32> ing_rank_id;   // Ingress rank identifier

    /* Packet type flags */
    bool is_roce;          // RoCEv2 packet
    bool has_reth;         // RETH header present
    bool has_aeth;         // AETH header present
    bool has_payload;      // Payload present

    /* Connection metadata */
    CONN_PHASE     conn_phase;       // Dispatch or Combine
    CONN_SEMANTICS conn_semantics;   // Traffic type
    bool           is_loopback;      // Loopback packet flag
    bit<8>         agg_op;           // Aggregation operation

    bit<32> channel_id;              // Communication channel

    /* Bitmap and TX state */
    bitmap_tofino_t bitmap;          // Destination bitmap
    bit<32>         tx_reg_idx;      // TX register index

    bit<32> tx_loc_val;              // Token location value
    bit<32> tx_offset_val;           // Packet offset within token

    bit<32> root_rank_id;            // Root rank for aggregation

    bit<64> next_token_addr;         // Address for next token
}

/**
 * Egress pipeline metadata
 */
struct a2a_egress_metadata_t {
    /* Comparison state */
    bit<32> diff;    // Value difference
    bit<32> cmp;     // Comparison result: 0=equal, 1=greater, 2=less

    /* Bridge header fields (copied from header) */
    bit<32>        ing_rank_id;
    bool           has_reth;
    bool           has_aeth;
    bool           has_payload;
    bool           is_loopback;
    CONN_PHASE     conn_phase;
    CONN_SEMANTICS conn_semantics;
    bit<32>        channel_id;
    bitmap_tofino_t bitmap;

    /* Combine-specific fields */
    bit<32> tx_loc_val;
    bit<32> tx_offset_val;

    bit<32> root_rank_id;

    /* Token address */
    bit<64> next_token_addr;
    bit<8>  agg_op;

    /* Egress state */
    bit<32> psn;           // Packet Sequence Number
    bit<32> eg_rank_id;    // Egress rank identifier
    bit<32> egress_rid;    // Egress replication ID

    /* Temporary variables */
    bit<32> tmp_a;
    bit<32> tmp_b;
    bit<32> tmp_c;
}

/* =============================================================================
 * Auxiliary Structures
 * ============================================================================= */

/**
 * Bitmap structure for 64-bit operations
 *
 * Note: Although defined as 64 bits, only the lower 32 bits are used
 * since Tofino is limited to 32 ports in the current design.
 */
struct bitmap_t {
    bit<32> lo;  // Lower 32 bits (actively used)
    bit<32> hi;  // Upper 32 bits (reserved)
}
