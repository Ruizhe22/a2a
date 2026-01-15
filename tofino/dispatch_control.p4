/* EP_SIZE(N) 8 */
#define TX_DISPATCH_CHANNELS_NUM 8 // number of channels per tx
#define DISPATCH_CHANNELS_NUM (EP_SIZE * TX_DISPATCH_CHANNELS_NUM)

/***************************************************************************
 * Dispatch Ingress Control
 * addr of the next hop should be set in egress pipeline, 
 * depending on the channel_id and the egress port.
 ***************************************************************************/

control DispatchIngress(
    inout a2a_ingress_headers_t hdr,
    inout a2a_ingress_metadata_t ig_md,
    in ingress_intrinsic_metadata_t ig_intr_md,
    inout ingress_intrinsic_metadata_for_deparser_t ig_dprsr_md,
    inout ingress_intrinsic_metadata_for_tm_t ig_tm_md)
{

    /***************************************************************************
     * Registers
     ***************************************************************************/
    
    /* tx_epsn */
    Register<bit<32>, bit<32>>(DISPATCH_CHANNELS_NUM) reg_tx_epsn;
    bit<32> psn_to_check;

    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_tx_epsn) ra_read_cond_inc_tx_epsn = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
            if (psn_to_check == value) {
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

    /* tx_msn */
    Register<bit<32>, bit<32>>(DISPATCH_CHANNELS_NUM) reg_tx_msn;
    
    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_tx_msn) ra_read_tx_msn = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
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

    /* tx_bitmap */


    Register<bitmap_tofino_tofino_t, bit<32>>(DISPATCH_CHANNELS_NUM) reg_tx_bitmap;
    
    RegisterAction<bitmap_tofino_t, bit<32>, bitmap_tofino_t>(reg_tx_bitmap) ra_read_tx_bitmap = {
        void apply(inout bitmap_tofino_t value, out bitmap_tofino_t result) {
            result = value;
        }
    };
    
    RegisterAction<bitmap_tofino_t, bit<32>, void>(reg_tx_bitmap) ra_write_tx_bitmap = {
        void apply(inout bitmap_tofino_t value) {
            value = ig_md.bridge.bitmap;
        }
    };
    
    /***************************************************************************
     * Utility Actions
     ***************************************************************************/
    
    action set_ack_ingress(bit<8> syndrome, bit<24> psn, bit<24> msn) {
        hdr.bth.psn = psn;
        hdr.aeth.setValid();
        hdr.aeth.syndrome = syndrome;
        hdr.aeth.msn = msn;
    }
    
    
    /***************************************************************************
     * Apply
     ***************************************************************************/
    
    apply {

        bit<32> channel_idx = (bit<32>)ig_md.bridge.channel_id;
        // process ACK/NAK from rx
        if (ig_md.bridge.conn_semantics == CONN_SEMANTICS.CONN_RX && hdr.bth.opcode == RDMA_OP_ACK) {
            if (hdr.aeth.syndrome[6:5] != AETH_ACK) {
                ra_invalidate_tx_epsn.execute(channel_idx);
            }
            ig_dprsr_md.drop_ctl = 1;
            return;
        }

        // process control connection
        if (ig_md.bridge.conn_semantics == CONN_SEMANTICS.CONN_CONTROL) {
            ra_init_tx_msn.execute(channel_idx);
            // should be extract from payload, but we set 0 as an agreement with the endpoint
            ra_init_tx_epsn.execute(channel_idx);
            set_ack_ingress(AETH_ACK_CREDIT_INVALID, hdr.bth.psn, hdr.bth.psn+1);
            ig_md.bridge.has_aeth = true;
            ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
            //ig_intr_md_for_dprsr.drop_ctl = 1;
            //ig_tm_md.mirror_session_id = ig_md.ing_rank_id;
            return;
        }
        
        // process data from tx
        if (ig_md.bridge.conn_semantics == CONN_SEMANTICS.CONN_TX) {
            if (hdr.bth.opcode != RDMA_OP_WRITE_FIRST && 
                hdr.bth.opcode != RDMA_OP_WRITE_MIDDLE &&
                hdr.bth.opcode != RDMA_OP_WRITE_LAST &&
                hdr.bth.opcode != RDMA_OP_WRITE_ONLY) {
                ig_dprsr_md.drop_ctl = 1;
                return;
            }
            
            // PSN validation
            psn_to_check = (bit<32>)hdr.bth.psn;
            bit<24> expected_epsn = (bit<24>)ra_read_cond_inc_tx_epsn.execute(channel_idx);
            bit<32> msn_saved = ra_read_tx_msn.execute(channel_idx);
            if(hdr.bth.psn > expected_epsn) {
                set_ack_ingress(AETH_NAK_SEQ_ERR, expected_epsn-1, msn_saved[23:0]);
                ig_md.bridge.has_aeth = true;
                ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
                //ig_intr_md_for_dprsr.drop_ctl = 1;
                //ig_tm_md.mirror_session_id = ig_md.ing_rank_id;
                return;
            } else if(hdr.bth.psn < expected_epsn){
                set_ack_ingress(AETH_ACK_CREDIT_INVALID, expected_epsn-1, msn_saved[23:0]);
                ig_md.bridge.has_aeth = true;
                ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
                return;
            }
            
            // fetch bitmap
            if (hdr.bth.opcode == RDMA_OP_WRITE_FIRST || 
                hdr.bth.opcode == RDMA_OP_WRITE_ONLY) {
                ig_md.bridge.bitmap = hdr.reth.addr[31:0]; // 32ports in tofino
                ra_write_tx_bitmap.execute(channel_idx);
            } else {
                ig_md.bridge.bitmap = ra_read_tx_bitmap.execute(channel_idx);
            }
            
            // multicast group
            ig_tm_md.mcast_grp_a = 100; // group id 100 is to all ports

            // ACK to ingress port
            set_ack_ingress(AETH_ACK_CREDIT_INVALID, expected_epsn-1, msn_saved[23:0]);
            ig_md.bridge.has_aeth = true;
            ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
            // MSN
            if (hdr.bth.opcode == RDMA_OP_WRITE_ONLY || 
                hdr.bth.opcode == RDMA_OP_WRITE_LAST) {
                ra_inc_tx_msn.execute(channel_idx);
            }
        }
    }
}


