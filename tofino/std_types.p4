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
    bit<16> length;
    bit<16> checksum;
}


header bth_h {
    bit<8> opcode;
    bit<8> se_migreq_pad_ver; // se = Solicited Event, ver = Transport Header Version, 1 + 1 + 2 + 4
    bit<16> pkey; // Partition Key, like VLAN id, 1 bit permission + 15 bit key 
    //bit<8> f_b_rsv; // FECN, BECN, reserved(0), 1 + 1 + 6, FECN may be useless in ROCEv2?
    bit<32> dst_qp; // f_b_rsv, dest QPN, 8 + 24
    // bit<8> ackreq_rsv; // the ACK for this packet should be scheduled by the responder, 1 + 7 
    // bit<24> seq_num;// responder is able to send ACK and can decide whether to send ACK.
    bit<32> psn; // ackreq_rsv + psn, 24
}

header reth_h {
    bit<64> addr; // virtual address
    bit<32> rkey;
    bit<32> len; // DMA length, padding bytes is not included
}

// --- ACK Syndrome Values ---

const bit<32> AETH_ACK_CREDIT_INVALID = 32w0x1F;  // Binary: 000 11111 (Op:00, Credit:31/Invalid)
const bit<32> AETH_ACK_CREDIT_ZERO = 32w0x00;  // Binary: 000 00000 (Op:00, Credit:0)

// --- NAK Syndrome Values (OpCode: 11) --- Binary: 011 NNNNN
const bit<32> AETH_NAK_SEQ_ERR = 32w0x60;  // NAK Code 0: PSN Sequence Error
const bit<32> AETH_NAK_INV_REQ = 32w0x61;  // NAK Code 1: Invalid Request
const bit<32> AETH_NAK_R_ACC_ERR = 32w0x62;  // NAK Code 2: Remote Access Error

header aeth_h {
     // 1 bit 0 + 2 bit flag [6:5] (ACK, RNR NAK, reserved, NAK) + 5 bit number (credit cnt, RNR timer, N/A, NAK code)
    bit<32> msn; // syndrom, 24 bit message sequence number, start from 0
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

/* in dispatch, for tx, epsn is the next psn to switch,
 *              for rx, epsn is the next psn to rx
 */
typedef bit<32> init_epsn_t; 
typedef bit<64> init_addr_t;


header icrc_h {
    bit<8> v0;
    bit<8> v1;
    bit<8> v2;
    bit<8> v3;
}
