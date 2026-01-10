parser A2AIngressParser( 
    packet_in pkt, 
    out a2a_ingress_headers_t ig_hdr, 
    out a2a_ingress_metadata_t ig_md, 
    out ingress_intrinsic_metadata_t ig_intr_md) 
{  
    state start { 
        pkt.extract(ig_intr_md); 
        pkt.advance(PORT_METADATA_SIZE); 
        ig_md.is_roce = false;
        transition parse_eth; 
    }  
    
    state parse_eth { 
        pkt.extract(ig_hdr.eth); 
        transition select(ig_hdr.eth.ether_type) { 
            ETHERTYPE_IPV4 : parse_ipv4; 
            default : accept; 
        }
    }

    state parse_ipv4 {
        pkt.extract(hdr.ipv4);
        transition select(hdr.ipv4.protocol) {
            IP_PROTOCOLS_UDP : parse_udp;
            default : accept;
        }
    }

    state parse_udp {
        pkt.extract(hdr.udp);
        transition select(hdr.udp.dst_port) {
            UDP_PORT_ROCE : parse_bth;
            default : accept;
        }
    }
    
    state parse_bth {
        pkt.extract(hdr.bth);
        ig_md.is_roce = true;
        transition select(hdr.bth.opcode) {
            RDMA_OP_WRITE_FIRST: parse_write_reth;
            RDMA_OP_WRITE_MIDDLE: parse_payload;
            RDMA_OP_WRITE_LAST: parse_payload;
            RDMA_OP_WRITE_ONLY: parse_write_reth;
            RDMA_OP_READ_REQ: parse_read_reth;
            RDMA_OP_READ_RES_FIRST: parse_read_aeth;
            RDMA_OP_READ_RES_MIDDLE: parse_payload;
            RDMA_OP_READ_RES_LAST: parse_read_aeth;
            RDMA_OP_READ_RES_ONLY: parse_read_aeth;
            RDMA_OP_ACK: parse_ack_aeth;
            default : accept;
        }
    }

    state parse_write_reth {
        pkt.extract(hdr.reth);
        transition parse_payload;
    }

    state parse_read_aeth {
        pkt.extract(hdr.aeth);
        transition parse_payload;
    }

    // for RDMA_OP_READ_REQ, no payload
    state parse_read_reth {
        pkt.extract(hdr.reth);
        transition accept;
    }

    state parse_payload {
        packet.extract(hdr.payload);
        transition parse_icrc;
    } 

    state parse_ack_aeth {
        pkt.extract(hdr.aeth);
        transition accept;
    }
}