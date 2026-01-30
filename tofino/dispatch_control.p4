/**
 * @file dispatch_control.p4
 * @brief Dispatch phase control logic for A2A communication
 *
 * Implements the scatter/dispatch phase of All-to-All collective,
 * managing PSN tracking, bitmap-based multicast, and per-receiver
 * state maintenance.
 */

/* =============================================================================
 * Configuration Constants
 * ============================================================================= */

#define TX_DISPATCH_CHANNELS_NUM 8                              // Channels per TX
#define DISPATCH_CHANNELS_NUM    (EP_SIZE * TX_DISPATCH_CHANNELS_NUM)

/* =============================================================================
 * Dispatch Ingress Control
 *
 * Handles incoming data packets:
 *   - ACK/NAK processing from receivers
 *   - Control connection initialization
 *   - TX data packet processing with bitmap-based multicast
 *
 * Note: Next-hop addresses are set in egress based on channel_id and port.
 * ============================================================================= */

control DispatchIngress(
    inout a2a_headers_t                         hdr,
    inout a2a_ingress_metadata_t                ig_md,
    in    ingress_intrinsic_metadata_t          ig_intr_md,
    inout ingress_intrinsic_metadata_for_deparser_t ig_dprsr_md,
    inout ingress_intrinsic_metadata_for_tm_t   ig_tm_md)
{
    /* =========================================================================
     * TX State Registers
     * ========================================================================= */

    /* Expected PSN for TX connections */
    Register<bit<32>, bit<32>>(DISPATCH_CHANNELS_NUM) reg_tx_epsn;

    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_tx_epsn) ra_read_cond_inc_tx_epsn = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
            if (ig_md.psn == value) {
                value = value + 1;
            }
        }
    };

    RegisterAction<bit<32>, bit<32>, void>(reg_tx_epsn) ra_init_tx_epsn = {
        void apply(inout bit<32> value) {
            value = 0;
        }
    };

    RegisterAction<bit<32>, bit<32>, void>(reg_tx_epsn) ra_invalidate_tx_epsn = {
        void apply(inout bit<32> value) {
            value = 0xFFFFFFFF;
        }
    };

    /* Message Sequence Number for TX connections */
    Register<bit<32>, bit<32>>(DISPATCH_CHANNELS_NUM) reg_tx_msn;

    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_tx_msn) ra_read_tx_msn = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
            if (hdr.bth.opcode == RDMA_OP_WRITE_ONLY ||
                hdr.bth.opcode == RDMA_OP_WRITE_LAST) {
                value = value + 1;
            }
        }
    };

    RegisterAction<bit<32>, bit<32>, void>(reg_tx_msn) ra_inc_tx_msn = {
        void apply(inout bit<32> value) {
            value = value + 1;
        }
    };

    RegisterAction<bit<32>, bit<32>, void>(reg_tx_msn) ra_init_tx_msn = {
        void apply(inout bit<32> value) {
            value = 0;
        }
    };

    /* Bitmap for multicast destinations */
    Register<bitmap_tofino_t, bit<32>>(DISPATCH_CHANNELS_NUM) reg_tx_bitmap;

    RegisterAction<bitmap_tofino_t, bit<32>, bitmap_tofino_t>(reg_tx_bitmap) ra_read_tx_bitmap = {
        void apply(inout bitmap_tofino_t value, out bitmap_tofino_t result) {
            result = value;
        }
    };

    RegisterAction<bitmap_tofino_t, bit<32>, void>(reg_tx_bitmap) ra_write_tx_bitmap = {
        void apply(inout bitmap_tofino_t value) {
            value = ig_md.bitmap;
        }
    };

    /* =========================================================================
     * Utility Actions
     * ========================================================================= */

    action mul_256() {
        ig_md.msn = ig_md.msn * 256;
    }

    action set_aeth_msn() {
        ig_md.has_aeth = true;
        hdr.aeth.setValid();
        hdr.aeth.msn = ig_md.msn;
    }

    action set_aeth_syndrome(bit<32> syndrome) {
        ig_md.msn = ig_md.msn + syndrome;
    }

    action set_aeth_psn(bit<32> psn) {
        hdr.bth.psn = psn;
    }

    /* =========================================================================
     * PSN Comparison Table
     * ========================================================================= */

    action set_cmp(bit<8> cmp) {
        ig_md.psn_cmp = cmp;
    }

    table tbl_compare {
        key = {
            ig_md.psn_diff: ternary;
        }
        actions = {
            set_cmp;
        }
    }

    /* =========================================================================
     * Register Access Actions
     * ========================================================================= */

    action do_init_tx_epsn() {
        ra_init_tx_epsn.execute(ig_md.channel_id);
    }

    action do_read_cond_inc_tx_epsn() {
        ig_md.tmp_a = ra_read_cond_inc_tx_epsn.execute(ig_md.channel_id);
    }

    /* =========================================================================
     * Apply Block
     * ========================================================================= */

    apply {
        /* ---------------------------------------------------------------------
         * Process ACK/NAK from RX
         * --------------------------------------------------------------------- */
        if (ig_md.conn_semantics == CONN_SEMANTICS.CONN_RX &&
            hdr.bth.opcode == RDMA_OP_ACK) {
            ig_dprsr_md.drop_ctl = 1;
            return;
        }

        /* ---------------------------------------------------------------------
         * Process Control Connection (Initialization)
         * --------------------------------------------------------------------- */
        else if (ig_md.conn_semantics == CONN_SEMANTICS.CONN_CONTROL) {
            do_init_tx_epsn();
            ra_init_tx_msn.execute(ig_md.channel_id);

            /* Build ACK response with MSN = PSN + 1 */
            ig_md.msn = ig_md.psn + 1;
            mul_256();
            set_aeth_syndrome(AETH_ACK_CREDIT_INVALID);
            set_aeth_msn();
            set_aeth_psn(ig_md.psn);
            ig_md.has_aeth = true;

            /* Send ACK back to ingress port */
            ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
            return;
        }

        /* ---------------------------------------------------------------------
         * Process TX Data Packets
         * --------------------------------------------------------------------- */
        else if (ig_md.conn_semantics == CONN_SEMANTICS.CONN_TX) {
            /* Read and conditionally increment TX MSN */
            ig_md.tmp_b = ra_read_tx_msn.execute(ig_md.channel_id);
            ig_md.msn = ig_md.tmp_b;
            mul_256();
            set_aeth_syndrome(AETH_ACK_CREDIT_INVALID);
            set_aeth_msn();
            set_aeth_psn(ig_md.tmp_a - 1);
            ig_md.has_aeth = true;
            ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;

            /* Handle bitmap for multicast routing */
            if (hdr.bth.opcode == RDMA_OP_WRITE_FIRST ||
                hdr.bth.opcode == RDMA_OP_WRITE_ONLY) {
                /* First packet: extract bitmap from RETH address field */
                ig_md.bitmap = hdr.reth.addr[31:0];
                ra_write_tx_bitmap.execute(ig_md.channel_id);
            } else {
                /* Subsequent packets: read stored bitmap */
                ig_md.bitmap = ra_read_tx_bitmap.execute(ig_md.channel_id);
            }

            /* Enable multicast to all ports (group 100) */
            ig_tm_md.mcast_grp_a = 100;

            /* Rebuild ACK with saved MSN */
            ig_md.msn = ig_md.tmp_b;
            mul_256();
            set_aeth_syndrome(AETH_ACK_CREDIT_INVALID);
            set_aeth_msn();
            set_aeth_psn(ig_md.tmp_a - 1);
            ig_md.has_aeth = true;
            ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
        }
    }
}


