/**
 * @file std_types.p4
 * @brief Standard type definitions and constants for RoCEv2 packet processing
 *
 * This file contains fundamental type definitions, protocol constants,
 * and header definitions used throughout the A2A (All-to-All) pipeline.
 */

/* =============================================================================
 * Type Definitions
 * ============================================================================= */

typedef bit<48> mac_addr_t;
typedef bit<32> ipv4_addr_t;
typedef bit<16> ether_type_t;
typedef bit<8>  ip_protocol_t;

/* =============================================================================
 * Protocol Constants
 * ============================================================================= */

/* Ethernet */
const ether_type_t ETHERTYPE_IPV4 = 16w0x0800;

/* IP Protocol Numbers */
const ip_protocol_t IP_PROTOCOLS_TCP = 6;
const ip_protocol_t IP_PROTOCOLS_UDP = 17;

/* RoCEv2 UDP Port */
const bit<16> UDP_PORT_ROCE = 4791;

/* =============================================================================
 * RDMA Operation Codes (InfiniBand BTH Opcodes)
 * ============================================================================= */

/* Send Operations */
const bit<8> RDMA_OP_SEND_FIRST        = 8w0x00;
const bit<8> RDMA_OP_SEND_MIDDLE       = 8w0x01;
const bit<8> RDMA_OP_SEND_LAST         = 8w0x02;
const bit<8> RDMA_OP_SEND_LAST_WITH_IMM = 8w0x03;
const bit<8> RDMA_OP_SEND_ONLY         = 8w0x04;
const bit<8> RDMA_OP_SEND_ONLY_WITH_IMM = 8w0x05;

/* Write Operations */
const bit<8> RDMA_OP_WRITE_FIRST        = 8w0x06;
const bit<8> RDMA_OP_WRITE_MIDDLE       = 8w0x07;
const bit<8> RDMA_OP_WRITE_LAST         = 8w0x08;
const bit<8> RDMA_OP_WRITE_LAST_WITH_IMM = 8w0x09;
const bit<8> RDMA_OP_WRITE_ONLY         = 8w0x0a;  // Message shorter than MTU
const bit<8> RDMA_OP_WRITE_ONLY_WITH_IMM = 8w0x0b;

/* Read Operations */
const bit<8> RDMA_OP_READ_REQ        = 8w0x0c;
const bit<8> RDMA_OP_READ_RES_FIRST  = 8w0x0d;
const bit<8> RDMA_OP_READ_RES_MIDDLE = 8w0x0e;
const bit<8> RDMA_OP_READ_RES_LAST   = 8w0x0f;
const bit<8> RDMA_OP_READ_RES_ONLY   = 8w0x10;

/* ACK and Atomic Operations */
const bit<8> RDMA_OP_ACK        = 8w0x11;
const bit<8> RDMA_OP_ATOMIC_ACK = 8w0x12;
const bit<8> RDMA_OP_CMPSWAP    = 8w0x13;
const bit<8> RDMA_OP_FETCHADD   = 8w0x14;

/* Congestion Notification */
const bit<8> RDMA_OP_CNP = 8w0x81;

/* Unreliable Datagram */
const bit<8> RDMA_OP_UD_SEND_ONLY = 8w0x64;

/* =============================================================================
 * AETH Syndrome Values (ACK Extended Transport Header)
 * ============================================================================= */

/* ACK Syndrome: OpCode bits [6:5] = 00 */
const bit<32> AETH_ACK_CREDIT_INVALID = 32w0x1F;  // Credit: 31 (Invalid)
const bit<32> AETH_ACK_CREDIT_ZERO    = 32w0x00;  // Credit: 0

/* NAK Syndrome: OpCode bits [6:5] = 11 (Binary: 011 NNNNN) */
const bit<32> AETH_NAK_SEQ_ERR   = 32w0x60;  // NAK Code 0: PSN Sequence Error
const bit<32> AETH_NAK_INV_REQ   = 32w0x61;  // NAK Code 1: Invalid Request
const bit<32> AETH_NAK_R_ACC_ERR = 32w0x62;  // NAK Code 2: Remote Access Error

