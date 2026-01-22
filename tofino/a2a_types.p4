#include "std_types.p4"


// @pa_container_size("ingress", "hdr.payload.data00", 32)
// @pa_container_size("ingress", "hdr.payload.data01", 32)
// @pa_container_size("ingress", "hdr.payload.data02", 32)
// @pa_container_size("ingress", "hdr.payload.data03", 32)
// @pa_container_size("ingress", "hdr.payload.data04", 32)
// @pa_container_size("ingress", "hdr.payload.data05", 32)
// @pa_container_size("ingress", "hdr.payload.data06", 32)
// @pa_container_size("ingress", "hdr.payload.data07", 32)
// @pa_container_size("ingress", "hdr.payload.data08", 32)
// @pa_container_size("ingress", "hdr.payload.data09", 32)
// @pa_container_size("ingress", "hdr.payload.data0a", 32)
// @pa_container_size("ingress", "hdr.payload.data0b", 32)
// @pa_container_size("ingress", "hdr.payload.data0c", 32)
// @pa_container_size("ingress", "hdr.payload.data0d", 32)
// @pa_container_size("ingress", "hdr.payload.data0e", 32)
// @pa_container_size("ingress", "hdr.payload.data0f", 32)
// @pa_container_size("ingress", "hdr.payload.data10", 32)
// @pa_container_size("ingress", "hdr.payload.data11", 32)
// @pa_container_size("ingress", "hdr.payload.data12", 32)
// @pa_container_size("ingress", "hdr.payload.data13", 32)
// @pa_container_size("ingress", "hdr.payload.data14", 32)
// @pa_container_size("ingress", "hdr.payload.data15", 32)
// @pa_container_size("ingress", "hdr.payload.data16", 32)
// @pa_container_size("ingress", "hdr.payload.data17", 32)




#define EP_SIZE 8

#define LOOPBACK_PORT 192

typedef bit<32> bitmap_tofino_t;

typedef bit<64> addr_tofino_t; 
typedef bit<32> addr_half_t ;

enum bit<8> AGG_OP {
    STORE = 0,
    AGGREGATE = 1
}


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

// partial payload size which can be processed by tofino stages while remaining payload is in the real packet payload
header payload_h {
    bit<32> data00;
    // bit<32> data01;
    // bit<32> data02;
    // bit<32> data03;
    // bit<32> data04;
    // bit<32> data05;
    // bit<32> data06;
    // bit<32> data07;
    // bit<32> data08;
    // bit<32> data09;
    // bit<32> data0a;
    // bit<32> data0b;
    // bit<32> data0c;
    // bit<32> data0d;
    // bit<32> data0e;
    // bit<32> data0f;
    // bit<32> data10;
    // bit<32> data11;
    // bit<32> data12;
    // bit<32> data13;
    // bit<32> data14;
    // bit<32> data15;
    // bit<32> data16;
    // bit<32> data17;
}

header payload_word_h {
    bit<32> data;
}

#define PAYLOAD_HEADER_LEN 128 // bytes

header bridge_h {
    // dispatch or combine 8bytes
    bit<32> ing_rank_id;
    bool has_reth;
    bool has_aeth;
    bool has_payload;
    bool is_loopback;
    CONN_PHASE  conn_phase;  
    CONN_SEMANTICS conn_semantics;
    bit<32>  channel_id;
    bitmap_tofino_t    bitmap;
    // combine only, 5bytes
    bit<32> tx_loc_val;
    bit<32> tx_offset_val;

    bit<32> root_rank_id;
    // 8
    bit<64> next_token_addr;
    bit<8> agg_op;
}

struct a2a_headers_t {
    bridge_h bridge;  
    eth_h eth; 
    ipv4_h ipv4;
    udp_h udp;
    bth_h bth;
    aeth_h aeth;
    reth_h reth;
    payload_word_h payload_first_word;
    payload_h payload;
    icrc_h icrc;
}


struct a2a_ingress_metadata_t {
    bit<32> diff;
    bit<32> cmp; // 0==, 1>, 2<
    
    
    bit<32> psn;
    bit<32> msn;
    bit<32> syndrome;
    bit<32> channel_class;

    bit<32> tmp_a;
    bit<32> tmp_b;
    bit<32> tmp_c;
    bit<32> tmp_d;
    bit<32> tmp_e;
    // bridge
    bit<32> ing_rank_id;
    
    bool is_roce;
    bool has_reth;
    bool has_aeth;
    bool has_payload;
    CONN_PHASE  conn_phase;  
    CONN_SEMANTICS conn_semantics;
    bool is_loopback;
    bit<8> agg_op;

    bit<32>  channel_id;

    bitmap_tofino_t    bitmap;
    bit<32> tx_reg_idx;

    bit<32> tx_loc_val;
    bit<32> tx_offset_val;

    bit<32> root_rank_id;

    bit<64> next_token_addr;

}

struct a2a_egress_metadata_t {
    bit<32> diff;
    bit<32> cmp; // 0==, 1>, 2<
    // bridge header
    bit<32> ing_rank_id;
    bool has_reth;
    bool has_aeth;
    bool has_payload;
    bool is_loopback;
    CONN_PHASE  conn_phase;  
    CONN_SEMANTICS conn_semantics;
    bit<32>  channel_id;
    bitmap_tofino_t    bitmap;
    // combine only, 5bytes
    bit<32> tx_loc_val;
    bit<32> tx_offset_val;

    bit<32> root_rank_id;
    // 8
    bit<64> next_token_addr;
    bit<8> agg_op;
    
    // 
    bit<32> psn;
    bit<32> eg_rank_id;
    bit<32> egress_rid;

    //
    bit<32> tmp_a;
    bit<32> tmp_b;
    bit<32> tmp_c;

}

/* Although the bitmap is defined to be 64 bits, we only use lower 32 bits in practice
 * as the total number of ports in tofino is limited to 32 in current design.
 */
struct bitmap_t {
    bit<32> lo;
    bit<32> hi;
}


enum bit<2> DISPATCH_REG_OP {
    OP_INIT = 0,
    OP_READ_INC = 1,
    OP_READ_ADD = 2
} 

enum bit<2> COMBINE_QUEUE_POINTER_REG_OP {
    OP_INIT     = 0,
    OP_READ     = 1,
    OP_INC    = 2,
    OP_READ_ADD = 3     // read and add a fixed value 8 (circular)
}

enum bit<2> COMBINE_BITMAP_REG_OP {
    OP_READ      = 1,
    OP_WRITE     = 2,
    OP_CLEAR_BIT = 3,    // XOR clear specified bit(s), return value after clear
    OP_RESET     = 0     // reset to 0
}

enum bit<2> COMBINE_ADDR_REG_OP {
    OP_RESET  = 0,
    OP_READ  = 1,
    OP_WRITE = 2
}

#define LOOPBACK_MCAST_GRP 200