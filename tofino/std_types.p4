typedef bit<48> mac_addr_t;
typedef bit<32> ipv4_addr_t;

typedef bit<16> ether_type_t;
const ether_type_t ETHERTYPE_IPV4 = 16w0x0800;

typedef bit<8> ip_protocol_t;
const ip_protocol_t IP_PROTOCOLS_TCP = 6;
const ip_protocol_t IP_PROTOCOLS_UDP = 17;

const bit<16> UDP_PORT_ROCE = 4791;

const bit<8> RDMA_OP_SEND_FIRST = 8w0x00;
const bit<8> RDMA_OP_SEND_MIDDLE = 8w0x01;
const bit<8> RDMA_OP_SEND_LAST = 8w0x02;
const bit<8> RDMA_OP_SEND_LAST_WITH_IMM = 8w0x03;
const bit<8> RDMA_OP_SEND_ONLY = 8w0x04;
const bit<8> RDMA_OP_SEND_ONLY_WITH_IMM = 8w0x05;
const bit<8> RDMA_OP_WRITE_FIRST = 8w0x06;
const bit<8> RDMA_OP_WRITE_MIDDLE = 8w0x07;
const bit<8> RDMA_OP_WRITE_LAST = 8w0x08;
const bit<8> RDMA_OP_WRITE_LAST_WITH_IMM = 8w0x09;
const bit<8> RDMA_OP_WRITE_ONLY = 8w0x0a; // WRITE_ONLY occurs when the message is shorter than RDMA_MTU
const bit<8> RDMA_OP_WRITE_ONLY_WITH_IMM = 8w0x0b;
const bit<8> RDMA_OP_READ_REQ = 8w0x0c;
const bit<8> RDMA_OP_READ_RES_FIRST = 8w0x0d;
const bit<8> RDMA_OP_READ_RES_MIDDLE = 8w0x0e;
const bit<8> RDMA_OP_READ_RES_LAST = 8w0x0f;
const bit<8> RDMA_OP_READ_RES_ONLY = 8w0x10;
const bit<8> RDMA_OP_ACK = 8w0x11;
const bit<8> RDMA_OP_ATOMIC_ACK = 8w0x12;
const bit<8> RDMA_OP_CMPSWAP = 8w0x13;
const bit<8> RDMA_OP_FETCHADD = 8w0x14;
const bit<8> RDMA_OP_CNP = 8w0x81;
const bit<8> RDMA_OP_UD_SEND_ONLY = 8w0x64;

header eth_h {
    mac_addr_t dst_addr;
    mac_addr_t src_addr;
    bit<16> ether_type;
}

header ipv4_h {
    bit<8> ver_ihl;         // version, ihl, 4 + 4
    bit<8> diffserv;
    bit<16> total_len;
    bit<16> identification;
    bit<16> flag_offset;    // flag, frag_offset, 3 + 13
    bit<8> ttl;
    bit<8> protocol;
    bit<16> hdr_checksum;
    ipv4_addr_t src_addr;
    ipv4_addr_t dst_addr;
}

header tcp_h {
    bit<16> src_port;
    bit<16> dst_port;
    bit<32> seq_no;
    bit<32> ack_no;
    bit<8> data_offset_res; // data_offset , res, 4 + 4
    bit<8> flags;
    bit<16> window;
    bit<16> checksum;
    bit<16> urgent_ptr;
}

header udp_h {
    bit<16> src_port;
    bit<16> dst_port;
    bit<16> hdr_length;
    bit<16> checksum;
}


header bth_h {
    bit<8> opcode;
    bit<8> se_migreq_pad_ver; // se = Solicited Event, ver = Transport Header Version, 1 + 1 + 2 + 4
    bit<16> pkey; // Partition Key, like VLAN id, 1 bit permission + 15 bit key 
    bit<8> f_b_rsv; // FECN, BECN, reserved(0), 1 + 1 + 6, FECN may be useless in ROCEv2?
    bit<24> dqpn; // f_b_rsv, dest QPN, 8 + 24
    // bit<8> ackreq_rsv; // the ACK for this packet should be scheduled by the responder, 1 + 7 
    // bit<24> seq_num;// responder is able to send ACK and can decide whether to send ACK.
    // bit<8> ackreq_rsv; // 1 + 7
    bit<32> psn; // ackreq_rsv, psn, 8 + 24
}

header reth_h {
    bit<64> addr; // virtual address
    bit<32> rkey;
    bit<32> len; // DMA length, padding bytes is not included
}

header aeth_h {
    bit<8> syndrome; // 1 bit 0 + 2 bit flag (ACK, RNR NAK, reserved, NAK) + 5 bit number (credit cnt, RNR timer, N/A, NAK code)
    bit<24> msn; // syndrom, 24 bit message sequence number, start from 0
}

header atomic_eth_h {
    bit<64> addr;
    bit<32> rkey;
    bit<64> swapadd_data;
    bit<64> compare_data;
}

header atomic_aeth_h {
    bit<64> original_data;
}

header cnp_h {
    bit<128> reserved;
}

header imm_h {
    bit<32> imm;
}

header payload_h {
    agg_t data00;
    agg_t data01;
    agg_t data02;
    agg_t data03;
    agg_t data04;
    agg_t data05;
    agg_t data06;
    agg_t data07;
    agg_t data08;
    agg_t data09;
    agg_t data0a;
    agg_t data0b;
    agg_t data0c;
    agg_t data0d;
    agg_t data0e;
    agg_t data0f;
    agg_t data10;
    agg_t data11;
    agg_t data12;
    agg_t data13;
    agg_t data14;
    agg_t data15;
    agg_t data16;
    agg_t data17;
    agg_t data18;
    agg_t data19;
    agg_t data1a;
    agg_t data1b;
    agg_t data1c;
    agg_t data1d;
    agg_t data1e;
    agg_t data1f;
    agg_t data20;
    agg_t data21;
    agg_t data22;
    agg_t data23;
    agg_t data24;
    agg_t data25;
    agg_t data26;
    agg_t data27;
    agg_t data28;
    agg_t data29;
    agg_t data2a;
    agg_t data2b;
    agg_t data2c;
    agg_t data2d;
    agg_t data2e;
    agg_t data2f;
    agg_t data30;
    agg_t data31;
    agg_t data32;
    agg_t data33;
    agg_t data34;
    agg_t data35;
    agg_t data36;
    agg_t data37;
    agg_t data38;
    agg_t data39;
    agg_t data3a;
    agg_t data3b;
    agg_t data3c;
    agg_t data3d;
    agg_t data3e;
    agg_t data3f;
}


header icrc_h {
    bit<8> v0;
    bit<8> v1;
    bit<8> v2;
    bit<8> v3;
}
