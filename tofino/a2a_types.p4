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
    CONN_BITMAP = 3, // only for combine
}

// partial payload size which can be processed by tofino stages while remaining payload is in the real packet payload
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
    bit<32> data18;
    bit<32> data19;
    bit<32> data1a;
    bit<32> data1b;
    bit<32> data1c;
    bit<32> data1d;
    bit<32> data1e;
    bit<32> data1f;
}

#define PAYLOAD_HEADER_LEN 128 // bytes

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
    // dispatch or combine 8bytes
    bit<8> ing_rank_id;
    bool has_reth;
    bool has_aeth;
    bool has_payload;
    CONN_PHASE  conn_phase;    
    CONN_SEMANTICS conn_semantics;
    bit<16>  channel_id;
    bitmap_tofino_t    bitmap;
    // combine only, 5bytes
    bit<8> tx_loc_val;
    bit<8> tx_offset_val;
    bit<8> clear_offset;
    bool is_loopback;
    bit<8> root_rank_id
    // 8 bit
    bit<64> next_token_addr;
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
    OP_INIT = 0,
    OP_READ_INC = 1,
    OP_READ_ADD = 2
} 

enum bit<2> COMBINE_QUEUE_POINTER_REG_OP {
    OP_INIT     = 0,
    OP_READ     = 1,
    OP_INC    = 2,
    OP_READ_ADD = 3     // 读取并加固定值8（环形）
}

enum bit<2> COMBINE_BITMAP_REG_OP {
    OP_READ      = 1,
    OP_WRITE     = 2,
    OP_CLEAR_BIT = 3,    // XOR 清除指定位，返回清除后的值
    OP_RESET     = 0     // 重置为 0
}

enum bit<2> COMBINE_ADDR_REG_OP {
    OP_RESET  = 0,
    OP_READ  = 1,
    OP_WRITE = 2
}

#define LOOPBACK_MCAST_GRP 200