/***************************************************************************
 * Dispatch Egress Control
 * Bridge header: 
    header bridge_h {
        bool is_roce;
        bool has_reth;
        bool has_aeth;
        bool has_payload;
        CONN_PHASE  conn_phase;    // dispatch or combine
        CONN_SEMANTICS conn_semantics;
        bit<32>    channel_id;
        bitmap_tofino_t    bitmap;
    }
 ***************************************************************************/


/*******************************************************************************
 * RxPsnSlot - PSN management for a single RX
 ******************************************************************************/
control RxPsnSlot(
    out bit<32> result_psn,
    in bit<32> init_value,
    in DISPATCH_REG_OP operation,
    in bit<32> channel_idx) 
{
    bit<32> init_val;

    Register<bit<32>, bit<32>>(DISPATCH_CHANNELS_NUM) reg_psn;

    RegisterAction<bit<32>, bit<32>, void>(reg_psn) ra_init = {
        void apply(inout bit<32> value) {
            value = init_val;
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
            ra_init.execute(channel_idx);
        } else if (operation == DISPATCH_REG_OP.OP_READ_INC) {
            result_psn = ra_read_inc.execute(channel_idx);
        }
    }
}

/*******************************************************************************
 * RxAddrSlot - Address management for a single RX
 ******************************************************************************/
control RxAddrSlot(
    out bit<32> result_addr_lo,
    out bit<32> result_addr_hi,
    in bit<32> init_addr_lo,
    in bit<32> init_addr_hi,
    in bit<32> add_value,
    in DISPATCH_REG_OP operation,
    in bit<32> channel_idx
) {
    addr_tofino_t init_addr;
    bit<32> add_val;

    Register<addr_tofino_t, bit<32>>(TX_DISPATCH_CHANNELS_NUM) reg_addr;

    RegisterAction<addr_tofino_t, bit<32>, void>(reg_addr) ra_init = {
        void apply(inout addr_tofino_t value) {
            value.lo = init_addr.lo;
            value.hi = init_addr.hi;
        }
    };

    RegisterAction<addr_tofino_t, bit<32>, addr_tofino_t>(reg_addr) ra_read_add = {
        void apply(inout addr_tofino_t value, out addr_tofino_t result) {
            result = value;
            value.lo = value.lo + add_val;
        }
    };

    apply {
        if (operation == DISPATCH_REG_OP.OP_INIT) {
            init_addr.lo = init_addr_lo;
            init_addr.hi = init_addr_hi;
            ra_init.execute(channel_idx);
        } else if (operation == DISPATCH_REG_OP.OP_READ_ADD) {
            add_val = add_value;
            addr_tofino_t tmp = ra_read_add.execute(channel_idx);
            result_addr_lo = tmp.lo;
            result_addr_hi = tmp.hi;
        }
    }
}

