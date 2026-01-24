parser A2AEgressParser( 
    packet_in pkt, 
    out a2a_headers_t hdr, 
    out a2a_egress_metadata_t eg_md, 
    out egress_intrinsic_metadata_t eg_intr_md)
{  
    state start { 

        pkt.extract(eg_intr_md);
        pkt.extract(hdr.eth); 
        pkt.extract(hdr.ipv4);
        pkt.extract(hdr.udp);
        pkt.extract(hdr.bth);
        pkt.extract(hdr.bridge); 
        transition check_aeth;
    }  

    state check_aeth {
        transition select(hdr.bridge.has_aeth) {
            1  : parse_aeth;
            0 : check_reth; 
        } 
    }

    state parse_aeth {
        pkt.extract(hdr.aeth);
        transition check_reth;
    }

    state check_reth {
        transition select(hdr.bridge.has_reth) {
            1  : parse_reth;
            0 : check_payload;
        }
    }

    state parse_reth {
        pkt.extract(hdr.reth);
        transition check_payload;
    }

    state check_payload {
        transition select(hdr.bridge.has_payload) {
            1  : parse_payload;
            0 : accept;
        }
    }

    state parse_payload {
        pkt.extract(hdr.payload_first_word);
        transition accept;
    }
}