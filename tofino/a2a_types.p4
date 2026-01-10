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

struct a2a_ingress_headers_t {  
    eth_h eth; 
    ipv4_h ipv4;
    udp_h udp;
    bth_h bth;
    aeth_h aeth;
    reth_h reth;
    payload_h payload;
    icrc_h icrc;
}

struct a2a_ingress_metadata_t {
    bool is_roce;
    CONN_PHASE  conn_phase;    // dispatch or combine
    CONN_SEMANTICS conn_semantics;
    bit<32>    channel_id;
}

struct a2a_dispatch_metadata_t {
    bit<32> tx_id;
    bit<32> channel_id;
    bit<32> rx_id;
    bit<32> tx_reg_idx;
    bit<32> rx_reg_idx;
    bit<64> bitmap;
    bit<32> expected_psn;
    bit<32> current_msn;
    bit<32> pkt_psn;
    bit<2>  packet_type;
    bit<2>  psn_status;
    bit<1>  is_write_first_or_only;
    bit<16> payload_len;
}

struct a2a_combine_metadata_t {
    bit<32> rx_id;           // combine中的发送方（原dispatch的rx）
    bit<32> channel_id;
    bit<32> tx_id;           // combine中的接收方（原dispatch的tx）
    bit<32> reg_idx;
    bit<32> expected_psn;
    bit<32> current_msn;
    bit<32> pkt_psn;
    bit<2>  packet_type;
    bit<2>  psn_status;
    bit<16> payload_len;
    // combine特有：聚合相关
    bit<32> agg_count;       // 已聚合的数量
    bit<32> agg_total;       // 需要聚合的总数
}