/* =============================================================================
 * RxPsnSlot - PSN Management Sub-Control
 *
 * Manages per-receiver PSN state for a single endpoint slot.
 * ============================================================================= */

control RxPsnSlot(
    out bit<32>        result_psn,
    in  bit<32>        init_value,
    in  DISPATCH_REG_OP operation,
    in  bit<32>        channel_id)
{
    bit<32> init_val;

    Register<bit<32>, bit<32>>(DISPATCH_CHANNELS_NUM) reg_psn;

    RegisterAction<bit<32>, bit<32>, void>(reg_psn) ra_init = {
        void apply(inout bit<32> value) {
            value = 0;
        }
    };

    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_psn) ra_read_inc = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
            value = value + 1;
        }
    };

    apply {
        if (operation == DISPATCH_REG_OP.OP_INIT) {
            init_val = init_value;
            ra_init.execute(channel_id);
        } else if (operation == DISPATCH_REG_OP.OP_READ_INC) {
            result_psn = ra_read_inc.execute(channel_id);
        }
    }
}


/* =============================================================================
 * RxAddrSlot - Address Management Sub-Control
 *
 * Manages 64-bit addresses using two 32-bit registers (lo/hi split)
 * for a single endpoint slot.
 * ============================================================================= */

control RxAddrSlot(
    out addr_tofino_t  result_addr,
    in  addr_tofino_t  init_addr,
    in  bit<32>        add_value,
    in  DISPATCH_REG_OP operation,
    in  bit<32>        channel_id)
{
    bit<32> add_val;

    /* Low 32 bits register */
    Register<bit<32>, bit<32>>(TX_DISPATCH_CHANNELS_NUM) reg_addr_lo;

    RegisterAction<bit<32>, bit<32>, void>(reg_addr_lo) ra_lo_init = {
        void apply(inout bit<32> value) {
            value = 0;
        }
    };

    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_addr_lo) ra_lo_read_add = {
        void apply(inout bit<32> value, out bit<32> res) {
            res = value;
            value = value + add_val;
        }
    };

    /* High 32 bits register */
    Register<bit<32>, bit<32>>(TX_DISPATCH_CHANNELS_NUM) reg_addr_hi;

    RegisterAction<bit<32>, bit<32>, void>(reg_addr_hi) ra_hi_init = {
        void apply(inout bit<32> value) {
            value = 0;
        }
    };

    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_addr_hi) ra_hi_read = {
        void apply(inout bit<32> value, out bit<32> res) {
            res = value;
        }
    };

    apply {
        if (operation == DISPATCH_REG_OP.OP_INIT) {
            ra_lo_init.execute(channel_id);
            ra_hi_init.execute(channel_id);
        } else if (operation == DISPATCH_REG_OP.OP_READ_ADD) {
            add_val = add_value;
            result_addr[31:0]  = ra_lo_read_add.execute(channel_id);
            result_addr[63:32] = ra_hi_read.execute(channel_id);
        }
    }
}