/*******************************************************************************
 * DispatchEgress
 ******************************************************************************/
control DispatchEgress(
    inout a2a_headers_t hdr,
    inout a2a_egress_metadata_t eg_md,
    in egress_intrinsic_metadata_t eg_intr_md,
    inout egress_intrinsic_metadata_for_deparser_t eg_dprsr_md)
{
    /***************************************************************************
     * PSN Slot Instances (EP_SIZE = 8)
     ***************************************************************************/
    RxPsnSlot() psn_slot_0;
    RxPsnSlot() psn_slot_1;
    RxPsnSlot() psn_slot_2;
    RxPsnSlot() psn_slot_3;
    RxPsnSlot() psn_slot_4;
    RxPsnSlot() psn_slot_5;
    RxPsnSlot() psn_slot_6;
    RxPsnSlot() psn_slot_7;

    /***************************************************************************
     * Addr Slot Instances (EP_SIZE = 8)
     ***************************************************************************/
    RxAddrSlot() addr_slot_0;
    RxAddrSlot() addr_slot_1;
    RxAddrSlot() addr_slot_2;
    RxAddrSlot() addr_slot_3;
    RxAddrSlot() addr_slot_4;
    RxAddrSlot() addr_slot_5;
    RxAddrSlot() addr_slot_6;
    RxAddrSlot() addr_slot_7;

    /***************************************************************************
     * Local Variables
     ***************************************************************************/
    bit<32> channel_idx;
    bit<32> result_psn;
    bit<32> result_addr_lo;
    bit<32> result_addr_hi;
    bit<32> payload_len_32;

    /***************************************************************************
     * Table - Set RX info based on egress_rid
     **************************************************************************/
    action get_rank_id(bit<8> rank_id) {
        eg_md.eg_rank_id = rank_id;
    }

    table dispatch_rank_info {
        key = {
            eg_md.bridge.channel_id : exact;
            eg_intr_md.egress_port   : exact;
        }
        actions = {
            get_rank_id;
            NoAction;
        }
        size = 1024;
        default_action = NoAction;
    }


    action set_rx_info(bit<48> dst_mac, bit<32> dst_ip, 
                       bit<24> dst_qp, bit<32> rkey) {

        hdr.eth.dst_addr = dst_mac;
        hdr.ipv4.dst_addr = dst_ip;
        hdr.bth.dst_qp = dst_qp;
        hdr.reth.rkey = rkey;
    }

    table dispatch_rx_info {
        key = {
            eg_md.bridge.channel_id : exact;
            eg_md.eg_rank_id   : exact;
        }
        actions = {
            set_rx_info;
            NoAction;
        }
        size = 1024;
        default_action = NoAction;
    }

    /***************************************************************************
     * Apply
     ***************************************************************************/
    action set_ack_egress() {
        // Remove unnecessary headers
        hdr.reth.setInvalid();
        hdr.payload.setInvalid();
        
        // BTH
        hdr.bth.opcode = RDMA_OP_ACK;
        
        // UDP
        hdr.udp.length = 28;
        bit<16> tmp_port = hdr.udp.src_port;
        hdr.udp.src_port = hdr.udp.dst_port;
        hdr.udp.dst_port = tmp_port;
        hdr.udp.checksum = 0;
        
        // IPv4
        hdr.ipv4.total_len = 48;
        bit<32> tmp_ip = hdr.ipv4.src_addr;
        hdr.ipv4.src_addr = hdr.ipv4.dst_addr;
        hdr.ipv4.dst_addr = tmp_ip;
        
        // Ethernet
        bit<48> tmp_mac = hdr.eth.src_addr;
        hdr.eth.src_addr = hdr.eth.dst_addr;
        hdr.eth.dst_addr = tmp_mac;
    }

    apply {

        dispatch_rank_info.apply();
        channel_idx = (bit<32>)eg_md.bridge.channel_id;

        // ==================== Control connection: initialize all RX ====================
        if (eg_md.bridge.conn_semantics == CONN_SEMANTICS.CONN_CONTROL) {
            
            // Initialize PSN (payload: data00 - data07)
            psn_slot_0.apply(result_psn, hdr.payload.data00, DISPATCH_REG_OP.OP_INIT, channel_idx);
            psn_slot_1.apply(result_psn, hdr.payload.data01, DISPATCH_REG_OP.OP_INIT, channel_idx);
            psn_slot_2.apply(result_psn, hdr.payload.data02, DISPATCH_REG_OP.OP_INIT, channel_idx);
            psn_slot_3.apply(result_psn, hdr.payload.data03, DISPATCH_REG_OP.OP_INIT, channel_idx);
            psn_slot_4.apply(result_psn, hdr.payload.data04, DISPATCH_REG_OP.OP_INIT, channel_idx);
            psn_slot_5.apply(result_psn, hdr.payload.data05, DISPATCH_REG_OP.OP_INIT, channel_idx);
            psn_slot_6.apply(result_psn, hdr.payload.data06, DISPATCH_REG_OP.OP_INIT, channel_idx);
            psn_slot_7.apply(result_psn, hdr.payload.data07, DISPATCH_REG_OP.OP_INIT, channel_idx);

            // Initialize Addr (payload: data08-data17, each address 64-bit = lo + hi)
            // addr_tofino_t structure: {lo, hi}
            addr_slot_0.apply(result_addr_lo, result_addr_hi,
                              hdr.payload.data08, hdr.payload.data09,
                              0, DISPATCH_REG_OP.OP_INIT, channel_idx);
            addr_slot_1.apply(result_addr_lo, result_addr_hi,
                              hdr.payload.data0a, hdr.payload.data0b,
                              0, DISPATCH_REG_OP.OP_INIT, channel_idx);
            addr_slot_2.apply(result_addr_lo, result_addr_hi,
                              hdr.payload.data0c, hdr.payload.data0d,
                              0, DISPATCH_REG_OP.OP_INIT, channel_idx);
            addr_slot_3.apply(result_addr_lo, result_addr_hi,
                              hdr.payload.data0e, hdr.payload.data0f,
                              0, DISPATCH_REG_OP.OP_INIT, channel_idx);
            addr_slot_4.apply(result_addr_lo, result_addr_hi,
                              hdr.payload.data10, hdr.payload.data11,
                              0, DISPATCH_REG_OP.OP_INIT, channel_idx);
            addr_slot_5.apply(result_addr_lo, result_addr_hi,
                              hdr.payload.data12, hdr.payload.data13,
                              0, DISPATCH_REG_OP.OP_INIT, channel_idx);
            addr_slot_6.apply(result_addr_lo, result_addr_hi,
                              hdr.payload.data14, hdr.payload.data15,
                              0, DISPATCH_REG_OP.OP_INIT, channel_idx);
            addr_slot_7.apply(result_addr_lo, result_addr_hi,
                              hdr.payload.data16, hdr.payload.data17,
                              0, DISPATCH_REG_OP.OP_INIT, channel_idx);

            set_ack_egress.apply();

            return;
        }

        // ==================== Data connection: Multicast replica processing ====================
        if (eg_md.bridge.conn_semantics == CONN_SEMANTICS.CONN_TX) {
            if((eg_intr_md.egress_rid == 0)&&(em_md.bridge.ing_rank_id == eg_md.eg_rank_id)) {
                set_ack_egress.apply();
            }
            else if(((eg_md.bridge.bitmap >> em_md.eg_rank_id) & 1) == 1){
                // Bcast packet to all replicas
                payload_len_32 = 1024;  // to add addr
                // Lookup and set RX info based on egress_rid
                dispatch_rx_info.apply();

                // ===== PSN: select corresponding slot based on rank_id =====
                if (eg_md.eg_rank_id == 0) {
                    psn_slot_0.apply(result_psn, 0, DISPATCH_REG_OP.OP_READ_INC, channel_idx);
                } else if (eg_md.eg_rank_id == 1) {
                    psn_slot_1.apply(result_psn, 0, DISPATCH_REG_OP.OP_READ_INC, channel_idx);
                } else if (eg_md.eg_rank_id == 2) {
                    psn_slot_2.apply(result_psn, 0, DISPATCH_REG_OP.OP_READ_INC, channel_idx);
                } else if (eg_md.eg_rank_id == 3) {
                    psn_slot_3.apply(result_psn, 0, DISPATCH_REG_OP.OP_READ_INC, channel_idx);
                } else if (eg_md.eg_rank_id == 4) {
                    psn_slot_4.apply(result_psn, 0, DISPATCH_REG_OP.OP_READ_INC, channel_idx);
                } else if (eg_md.eg_rank_id == 5) {
                    psn_slot_5.apply(result_psn, 0, DISPATCH_REG_OP.OP_READ_INC, channel_idx);
                } else if (eg_md.eg_rank_id == 6) {
                    psn_slot_6.apply(result_psn, 0, DISPATCH_REG_OP.OP_READ_INC, channel_idx);
                } else if (eg_md.eg_rank_id == 7) {
                    psn_slot_7.apply(result_psn, 0, DISPATCH_REG_OP.OP_READ_INC, channel_idx);
                }

                // Update BTH PSN
                hdr.bth.psn = result_psn[23:0];

                // ===== Addr: only update when RETH is valid =====
                if (hdr.reth.isValid() && 
                    (hdr.bth.opcode == RDMA_OP_WRITE_FIRST || 
                    hdr.bth.opcode == RDMA_OP_WRITE_ONLY)) {
                    if (eg_md.eg_rank_id == 0) {
                        addr_slot_0.apply(result_addr_lo, result_addr_hi, 0, 0,
                                        payload_len_32, DISPATCH_REG_OP.OP_READ_ADD, channel_idx);
                    } else if (eg_md.eg_rank_id == 1) {
                        addr_slot_1.apply(result_addr_lo, result_addr_hi, 0, 0,
                                        payload_len_32, DISPATCH_REG_OP.OP_READ_ADD, channel_idx);
                    } else if (eg_md.eg_rank_id == 2) {
                        addr_slot_2.apply(result_addr_lo, result_addr_hi, 0, 0,
                                        payload_len_32, DISPATCH_REG_OP.OP_READ_ADD, channel_idx);
                    } else if (eg_md.eg_rank_id == 3) {
                        addr_slot_3.apply(result_addr_lo, result_addr_hi, 0, 0,
                                        payload_len_32, DISPATCH_REG_OP.OP_READ_ADD, channel_idx);
                    } else if (eg_md.eg_rank_id == 4) {
                        addr_slot_4.apply(result_addr_lo, result_addr_hi, 0, 0,
                                        payload_len_32, DISPATCH_REG_OP.OP_READ_ADD, channel_idx);
                    } else if (eg_md.eg_rank_id == 5) {
                        addr_slot_5.apply(result_addr_lo, result_addr_hi, 0, 0,
                                        payload_len_32, DISPATCH_REG_OP.OP_READ_ADD, channel_idx);
                    } else if (eg_md.eg_rank_id == 6) {
                        addr_slot_6.apply(result_addr_lo, result_addr_hi, 0, 0,
                                        payload_len_32, DISPATCH_REG_OP.OP_READ_ADD, channel_idx);
                    } else if (eg_md.eg_rank_id == 7) {
                        addr_slot_7.apply(result_addr_lo, result_addr_hi, 0, 0,
                                        payload_len_32, DISPATCH_REG_OP.OP_READ_ADD, channel_idx);
                    }

                    // Update RETH addr (addr_tofino_t: lo first, hi second)
                    hdr.reth.addr[31:0] = result_addr_lo;
                    hdr.reth.addr[63:32] = result_addr_hi;
                }

                hdr.aeth.setInvalid();
            }
            else {
                eg_dprsr_md.drop_ctl = 1;
            }
        }
    }
}