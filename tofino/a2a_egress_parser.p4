parser A2AEgressParser( 
    packet_in pkt, 
    out a2a_headers_t hdr, 
    out a2a_egress_metadata_t eg_md, 
    out egress_intrinsic_metadata_t eg_intr_md)
{  
    state start { 
        pkt.extract(eg_intr_md); 
        pkt.extract(eg_md.bridge);
        pkt.extract(hdr.eth); 
        pkt.extract(hdr.ipv4);
        pkt.extract(hdr.udp);
        pkt.extract(hdr.bth);
        
        transition select(eg_md.bridge.has_aeth) {
            true  : parse_aeth;
            false : check_reth; 
        } 
    }  

    state parse_aeth {
        pkt.extract(hdr.aeth);
        transition check_reth;
    }

    state check_reth {
        transition select(eg_md.bridge.has_reth) {
            true  : parse_reth;
            false : check_payload;
        }
    }

    state parse_reth {
        pkt.extract(hdr.reth);
        transition check_payload;
    }

    state check_payload {
        transition select(eg_md.bridge.has_payload) {
            true  : parse_payload;
            false : parse_icrc;
        }
    }

    state parse_payload {
        pkt.extract(hdr.payload);
        transition accept;
    }
}