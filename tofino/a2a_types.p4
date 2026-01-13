#include "std_header.p4"

#define EP_SIZE 8

enum bit<2> CONN_PHASE {
    CONN_DISPATCH = 1,
    CONN_COMBINE = 2,
    CONN_UNKNOWN = 0
}

enum bit<2> CONN_SEMANTICS {
    CONN_CONTROL = 0,
    CONN_TX = 1,
    CONN_RX = 2,
    CONN_BITMAP = 3 // only for combine
}

struct a2a_headers_t {  
    eth_h eth; 
    ipv4_h ipv4;
    udp_h udp;
    bth_h bth;
    aeth_h aeth;
    reth_h reth;
    payload_h payload;
    icrc_h icrc;
}


header bridge_h {
    bit<8> ing_rank_id;
    bool has_reth;
    bool has_aeth;
    bool has_payload;
    CONN_PHASE  conn_phase;    // dispatch or combine
    CONN_SEMANTICS conn_semantics;
    bit<32>    channel_id;
    bitmap_tofino_t    bitmap;
    bit<16> payload_len;
}


struct a2a_ingress_metadata_t {
    bool is_roce;
    bridge_h bridge;
}

struct a2a_egress_metadata_t {
    bit<8> eg_rank_id;
    bridge_h bridge;
}

/* Although the bitmap is defined to be 64 bits, we only use lower 32 bits in practice
 * as the total number of ports in tofino is limited to 32 in current design.
 */
struct bitmap_t {
    bit<32> lo;
    bit<32> hi;
}


struct addr_tofino_t {
    bit<32> lo;
    bit<32> hi;
}

typedef bit<32> bitmap_tofino_t;

enum bit<2> DISPATCH_REG_OP {
    OP_NONE = 0,
    OP_INIT = 1,
    OP_READ_INC = 2,
    OP_READ_ADD = 3
} 