/* =============================================================================
 * Dispatch Egress Control
 *
 * Processes multicast replicas in egress:
 *   - Control connection: generates ACK responses
 *   - TX data: filters by bitmap, updates per-receiver PSN and address
 *
 * Bridge header fields available:
 *   - is_roce, has_reth, has_aeth, has_payload
 *   - conn_phase, conn_semantics
 *   - channel_id, bitmap
 * ============================================================================= */

control DispatchEgress(
    inout a2a_headers_t                            hdr,
    inout a2a_egress_metadata_t                    eg_md,
    in    egress_intrinsic_metadata_t              eg_intr_md,
    inout egress_intrinsic_metadata_for_deparser_t eg_dprsr_md)
{
    /* =========================================================================
     * PSN Slot Instances (EP_SIZE = 8)
     * ========================================================================= */

    RxPsnSlot() psn_slot_0;
    RxPsnSlot() psn_slot_1;
    RxPsnSlot() psn_slot_2;
    RxPsnSlot() psn_slot_3;
    RxPsnSlot() psn_slot_4;
    RxPsnSlot() psn_slot_5;
    RxPsnSlot() psn_slot_6;
    RxPsnSlot() psn_slot_7;

    /* =========================================================================
     * Address Slot Instances (EP_SIZE = 8)
     * ========================================================================= */

    RxAddrSlot() addr_slot_0;
    RxAddrSlot() addr_slot_1;
    RxAddrSlot() addr_slot_2;
    RxAddrSlot() addr_slot_3;
    RxAddrSlot() addr_slot_4;
    RxAddrSlot() addr_slot_5;
    RxAddrSlot() addr_slot_6;
    RxAddrSlot() addr_slot_7;

    /* =========================================================================
     * Local Variables
     * ========================================================================= */

    bit<32> channel_id;
    bit<32> result_psn;
    bit<64> result_addr;
    bit<32> payload_len_32;

    /* =========================================================================
     * Rank ID Lookup Table
     * ========================================================================= */

    action get_rank_id(bit<32> rank_id) {
        eg_md.eg_rank_id = rank_id;
    }

    table dispatch_rank_info {
        key = {
            eg_md.channel_id       : exact;
            eg_intr_md.egress_port : exact;
        }
        actions = {
            get_rank_id;
            NoAction;
        }
        size = 1024;
        default_action = NoAction;
    }

    /* =========================================================================
     * RX Connection Info Lookup Table
     * ========================================================================= */

    action set_rx_info(
        bit<48> dst_mac,
        bit<32> dst_ip,
        bit<32> dst_qp,
        bit<32> rkey)
    {
        hdr.eth.dst_addr  = dst_mac;
        hdr.ipv4.dst_addr = dst_ip;
        hdr.bth.dst_qp    = dst_qp;
        hdr.reth.rkey     = rkey;
    }

    table dispatch_rx_info {
        key = {
            eg_md.channel_id : exact;
            eg_md.eg_rank_id : exact;
        }
        actions = {
            set_rx_info;
            NoAction;
        }
        size = 1024;
        default_action = NoAction;
    }

    /* =========================================================================
     * Bitmap Membership Check Table
     * ========================================================================= */

    action set_in_bitmap(bit<32> cmp) {
        eg_md.cmp = cmp;
    }

    table tbl_in_bitmap {
        key = {
            eg_md.bitmap     : exact;
            eg_md.eg_rank_id : exact;
        }
        actions = {
            set_in_bitmap;
        }
        size = 64;
    }

    /* =========================================================================
     * ACK Generation Action
     * ========================================================================= */

    action set_ack_egress() {
        /* Remove data headers */
        hdr.reth.setInvalid();
        hdr.payload.setInvalid();

        /* Set BTH opcode to ACK */
        hdr.bth.opcode = RDMA_OP_ACK;

        /* Update UDP length for ACK packet */
        hdr.udp.length   = 28;
        hdr.udp.checksum = 0;

        /* Swap UDP ports */
        bit<16> tmp_port = hdr.udp.src_port;
        hdr.udp.src_port = hdr.udp.dst_port;
        hdr.udp.dst_port = tmp_port;

        /* Update IPv4 length and swap addresses */
        hdr.ipv4.total_len = 48;
        bit<32> tmp_ip     = hdr.ipv4.src_addr;
        hdr.ipv4.src_addr  = hdr.ipv4.dst_addr;
        hdr.ipv4.dst_addr  = tmp_ip;

        /* Swap Ethernet addresses */
        bit<48> tmp_mac    = hdr.eth.src_addr;
        hdr.eth.src_addr   = hdr.eth.dst_addr;
        hdr.eth.dst_addr   = tmp_mac;
    }

    /* =========================================================================
     * Apply Block
     * ========================================================================= */

    apply {
        dispatch_rank_info.apply();
        channel_id = (bit<32>)eg_md.channel_id;

        /* ---------------------------------------------------------------------
         * Control Connection: Generate ACK
         * --------------------------------------------------------------------- */
        if (eg_md.conn_semantics == CONN_SEMANTICS.CONN_CONTROL) {
            set_ack_egress();
            return;
        }

        /* ---------------------------------------------------------------------
         * TX Data Connection: Process Multicast Replica
         * --------------------------------------------------------------------- */
        if (eg_md.conn_semantics == CONN_SEMANTICS.CONN_TX) {
            eg_md.diff = eg_md.ing_rank_id - eg_md.eg_rank_id;

            /* Check if this is the ACK replica (back to sender) */
            if (eg_md.cmp == 0) {
                set_ack_egress();
            } else {
                /* Check if this rank is in the destination bitmap */
                tbl_in_bitmap.apply();

                if (eg_md.cmp == 0) {
                    /* Rank is in bitmap: forward packet */
                    payload_len_32 = 1024;

                    /* Lookup destination RX connection info */
                    dispatch_rx_info.apply();

                    /* Update PSN based on egress rank */
                    if (eg_md.eg_rank_id == 0) {
                        psn_slot_0.apply(result_psn, 0, DISPATCH_REG_OP.OP_READ_INC, channel_id);
                    } else if (eg_md.eg_rank_id == 1) {
                        psn_slot_1.apply(result_psn, 0, DISPATCH_REG_OP.OP_READ_INC, channel_id);
                    } else if (eg_md.eg_rank_id == 2) {
                        psn_slot_2.apply(result_psn, 0, DISPATCH_REG_OP.OP_READ_INC, channel_id);
                    } else if (eg_md.eg_rank_id == 3) {
                        psn_slot_3.apply(result_psn, 0, DISPATCH_REG_OP.OP_READ_INC, channel_id);
                    } else if (eg_md.eg_rank_id == 4) {
                        psn_slot_4.apply(result_psn, 0, DISPATCH_REG_OP.OP_READ_INC, channel_id);
                    } else if (eg_md.eg_rank_id == 5) {
                        psn_slot_5.apply(result_psn, 0, DISPATCH_REG_OP.OP_READ_INC, channel_id);
                    } else if (eg_md.eg_rank_id == 6) {
                        psn_slot_6.apply(result_psn, 0, DISPATCH_REG_OP.OP_READ_INC, channel_id);
                    } else if (eg_md.eg_rank_id == 7) {
                        psn_slot_7.apply(result_psn, 0, DISPATCH_REG_OP.OP_READ_INC, channel_id);
                    }

                    hdr.bth.psn = result_psn;

                    /* Update RETH address for first/only packets */
                    if (hdr.reth.isValid() &&
                        (hdr.bth.opcode == RDMA_OP_WRITE_FIRST ||
                         hdr.bth.opcode == RDMA_OP_WRITE_ONLY)) {

                        if (eg_md.eg_rank_id == 0) {
                            addr_slot_0.apply(result_addr, 0, payload_len_32,
                                              DISPATCH_REG_OP.OP_READ_ADD, channel_id);
                        } else if (eg_md.eg_rank_id == 1) {
                            addr_slot_1.apply(result_addr, 0, payload_len_32,
                                              DISPATCH_REG_OP.OP_READ_ADD, channel_id);
                        } else if (eg_md.eg_rank_id == 2) {
                            addr_slot_2.apply(result_addr, 0, payload_len_32,
                                              DISPATCH_REG_OP.OP_READ_ADD, channel_id);
                        } else if (eg_md.eg_rank_id == 3) {
                            addr_slot_3.apply(result_addr, 0, payload_len_32,
                                              DISPATCH_REG_OP.OP_READ_ADD, channel_id);
                        } else if (eg_md.eg_rank_id == 4) {
                            addr_slot_4.apply(result_addr, 0, payload_len_32,
                                              DISPATCH_REG_OP.OP_READ_ADD, channel_id);
                        } else if (eg_md.eg_rank_id == 5) {
                            addr_slot_5.apply(result_addr, 0, payload_len_32,
                                              DISPATCH_REG_OP.OP_READ_ADD, channel_id);
                        } else if (eg_md.eg_rank_id == 6) {
                            addr_slot_6.apply(result_addr, 0, payload_len_32,
                                              DISPATCH_REG_OP.OP_READ_ADD, channel_id);
                        } else if (eg_md.eg_rank_id == 7) {
                            addr_slot_7.apply(result_addr, 0, payload_len_32,
                                              DISPATCH_REG_OP.OP_READ_ADD, channel_id);
                        }

                        hdr.reth.addr = result_addr;
                    }

                    /* Remove AETH from data packets */
                    hdr.aeth.setInvalid();
                } else {
                    /* Rank not in bitmap: drop packet */
                    eg_dprsr_md.drop_ctl = 1;
                }
            }
        }
    }
}
