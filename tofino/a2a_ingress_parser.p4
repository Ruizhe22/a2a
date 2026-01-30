/**
 * @file a2a_ingress_parser.p4
 * @brief Ingress parser for A2A packet processing
 *
 * Parses incoming packets through the standard network stack
 * (Ethernet -> IPv4 -> UDP) and then handles RoCEv2/RDMA headers.
 */

parser A2AIngressParser(
    packet_in                        pkt,
    out a2a_headers_t                hdr,
    out a2a_ingress_metadata_t       ig_md,
    out ingress_intrinsic_metadata_t ig_intr_md)
{
    /* =========================================================================
     * Initial State
     * ========================================================================= */

    state start {
        pkt.extract(ig_intr_md);
        pkt.advance(PORT_METADATA_SIZE);

        /* Initialize metadata flags */
        ig_md.is_roce = false;

        transition parse_eth;
    }

    /* =========================================================================
     * Layer 2 Parsing
     * ========================================================================= */

    state parse_eth {
        pkt.extract(hdr.eth);
        transition select(hdr.eth.ether_type) {
            ETHERTYPE_IPV4: parse_ipv4;
            default:        accept;
        }
    }

    /* =========================================================================
     * Layer 3 Parsing
     * ========================================================================= */

    state parse_ipv4 {
        pkt.extract(hdr.ipv4);
        transition select(hdr.ipv4.protocol) {
            IP_PROTOCOLS_UDP: parse_udp;
            default:          accept;
        }
    }

    /* =========================================================================
     * Layer 4 Parsing
     * ========================================================================= */

    state parse_udp {
        pkt.extract(hdr.udp);
        transition select(hdr.udp.dst_port) {
            UDP_PORT_ROCE: parse_bth;
            default:       accept;
        }
    }

    /* =========================================================================
     * RDMA/RoCEv2 Header Parsing
     * ========================================================================= */

    /**
     * Parse Base Transport Header and branch based on opcode
     */
    state parse_bth {
        pkt.extract(hdr.bth);
        ig_md.is_roce = true;

        transition select(hdr.bth.opcode) {
            /* Write operations with RETH */
            RDMA_OP_WRITE_FIRST: parse_write_reth;
            RDMA_OP_WRITE_ONLY:  parse_write_reth;

            /* Write operations without RETH */
            RDMA_OP_WRITE_MIDDLE: parse_payload;
            RDMA_OP_WRITE_LAST:   parse_payload;

            /* Read request (RETH only, no payload) */
            RDMA_OP_READ_REQ: parse_read_reth;

            /* Read responses with AETH */
            RDMA_OP_READ_RES_FIRST: parse_read_aeth;
            RDMA_OP_READ_RES_LAST:  parse_read_aeth;
            RDMA_OP_READ_RES_ONLY:  parse_read_aeth;

            /* Read response without AETH */
            RDMA_OP_READ_RES_MIDDLE: parse_payload;

            /* ACK packet */
            RDMA_OP_ACK: parse_ack_aeth;

            default: accept;
        }
    }

    /**
     * Parse RETH for write operations, then continue to payload
     */
    state parse_write_reth {
        pkt.extract(hdr.reth);
        ig_md.has_reth = true;
        transition parse_payload;
    }

    /**
     * Parse RETH for read requests (no payload follows)
     */
    state parse_read_reth {
        pkt.extract(hdr.reth);
        ig_md.has_reth = true;
        transition accept;
    }

    /**
     * Parse AETH for read responses, then continue to payload
     */
    state parse_read_aeth {
        pkt.extract(hdr.aeth);
        ig_md.has_aeth = true;
        transition parse_payload;
    }

    /**
     * Parse AETH for ACK packets (no payload follows)
     */
    state parse_ack_aeth {
        pkt.extract(hdr.aeth);
        ig_md.has_aeth = true;
        transition accept;
    }

    /**
     * Parse payload header for in-switch processing
     */
    state parse_payload {
        pkt.extract(hdr.payload);
        ig_md.has_payload = true;
        transition accept;
    }
}
