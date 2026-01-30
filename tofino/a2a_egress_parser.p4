/**
 * @file a2a_egress_parser.p4
 * @brief Egress parser for A2A packet processing
 *
 * Parses packets entering the egress pipeline, extracting the bridge
 * header and conditionally parsing RDMA headers based on flags.
 */

parser A2AEgressParser(
    packet_in                       pkt,
    out a2a_headers_t               hdr,
    out a2a_egress_metadata_t       eg_md,
    out egress_intrinsic_metadata_t eg_intr_md)
{
    /* =========================================================================
     * Initial State - Extract Fixed Headers
     * ========================================================================= */

    state start {
        /* Extract egress intrinsic metadata */
        pkt.extract(eg_intr_md);

        /* Extract standard network headers */
        pkt.extract(hdr.eth);
        pkt.extract(hdr.ipv4);
        pkt.extract(hdr.udp);
        pkt.extract(hdr.bth);

        /* Extract bridge header (ingress-to-egress metadata) */
        pkt.extract(hdr.bridge);

        transition check_aeth;
    }

    /* =========================================================================
     * Conditional AETH Parsing
     * ========================================================================= */

    state check_aeth {
        transition select(hdr.bridge.has_aeth) {
            1:       parse_aeth;
            default: check_reth;
        }
    }

    state parse_aeth {
        pkt.extract(hdr.aeth);
        transition check_reth;
    }

    /* =========================================================================
     * Conditional RETH Parsing
     * ========================================================================= */

    state check_reth {
        transition select(hdr.bridge.has_reth) {
            1:       parse_reth;
            default: check_payload;
        }
    }

    state parse_reth {
        pkt.extract(hdr.reth);
        transition check_payload;
    }

    /* =========================================================================
     * Conditional Payload Parsing
     * ========================================================================= */

    state check_payload {
        transition select(hdr.bridge.has_payload) {
            1:       parse_payload;
            default: accept;
        }
    }

    state parse_payload {
        /* Extract only the first word for egress processing */
        pkt.extract(hdr.payload_first_word);
        transition accept;
    }
}