/* =============================================================================
 * Header Definitions
 * ============================================================================= */

/**
 * Ethernet Header (14 bytes)
 */
header eth_h {
    mac_addr_t dst_addr;
    mac_addr_t src_addr;
    bit<16>    ether_type;
}

/**
 * IPv4 Header (20 bytes, no options)
 */
header ipv4_h {
    bit<8>      ver_ihl;        // Version (4b) + IHL (4b)
    bit<8>      diffserv;       // DSCP + ECN
    bit<16>     total_len;
    bit<16>     identification;
    bit<16>     flag_offset;    // Flags (3b) + Fragment Offset (13b)
    bit<8>      ttl;
    bit<8>      protocol;
    bit<16>     hdr_checksum;
    ipv4_addr_t src_addr;
    ipv4_addr_t dst_addr;
}

/**
 * TCP Header (20 bytes, no options)
 */
header tcp_h {
    bit<16> src_port;
    bit<16> dst_port;
    bit<32> seq_no;
    bit<32> ack_no;
    bit<8>  data_offset_res;  // Data Offset (4b) + Reserved (4b)
    bit<8>  flags;
    bit<16> window;
    bit<16> checksum;
    bit<16> urgent_ptr;
}

/**
 * UDP Header (8 bytes)
 */
header udp_h {
    bit<16> src_port;
    bit<16> dst_port;
    bit<16> length;
    bit<16> checksum;
}

/**
 * InfiniBand Base Transport Header (12 bytes)
 *
 * Structure:
 *   - opcode: Operation code
 *   - se_migreq_pad_ver: Solicited Event (1b) + Migration Request (1b) +
 *                        Pad Count (2b) + Transport Version (4b)
 *   - pkey: Partition Key (1b permission + 15b key)
 *   - dst_qp: Reserved (8b) + Destination QPN (24b)
 *   - psn: ACK Request (1b) + Reserved (7b) + PSN (24b)
 */
header bth_h {
    bit<8>  opcode;
    bit<8>  se_migreq_pad_ver;
    bit<16> pkey;
    bit<32> dst_qp;
    bit<32> psn;
}

/**
 * RDMA Extended Transport Header (16 bytes)
 * Used for RDMA Read/Write operations
 */
header reth_h {
    bit<64> addr;   // Virtual address
    bit<32> rkey;   // Remote key
    bit<32> len;    // DMA length (excludes padding)
}

/**
 * ACK Extended Transport Header (4 bytes)
 *
 * Syndrome field format:
 *   - Bit 7: Reserved (0)
 *   - Bits [6:5]: OpCode (ACK=00, RNR NAK=01, Reserved=10, NAK=11)
 *   - Bits [4:0]: Value (Credit count, RNR timer, or NAK code)
 *   - Bits [23:0]: Message Sequence Number (starts from 0)
 */
header aeth_h {
    bit<32> msn;  // Syndrome (8b) + MSN (24b)
}

/**
 * Atomic Extended Transport Header (28 bytes)
 * Used for Compare-and-Swap and Fetch-and-Add operations
 */
header atomic_eth_h {
    bit<64> addr;
    bit<32> rkey;
    bit<64> swapadd_data;
    bit<64> compare_data;
}

/**
 * Atomic ACK Extended Transport Header (8 bytes)
 */
header atomic_aeth_h {
    bit<64> original_data;
}

/**
 * Congestion Notification Packet Header (16 bytes)
 */
header cnp_h {
    bit<128> reserved;
}

/**
 * Immediate Data Header (4 bytes)
 */
header imm_h {
    bit<32> imm;
}

/**
 * ICRC (Invariant CRC) Trailer (4 bytes)
 */
header icrc_h {
    bit<8> v0;
    bit<8> v1;
    bit<8> v2;
    bit<8> v3;
}

/* =============================================================================
 * Initialization Types
 * ============================================================================= */

/**
 * Expected PSN for dispatch operations:
 *   - TX: Next PSN to switch
 *   - RX: Next PSN to receive
 */
typedef bit<32> init_epsn_t;

/**
 * Address initialization type
 */
typedef bit<64> init_addr_t;
