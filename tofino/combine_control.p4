/*******************************************************************************
 * Combine Control for AllToAll Communication - In-Network Aggregation
 * Using macros instead of sub-controls to avoid variable duplication
 ******************************************************************************/

#include "combine_macros.p4"

#define NUM_COMBINE_CHANNELS_PER_RX 8
#define COMBINE_QUEUE_LENGTH 64
#define TOKEN_SIZE 7168
#define PAYLOAD_LEN 1024
#define TOKEN_PACKETS (TOKEN_SIZE / PAYLOAD_LEN)
#define N_AGG_SLOTS 32
#define BYTES_PER_SLOT 4
#define BITMAP_PER_PACKET 8

#define COMBINE_CHANNELS_TOTAL (EP_SIZE * NUM_COMBINE_CHANNELS_PER_RX)
#define PACKET_NUM_PER_CHANNEL_BUFFER (COMBINE_QUEUE_LENGTH * TOKEN_PACKETS)
#define COMBINE_BUFFER_ENTRIES (COMBINE_CHANNELS_TOTAL * PACKET_NUM_PER_CHANNEL_BUFFER)
#define COMBINE_TX_ENTRIES (COMBINE_CHANNELS_TOTAL * EP_SIZE)
#define COMBINE_BITMAP_ENTRIES (COMBINE_CHANNELS_TOTAL * COMBINE_QUEUE_LENGTH)


/*******************************************************************************
 * CombineIngress - main control logic with inline registers
 ******************************************************************************/
control CombineIngress(
    inout a2a_headers_t hdr,
    inout a2a_ingress_metadata_t ig_md,
    in ingress_intrinsic_metadata_t ig_intr_md,
    inout ingress_intrinsic_metadata_for_deparser_t ig_dprsr_md,
    inout ingress_intrinsic_metadata_for_tm_t ig_tm_md)
{

    /***************************************************************************
     * TX State Registers
     ***************************************************************************/
    Register<bit<32>, bit<32>>(COMBINE_TX_ENTRIES, 0) reg_tx_epsn;
    Register<bit<32>, bit<32>>(COMBINE_TX_ENTRIES) reg_tx_msn;
    Register<bit<32>, bit<32>>(COMBINE_TX_ENTRIES) reg_tx_loc;
    Register<bit<32>, bit<32>>(COMBINE_TX_ENTRIES) reg_tx_packet_offset;

    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_tx_epsn) ra_read_cond_inc_tx_epsn = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
            if(ig_md.psn == value) {
                value = value + 1;
            }
        }
    };

    RegisterAction<bit<32>, bit<32>, void>(reg_tx_epsn) ra_init_tx_epsn = {
        void apply(inout bit<32> value) { value = 0; }
    };

    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_tx_msn) ra_read_tx_msn = {
        void apply(inout bit<32> value, out bit<32> result) { result = value; }
    };

    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_tx_msn) ra_read_inc_tx_msn = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
            value = value + 1;
        }
    };

    RegisterAction<bit<32>, bit<32>, void>(reg_tx_msn) ra_init_tx_msn = {
        void apply(inout bit<32> value) { value = 0; }
    };

    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_tx_loc) ra_read_tx_loc = {
        void apply(inout bit<32> value, out bit<32> result) { result = value; }
    };

    RegisterAction<bit<32>, bit<32>, void>(reg_tx_loc) ra_write_tx_loc = {
        void apply(inout bit<32> value) { value = ig_md.tx_loc_val; }
    };

    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_tx_packet_offset) ra_read_inc_tx_offset = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
            value = value + 1;
        }
    };

    RegisterAction<bit<32>, bit<32>, void>(reg_tx_packet_offset) ra_reset_tx_offset = {
        void apply(inout bit<32> value) { value = 1; }
    };

    action do_read_cond_inc_tx_epsn(bit<32> idx) { ig_md.tmp_a = ra_read_cond_inc_tx_epsn.execute(idx); }
    action do_init_tx_epsn(bit<32> idx) { ra_init_tx_epsn.execute(idx); }
    action do_read_tx_msn(bit<32> idx) { ig_md.tmp_b = ra_read_tx_msn.execute(idx); }
    action do_read_inc_tx_msn(bit<32> idx) { ig_md.tmp_b = ra_read_inc_tx_msn.execute(idx); }
    action do_init_tx_msn(bit<32> idx) { ra_init_tx_msn.execute(idx); }
    action do_read_tx_loc(bit<32> idx) { ig_md.tx_loc_val = ra_read_tx_loc.execute(idx); }
    action do_write_tx_loc(bit<32> idx) { ra_write_tx_loc.execute(idx); }
    action do_read_inc_tx_offset(bit<32> idx) { ig_md.tx_offset_val = ra_read_inc_tx_offset.execute(idx); }
    action do_reset_tx_offset(bit<32> idx) { ra_reset_tx_offset.execute(idx); }

    /***************************************************************************
     * RX State Registers
     ***************************************************************************/
    Register<bit<32>, bit<32>>(COMBINE_CHANNELS_TOTAL, 0) reg_rx_bitmap_epsn;
    Register<bit<32>, bit<32>>(COMBINE_CHANNELS_TOTAL, 0) reg_rx_token_epsn;
    Register<bit<32>, bit<32>>(COMBINE_CHANNELS_TOTAL, 0) reg_rx_token_msn;

    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_rx_bitmap_epsn) ra_read_rx_bitmap_epsn = {
        void apply(inout bit<32> value, out bit<32> result) { result = value; }
    };

    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_rx_bitmap_epsn) ra_read_cond_inc_rx_bitmap_epsn = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
            if (ig_md.psn == value) { value = value + 1; }
        }
    };

    RegisterAction<bit<32>, bit<32>, void>(reg_rx_bitmap_epsn) ra_init_rx_bitmap_epsn = {
        void apply(inout bit<32> value) { value = 0; }
    };

    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_rx_token_epsn) ra_read_rx_token_epsn = {
        void apply(inout bit<32> value, out bit<32> result) { result = value; }
    };

    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_rx_token_epsn) ra_read_add_rx_token_epsn = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
            value = value + TOKEN_PACKETS;
        }
    };

    RegisterAction<bit<32>, bit<32>, void>(reg_rx_token_epsn) ra_init_rx_token_epsn = {
        void apply(inout bit<32> value) { value = 0; }
    };

    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_rx_token_msn) ra_read_inc_rx_token_msn = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
            value = value + 1;
        }
    };

    action do_read_rx_bitmap_epsn(bit<32> idx) { ig_md.tmp_a = ra_read_rx_bitmap_epsn.execute(idx); }
    action do_read_cond_inc_rx_bitmap_epsn(bit<32> idx) { ig_md.tmp_a = ra_read_cond_inc_rx_bitmap_epsn.execute(idx); }
    action do_init_rx_bitmap_epsn(bit<32> idx) { ra_init_rx_bitmap_epsn.execute(idx); }
    action do_read_rx_token_epsn(bit<32> idx) { ig_md.tmp_a = ra_read_rx_token_epsn.execute(idx); }
    action do_read_add_rx_token_epsn(bit<32> idx) { ig_md.tmp_a = ra_read_add_rx_token_epsn.execute(idx); }
    action do_init_rx_token_epsn(bit<32> idx) { ra_init_rx_token_epsn.execute(idx); }
    action do_read_inc_rx_token_msn(bit<32> idx) { ig_md.tmp_a = ra_read_inc_rx_token_msn.execute(idx); }

    /***************************************************************************
     * Queue Pointer Slots - using macros
     ***************************************************************************/
    // Queue Head Slots (8 instances)
    QUEUE_PTR_SLOT_DECLARE(queue_head_0)
    QUEUE_PTR_SLOT_DECLARE(queue_head_1)
    QUEUE_PTR_SLOT_DECLARE(queue_head_2)
    QUEUE_PTR_SLOT_DECLARE(queue_head_3)
    QUEUE_PTR_SLOT_DECLARE(queue_head_4)
    QUEUE_PTR_SLOT_DECLARE(queue_head_5)
    QUEUE_PTR_SLOT_DECLARE(queue_head_6)
    QUEUE_PTR_SLOT_DECLARE(queue_head_7)

    // Queue Tail Slots (8 instances)
    QUEUE_PTR_SLOT_DECLARE(queue_tail_0)
    QUEUE_PTR_SLOT_DECLARE(queue_tail_1)
    QUEUE_PTR_SLOT_DECLARE(queue_tail_2)
    QUEUE_PTR_SLOT_DECLARE(queue_tail_3)
    QUEUE_PTR_SLOT_DECLARE(queue_tail_4)
    QUEUE_PTR_SLOT_DECLARE(queue_tail_5)
    QUEUE_PTR_SLOT_DECLARE(queue_tail_6)
    QUEUE_PTR_SLOT_DECLARE(queue_tail_7)

    /***************************************************************************
     * Queue Incomplete Register
     ***************************************************************************/
    Register<bit<32>, bit<32>>(COMBINE_CHANNELS_TOTAL) reg_queue_incomplete;

    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_queue_incomplete) ra_read_queue_incomplete = {
        void apply(inout bit<32> value, out bit<32> result) { result = value; }
    };

    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_queue_incomplete) ra_read_cond_inc_queue_incomplete = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
            if(value == ig_md.tx_loc_val) {
                if (value >= COMBINE_QUEUE_LENGTH - 1) { value = 0; }
                else { value = value + 1; }
            }
        }
    };

    RegisterAction<bit<32>, bit<32>, void>(reg_queue_incomplete) ra_init_queue_incomplete = {
        void apply(inout bit<32> value) { value = 0; }
    };

    action do_read_cond_inc_queue_incomplete(bit<32> idx) { ig_md.tmp_a = ra_read_cond_inc_queue_incomplete.execute(idx); }
    action do_init_queue_incomplete(bit<32> idx) { ra_init_queue_incomplete.execute(idx); }

    /***************************************************************************
     * Bitmap Slots - using macros (8 instances)
     ***************************************************************************/
    BITMAP_SLOT_DECLARE(bitmap_0)
    BITMAP_SLOT_DECLARE(bitmap_1)
    BITMAP_SLOT_DECLARE(bitmap_2)
    BITMAP_SLOT_DECLARE(bitmap_3)
    BITMAP_SLOT_DECLARE(bitmap_4)
    BITMAP_SLOT_DECLARE(bitmap_5)
    BITMAP_SLOT_DECLARE(bitmap_6)
    BITMAP_SLOT_DECLARE(bitmap_7)

    /***************************************************************************
     * Addr Slots - using macros (8 instances)
     ***************************************************************************/
    ADDR_SLOT_DECLARE(addr_0)
    ADDR_SLOT_DECLARE(addr_1)
    ADDR_SLOT_DECLARE(addr_2)
    ADDR_SLOT_DECLARE(addr_3)
    ADDR_SLOT_DECLARE(addr_4)
    ADDR_SLOT_DECLARE(addr_5)
    ADDR_SLOT_DECLARE(addr_6)
    ADDR_SLOT_DECLARE(addr_7)

    /***************************************************************************
     * Clear Buffer Register
     ***************************************************************************/
    Register<bit<32>, bit<32>>(COMBINE_BITMAP_ENTRIES) reg_clear_buffer;

    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_clear_buffer) ra_read_set_clear = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
            if(value <= ig_md.tx_offset_val) { value = value + 1; }
        }
    };

    RegisterAction<bit<32>, bit<32>, void>(reg_clear_buffer) ra_reset_clear = {
        void apply(inout bit<32> value) { value = 0; }
    };

    action do_read_set_clear() { ig_md.tmp_a = ra_read_set_clear.execute(ig_md.tmp_b); } // token_idx
    action do_reset_clear(bit<32> idx) { ra_reset_clear.execute(idx); }

    /***************************************************************************
     * Utility Actions
     ***************************************************************************/

    action mul_256() { ig_md.msn = ig_md.msn * 256; }

    action set_aeth_msn() {
        ig_md.has_aeth = true;
        hdr.aeth.setValid();
        hdr.aeth.msn = ig_md.msn;
    }

    action set_aeth_syndrome(bit<32> syndrome) { ig_md.msn = ig_md.msn + syndrome; }
    action set_aeth_psn(bit<32> psn) { hdr.bth.psn = psn; }

    action swap_l2_l3_l4() {
        bit<48> tmp_mac = hdr.eth.src_addr;
        hdr.eth.src_addr = hdr.eth.dst_addr;
        hdr.eth.dst_addr = tmp_mac;
        bit<32> tmp_ip = hdr.ipv4.src_addr;
        hdr.ipv4.src_addr = hdr.ipv4.dst_addr;
        hdr.ipv4.dst_addr = tmp_ip;
        bit<16> tmp_port = hdr.udp.src_port;
        hdr.udp.src_port = hdr.udp.dst_port;
        hdr.udp.dst_port = tmp_port;
    }

    action set_ack_len() {
        hdr.udp.length = 28;
        hdr.ipv4.total_len = 48;
        hdr.udp.checksum = 0;
    }

    action set_bitmap_clear_mask(bitmap_tofino_t m) { ig_md.tmp_c = m; }

    table tbl_rank_to_clear_mask {
        key = { ig_md.ing_rank_id : exact; }
        actions = { set_bitmap_clear_mask; }
        size = 8;
        default_action = set_bitmap_clear_mask((bitmap_tofino_t)0);
        const entries = {
            0 : set_bitmap_clear_mask((bitmap_tofino_t)8w0x01);
            1 : set_bitmap_clear_mask((bitmap_tofino_t)8w0x02);
            2 : set_bitmap_clear_mask((bitmap_tofino_t)8w0x04);
            3 : set_bitmap_clear_mask((bitmap_tofino_t)8w0x08);
            4 : set_bitmap_clear_mask((bitmap_tofino_t)8w0x10);
            5 : set_bitmap_clear_mask((bitmap_tofino_t)8w0x20);
            6 : set_bitmap_clear_mask((bitmap_tofino_t)8w0x40);
            7 : set_bitmap_clear_mask((bitmap_tofino_t)8w0x80);
        }
    }

    /***************************************************************************
     * Compare Table
     ***************************************************************************/
    action set_cmp(bit<32> cmp){
        ig_md.cmp = cmp;
    }

    // table tbl_compare_a {
    //     key = {
    //         ig_md.diff : ternary;
    //     }
    //     actions = {
    //         set_cmp;
    //     }
    // }

    // table tbl_compare_b {
    //     key = {
    //         ig_md.diff : ternary;
    //     }
    //     actions = {
    //         set_cmp;
    //     }
    // }

    /***************************************************************************
     * Index Calculation Actions
     ***************************************************************************/
    action step1_cal_tx_reg_idx() { ig_md.tx_reg_idx = ig_md.ing_rank_id; }
    action step2_cal_tx_reg_idx() { ig_md.tx_reg_idx = ig_md.tx_reg_idx + ig_md.channel_class; }

    action step1_calc_token_idx_from_tail() { ig_md.tmp_a = ig_md.channel_id * 64; }
    action step2_calc_token_idx_from_tail() { ig_md.tmp_b = ig_md.tmp_c; }
    action step3_calc_token_idx_from_tail() { ig_md.tmp_b = ig_md.tmp_b + ig_md.tmp_a; } // tmp_b as token_idx
    
    action calc_slot_index_from_token_idx() { ig_md.tmp_b = ig_md.tmp_b >> 3; } // tmp_b as slot_index
    action calc_slot_id_from_token_idx() { ig_md.tmp_a = ig_md.tmp_b << 3;} // tmp_a as slot_id

    action calc_slot_index_from_next_token() { ig_md.tmp_b = ig_md.tmp_b >> 3; }
    action calc_slot_id_from_next_token_idx() { ig_md.tmp_a = ig_md.tmp_b << 3;} // tmp_a as slot_id


    action step1_calc_token_idx_from_tx_loc() { ig_md.tmp_a = ig_md.channel_id * 64; }
    action step2_calc_token_idx_from_tx_loc() { ig_md.tmp_b = ig_md.tx_loc_val; }
    action step3_calc_token_idx_from_tx_loc() { ig_md.tmp_b = ig_md.tmp_b + ig_md.tmp_a; }

    bit<32> temp_head_shifted;
    action step1_calc_shift_head() { ig_md.tmp_a = ig_md.tmp_a << 16; }
    action step2_calc_combine_tail() { ig_md.tmp_a = ig_md.tmp_a | ig_md.tmp_c; }
    action step3_write_payload_data_0() { hdr.payload.data00 = ig_md.tmp_a; }
    // action step3_write_payload_data_1() { hdr.payload.data01 = ig_md.tmp_a; }
    // action step3_write_payload_data_2() { hdr.payload.data02 = ig_md.tmp_a; }
    // action step3_write_payload_data_3() { hdr.payload.data03 = ig_md.tmp_a; }
    // action step3_write_payload_data_4() { hdr.payload.data04 = ig_md.tmp_a; }
    // action step3_write_payload_data_5() { hdr.payload.data05 = ig_md.tmp_a; }
    // action step3_write_payload_data_6() { hdr.payload.data06 = ig_md.tmp_a; }
    // action step3_write_payload_data_7() { hdr.payload.data07 = ig_md.tmp_a; }

    action step1_calc_next_token_idx_from_next_loc() { ig_md.tmp_a = ig_md.channel_id << 6; }
    action step2_calc_next_token_idx_from_next_loc() { ig_md.tmp_b = ig_md.tmp_a + ig_md.tmp_b; }

    action step_write_addr_lo() { ig_md.next_token_addr[31:0] = ig_md.tmp_d; }
    action step_write_addr_hi() { ig_md.next_token_addr[63:32] = ig_md.tmp_e; }

    /***************************************************************************
     * Apply
     ***************************************************************************/
    apply {

        step1_cal_tx_reg_idx();
        step2_cal_tx_reg_idx();

        // ================================================================
        // CONN_CONTROL: query queue pointer (READ)
        // ================================================================
        if (ig_md.conn_semantics == CONN_SEMANTICS.CONN_CONTROL) {
            if (hdr.bth.opcode == RDMA_OP_READ_REQ) {
                QUEUE_PTR_READ(queue_head_0); ig_md.tmp_a = ig_md.tmp_c; // queue_head ig_md.tmp_a
                QUEUE_PTR_READ(queue_tail_0); 
                step1_calc_shift_head(); step2_calc_combine_tail(); step3_write_payload_data_0();

                QUEUE_PTR_READ(queue_head_1); ig_md.tmp_a = ig_md.tmp_c;
                QUEUE_PTR_READ(queue_tail_1); 
                //step1_calc_shift_head(); step2_calc_combine_tail(); step3_write_payload_data_1();

                QUEUE_PTR_READ(queue_head_2); ig_md.tmp_a = ig_md.tmp_c;
                QUEUE_PTR_READ(queue_tail_2); 
                //step1_calc_shift_head(); step2_calc_combine_tail(); step3_write_payload_data_2();

                QUEUE_PTR_READ(queue_head_3); ig_md.tmp_a = ig_md.tmp_c;
                QUEUE_PTR_READ(queue_tail_3); 
                //step1_calc_shift_head(); step2_calc_combine_tail(); step3_write_payload_data_3();

                QUEUE_PTR_READ(queue_head_4); ig_md.tmp_a = ig_md.tmp_c;
                QUEUE_PTR_READ(queue_tail_4); 
                //step1_calc_shift_head(); step2_calc_combine_tail(); step3_write_payload_data_4();

                QUEUE_PTR_READ(queue_head_5); ig_md.tmp_a = ig_md.tmp_c;
                QUEUE_PTR_READ(queue_tail_5); 
                //step1_calc_shift_head(); step2_calc_combine_tail(); step3_write_payload_data_5();

                QUEUE_PTR_READ(queue_head_6); ig_md.tmp_a = ig_md.tmp_c;
                QUEUE_PTR_READ(queue_tail_6); 
                //step1_calc_shift_head(); step2_calc_combine_tail(); step3_write_payload_data_6();

                QUEUE_PTR_READ(queue_head_7); ig_md.tmp_a = ig_md.tmp_c;
                QUEUE_PTR_READ(queue_tail_7); 
                //step1_calc_shift_head(); step2_calc_combine_tail(); step3_write_payload_data_7();

                ig_md.msn = ig_md.psn + 32w1;
                mul_256();
                set_aeth_syndrome(AETH_ACK_CREDIT_INVALID);
                set_aeth_msn();
                set_aeth_psn(ig_md.psn);
                ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
            }
            return;
        }

        // ================================================================
        // CONN_BITMAP: rx writes bitmap (WRITE_ONLY)
        // ================================================================
        if (ig_md.conn_semantics == CONN_SEMANTICS.CONN_BITMAP) {
            if (hdr.bth.opcode != RDMA_OP_WRITE_ONLY) {
                ig_dprsr_md.drop_ctl = 1;
                return;
            }

            do_read_cond_inc_rx_bitmap_epsn(ig_md.channel_id);
            // bit<32> expected_psn = ig_md.tmp_a;
            
            ig_md.diff = ig_md.psn - ig_md.tmp_a;

            //tbl_compare_a.apply();

            if (ig_md.cmp == 0) {
                if (ig_md.ing_rank_id == 0) { QUEUE_PTR_READ_ADD(queue_tail_0);  }
                else if (ig_md.ing_rank_id == 1) { QUEUE_PTR_READ_ADD(queue_tail_1);  }
                else if (ig_md.ing_rank_id == 2) { QUEUE_PTR_READ_ADD(queue_tail_2);  }
                else if (ig_md.ing_rank_id == 3) { QUEUE_PTR_READ_ADD(queue_tail_3);  }
                else if (ig_md.ing_rank_id == 4) { QUEUE_PTR_READ_ADD(queue_tail_4);  }
                else if (ig_md.ing_rank_id == 5) { QUEUE_PTR_READ_ADD(queue_tail_5);  }
                else if (ig_md.ing_rank_id == 6) { QUEUE_PTR_READ_ADD(queue_tail_6);  }
                else if (ig_md.ing_rank_id == 7) { QUEUE_PTR_READ_ADD(queue_tail_7);  } // ig_md.queue_tail = ig_md.tmp_c;

                step1_calc_token_idx_from_tail();
                step2_calc_token_idx_from_tail();
                step3_calc_token_idx_from_tail();
                calc_slot_index_from_token_idx(); // tmp_b slot_index

                ig_md.tmp_c = hdr.payload.data00; BITMAP_WRITE(bitmap_0); //tmp_c as write value
                // ig_md.bitmap_write_val = hdr.payload.data01; BITMAP_WRITE(bitmap_1);
                // ig_md.bitmap_write_val = hdr.payload.data02; BITMAP_WRITE(bitmap_2);
                // ig_md.bitmap_write_val = hdr.payload.data03; BITMAP_WRITE(bitmap_3);
                // ig_md.bitmap_write_val = hdr.payload.data04; BITMAP_WRITE(bitmap_4);
                // ig_md.bitmap_write_val = hdr.payload.data05; BITMAP_WRITE(bitmap_5);
                // ig_md.bitmap_write_val = hdr.payload.data06; BITMAP_WRITE(bitmap_6);
                // ig_md.bitmap_write_val = hdr.payload.data07; BITMAP_WRITE(bitmap_7);

                // ig_md.addr_write_val[31:0] = hdr.payload.data08;
                // ig_md.addr_write_val[63:32] = hdr.payload.data09;
                // ADDR_WRITE(addr_0);
                // ig_md.addr_write_val[31:0] = hdr.payload.data0a;
                // ig_md.addr_write_val[63:32] = hdr.payload.data0b;
                // ADDR_WRITE(addr_1);
                // ig_md.addr_write_val[31:0] = hdr.payload.data0c;
                // ig_md.addr_write_val[63:32] = hdr.payload.data0d;
                // ADDR_WRITE(addr_2);
                // ig_md.addr_write_val[31:0] = hdr.payload.data0e;
                // ig_md.addr_write_val[63:32] = hdr.payload.data0f;
                // ADDR_WRITE(addr_3);
                // ig_md.addr_write_val[31:0] = hdr.payload.data10;
                // ig_md.addr_write_val[63:32] = hdr.payload.data11;
                // ADDR_WRITE(addr_4);
                // ig_md.addr_write_val[31:0] = hdr.payload.data12;
                // ig_md.addr_write_val[63:32] = hdr.payload.data13;
                // ADDR_WRITE(addr_5);
                // ig_md.addr_write_val[31:0] = hdr.payload.data14;
                // ig_md.addr_write_val[63:32] = hdr.payload.data15;
                // ADDR_WRITE(addr_6);
                // ig_md.addr_write_val[31:0] = hdr.payload.data16;
                // ig_md.addr_write_val[63:32] = hdr.payload.data17;
                // ADDR_WRITE(addr_7);

                ig_md.msn = ig_md.psn + 32w1;
                mul_256();
                set_aeth_syndrome(AETH_ACK_CREDIT_INVALID);
                set_aeth_msn();
                set_aeth_psn(ig_md.psn);
                ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
                
            } else if (ig_md.cmp == 1) {
                ig_md.msn = ig_md.tmp_a;
                mul_256();
                set_aeth_syndrome(AETH_NAK_SEQ_ERR);
                set_aeth_msn();
                set_aeth_psn(ig_md.tmp_a - 1);
                ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
            } else {
                ig_md.msn = ig_md.tmp_a;
                mul_256();
                set_aeth_syndrome(AETH_ACK_CREDIT_INVALID);
                set_aeth_msn();
                set_aeth_psn(ig_md.tmp_a - 1);
                ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
            }
            return;
        }

        // ================================================================
        // CONN_TX: tx writes token (WRITE) - aggregation
        // ================================================================
        if (ig_md.conn_semantics == CONN_SEMANTICS.CONN_TX && ig_intr_md.ingress_port != LOOPBACK_PORT) {
            if (hdr.bth.opcode != RDMA_OP_WRITE_FIRST && 
                hdr.bth.opcode != RDMA_OP_WRITE_MIDDLE &&
                hdr.bth.opcode != RDMA_OP_WRITE_LAST &&
                hdr.bth.opcode != RDMA_OP_WRITE_ONLY) {
                ig_dprsr_md.drop_ctl = 1;
                return;
            }
            //tbl_compare_a.apply();
            //ig_md.psn_to_read = ig_md.psn; 
            do_read_cond_inc_tx_epsn(ig_md.tx_reg_idx); //bit<32> expected_psn = ig_md.tmp_a;
            do_read_tx_msn(ig_md.tx_reg_idx); //bit<32> current_msn = ig_md.tmp_b;
            // 计算token的loc和packet在token的offset
            
            if (ig_md.cmp == 0) {
                if (hdr.bth.opcode == RDMA_OP_WRITE_FIRST || hdr.bth.opcode == RDMA_OP_WRITE_ONLY) {
                    ig_md.tx_loc_val = hdr.reth.addr[63:32];
                    ig_md.tx_offset_val = 0;
                    do_write_tx_loc(ig_md.tx_reg_idx);
                    do_reset_tx_offset(ig_md.tx_reg_idx);
                } else {
                    do_read_tx_loc(ig_md.tx_reg_idx);
                    do_read_inc_tx_offset(ig_md.tx_reg_idx);
                }
                
                ig_md.msn = ig_md.tmp_b;

                step1_calc_token_idx_from_tx_loc();
                step2_calc_token_idx_from_tx_loc();
                step3_calc_token_idx_from_tx_loc(); // ig_md.tmp_b token_idx
                do_read_set_clear(); // ig_md.tmp_a
                // ig_md.clear_offset = ig_md.tmp_a;

                ig_md.diff = ig_md.tmp_a - ig_md.tx_offset_val;

                //tbl_compare_b.apply();

                if(ig_md.cmp == 1){
                    ig_md.agg_op = AGG_OP.AGGREGATE;
                }
                else{
                    ig_md.agg_op = AGG_OP.STORE;
                }
                
                if (hdr.bth.opcode == RDMA_OP_WRITE_ONLY || hdr.bth.opcode == RDMA_OP_WRITE_LAST) {
                    calc_slot_index_from_token_idx(); // ig_md.tmp_b slot_index 
                    calc_slot_id_from_token_idx(); // ig_md.tmp_a slot_id
                    tbl_rank_to_clear_mask.apply(); // ig_md.tmp_c clear_mask
                    
                    if (ig_md.tmp_a == 0)      { BITMAP_CLEAR_BIT(bitmap_0); ADDR_READ(addr_0); } // ig_md.tmp_c bitmap_result ig_md.tmp_d, ig_md.tmp_e
                    else if (ig_md.tmp_a == 1) { BITMAP_CLEAR_BIT(bitmap_1); ADDR_READ(addr_1); }
                    else if (ig_md.tmp_a == 2) { BITMAP_CLEAR_BIT(bitmap_2); ADDR_READ(addr_2); }
                    else if (ig_md.tmp_a == 3) { BITMAP_CLEAR_BIT(bitmap_3); ADDR_READ(addr_3); }
                    else if (ig_md.tmp_a == 4) { BITMAP_CLEAR_BIT(bitmap_4); ADDR_READ(addr_4); }
                    else if (ig_md.tmp_a == 5) { BITMAP_CLEAR_BIT(bitmap_5); ADDR_READ(addr_5); }
                    else if (ig_md.tmp_a == 6) { BITMAP_CLEAR_BIT(bitmap_6); ADDR_READ(addr_6); }
                    else                   { BITMAP_CLEAR_BIT(bitmap_7); ADDR_READ(addr_7); }

                    do_read_inc_tx_msn(ig_md.tx_reg_idx);
                    
                    if (ig_md.tmp_c == 0) { // token全部聚合完成
                        do_read_cond_inc_queue_incomplete(ig_md.channel_id);
                        // queue_incomplete = ig_md.tmp_a;
                        if (ig_md.tmp_a == ig_md.tx_loc_val) { // 下一个要发的就是我们当前处理的token
                            if (ig_md.ing_rank_id == 0)      { QUEUE_PTR_INC(queue_head_0); }
                            else if (ig_md.ing_rank_id == 1) { QUEUE_PTR_INC(queue_head_1); }
                            else if (ig_md.ing_rank_id == 2) { QUEUE_PTR_INC(queue_head_2); }
                            else if (ig_md.ing_rank_id == 3) { QUEUE_PTR_INC(queue_head_3); }
                            else if (ig_md.ing_rank_id == 4) { QUEUE_PTR_INC(queue_head_4); }
                            else if (ig_md.ing_rank_id == 5) { QUEUE_PTR_INC(queue_head_5); }
                            else if (ig_md.ing_rank_id == 6) { QUEUE_PTR_INC(queue_head_6); }
                            else if (ig_md.ing_rank_id == 7) { QUEUE_PTR_INC(queue_head_7); }
                            
                            ig_tm_md.mcast_grp_b = 200;
                            step_write_addr_lo();
                            step_write_addr_hi();
                        }
                    }
                }

                mul_256();
                set_aeth_syndrome(AETH_ACK_CREDIT_INVALID);
                set_aeth_msn();
                set_aeth_psn(ig_md.psn);
                ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
                
            } else if (ig_md.cmp == 2) {
                ig_md.msn = ig_md.tmp_b;
                mul_256();
                set_aeth_syndrome(AETH_ACK_CREDIT_INVALID);
                set_aeth_msn();
                set_aeth_psn(ig_md.tmp_a - 1);
                ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
            } else {
                ig_md.msn = ig_md.tmp_b;
                mul_256();
                set_aeth_syndrome(AETH_NAK_SEQ_ERR);
                set_aeth_msn();
                set_aeth_psn(ig_md.tmp_a - 1);
                ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
            }
            return;
        }

        // ================================================================
        // Loopback port processing
        // ================================================================
        if (ig_intr_md.ingress_port == LOOPBACK_PORT && hdr.bth.opcode == RDMA_OP_WRITE_FIRST) {
            bit<32> tmp_next_loc = hdr.payload.data00;
            ig_md.tx_loc_val = tmp_next_loc; // ingress先把payload表示的的下一个token（对上一个而言）的loc读进来，作为本token的loc

            ig_md.is_loopback = true;
            
            ig_tm_md.mcast_grp_a = (bit<16>)ig_md.root_rank_id;
            
            do_read_add_rx_token_epsn(ig_md.channel_id); // tmp_a epsn
            ig_md.psn = ig_md.tmp_a;

            //tbl_compare_b.apply();
            //if (tmp_next_loc >= COMBINE_QUEUE_LENGTH - 1) { tmp_next_loc = 0; } // next_loc
            if (ig_md.cmp != 2) { tmp_next_loc = 0; }
            else { tmp_next_loc = tmp_next_loc + 1; } //本质是+1，防绕回
            
            ig_md.tmp_b = tmp_next_loc; // tmp_b next_loc
            
            if (ig_md.root_rank_id == 0)      { QUEUE_PTR_READ(queue_tail_0);  }
            else if (ig_md.root_rank_id == 1) { QUEUE_PTR_READ(queue_tail_1);  }
            else if (ig_md.root_rank_id == 2) { QUEUE_PTR_READ(queue_tail_2);  }
            else if (ig_md.root_rank_id == 3) { QUEUE_PTR_READ(queue_tail_3);  }
            else if (ig_md.root_rank_id == 4) { QUEUE_PTR_READ(queue_tail_4);  }
            else if (ig_md.root_rank_id == 5) { QUEUE_PTR_READ(queue_tail_5);  }
            else if (ig_md.root_rank_id == 6) { QUEUE_PTR_READ(queue_tail_6);  }
            else if (ig_md.root_rank_id == 7) { QUEUE_PTR_READ(queue_tail_7);  } // ig_md.queue_tail = ig_md.tmp_c;
            
            if (ig_md.tmp_b != ig_md.tmp_c) { // 下一个token的loc不是tail
                step1_calc_next_token_idx_from_next_loc();
                step2_calc_next_token_idx_from_next_loc(); // tmp_b next_token_idx
                calc_slot_index_from_next_token(); // tmp_b slot_index
                calc_slot_id_from_next_token_idx(); // tmp_a next_slot_id

                if (ig_md.tmp_a == 0)      { BITMAP_READ(bitmap_0); ADDR_READ(addr_0); } // next_bitmap_result as ig_md.bitmap_result as ig_md.tmp_c 
                else if (ig_md.tmp_a == 1) { BITMAP_READ(bitmap_1);  ADDR_READ(addr_1); }
                else if (ig_md.tmp_a == 2) { BITMAP_READ(bitmap_2);  ADDR_READ(addr_2); }
                else if (ig_md.tmp_a == 3) { BITMAP_READ(bitmap_3);  ADDR_READ(addr_3); }
                else if (ig_md.tmp_a == 4) { BITMAP_READ(bitmap_4);  ADDR_READ(addr_4); }
                else if (ig_md.tmp_a == 5) { BITMAP_READ(bitmap_5);  ADDR_READ(addr_5); }
                else if (ig_md.tmp_a == 6) { BITMAP_READ(bitmap_6);  ADDR_READ(addr_6); }
                else                        { BITMAP_READ(bitmap_7);  ADDR_READ(addr_7); }
                
                if (ig_md.tmp_c == 0) {
                    ig_md.tmp_b = ig_md.tx_loc_val; // current token loc as tmp_b
                    ig_md.tx_loc_val = tmp_next_loc;
                    do_read_cond_inc_queue_incomplete(ig_md.channel_id); // return tmp_a

                    ig_md.tx_loc_val = ig_md.tmp_b;
                    hdr.payload.data00 = tmp_next_loc;
                    
                    if (ig_md.root_rank_id == 0)      { QUEUE_PTR_INC(queue_head_0); }
                    else if (ig_md.root_rank_id == 1) { QUEUE_PTR_INC(queue_head_1); }
                    else if (ig_md.root_rank_id == 2) { QUEUE_PTR_INC(queue_head_2); }
                    else if (ig_md.root_rank_id == 3) { QUEUE_PTR_INC(queue_head_3); }
                    else if (ig_md.root_rank_id == 4) { QUEUE_PTR_INC(queue_head_4); }
                    else if (ig_md.root_rank_id == 5) { QUEUE_PTR_INC(queue_head_5); }
                    else if (ig_md.root_rank_id == 6) { QUEUE_PTR_INC(queue_head_6); }
                    else if (ig_md.root_rank_id == 7) { QUEUE_PTR_INC(queue_head_7); }
                    
                    ig_tm_md.mcast_grp_b = LOOPBACK_MCAST_GRP;

                    step_write_addr_lo();
                    step_write_addr_hi();
                }
            }

            hdr.bth.psn = ig_md.psn;
            return;
        }
    }
}


/*******************************************************************************
 * CombineEgress - unchanged from previous version
 ******************************************************************************/
control CombineEgress(
    inout a2a_headers_t hdr,
    inout a2a_egress_metadata_t eg_md,
    in egress_intrinsic_metadata_t eg_intr_md,
    inout egress_intrinsic_metadata_for_deparser_t eg_dprsr_md)
{
    
    Register<bit<32>, bit<32>>(COMBINE_BUFFER_ENTRIES) reg_agg;
    
    RegisterAction<bit<32>, bit<32>, void>(reg_agg) ra_store = {
        void apply(inout bit<32> value) { value = eg_md.tmp_b; }
    };

    RegisterAction<bit<32>, bit<32>, void>(reg_agg) ra_aggregate = {
        void apply(inout bit<32> value) { value = value + eg_md.tmp_b; }
    };

    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_agg) ra_read_agg = {
        void apply(inout bit<32> value, out bit<32> res) { res = value; }
    };

    action do_store() { ra_store.execute(eg_md.tmp_a); }
    action do_aggregate() { ra_aggregate.execute(eg_md.tmp_a); }
    action do_read_agg() { eg_md.tmp_b = ra_read_agg.execute(eg_md.tmp_a); }

    action swap_l2_l3_l4() {
        bit<48> tmp_mac = hdr.eth.src_addr;
        hdr.eth.src_addr = hdr.eth.dst_addr;
        hdr.eth.dst_addr = tmp_mac;
        bit<32> tmp_ip = hdr.ipv4.src_addr;
        hdr.ipv4.src_addr = hdr.ipv4.dst_addr;
        hdr.ipv4.dst_addr = tmp_ip;
        bit<16> tmp_port = hdr.udp.src_port;
        hdr.udp.src_port = hdr.udp.dst_port;
        hdr.udp.dst_port = tmp_port;
    }

    action set_ack_len() {
        hdr.udp.length = 28;
        hdr.ipv4.total_len = 48;
        hdr.udp.checksum = 0;
    }

    action set_write_first_len() {
        hdr.udp.length = 8 + 12 + 16 + PAYLOAD_LEN + 4;
        hdr.ipv4.total_len = 20 + 8 + 12 + 16 + PAYLOAD_LEN + 4;
        hdr.udp.checksum = 0;
    }

    action set_write_middle_len() {
        hdr.udp.length = 8 + 12 + PAYLOAD_LEN + 4;
        hdr.ipv4.total_len = 20 + 8 + 12 + PAYLOAD_LEN + 4;
        hdr.udp.checksum = 0;
    }

    action set_rx_info(bit<48> dst_mac, bit<32> dst_ip, bit<32> dst_qp, bit<32> rkey) {
        hdr.eth.dst_addr = dst_mac;
        hdr.ipv4.dst_addr = dst_ip;
        hdr.bth.dst_qp = dst_qp;
        hdr.reth.rkey = rkey;
    }

    table tbl_rx_info {
        key = {
            eg_md.channel_id : exact;
            eg_md.root_rank_id : exact;
        }
        actions = { set_rx_info; NoAction; }
        size = 1024;
        default_action = NoAction;
    }


    action step1_calc_buffer_idx() { eg_md.tmp_a = eg_md.channel_id << 9; }
    action step2_calc_buffer_idx() { eg_md.tmp_b = eg_md.channel_id << 6; }
    action step3_calc_buffer_idx() { eg_md.tmp_a = eg_md.tmp_a - eg_md.tmp_b; } // channel_mul_448 eg_md.tmp_a
    action step4a_set_loc_from_tx_loc() { eg_md.tmp_b = eg_md.tx_loc_val; }
    action step4b_calc_loc_mul_8() { eg_md.tmp_c = eg_md.tmp_b << 3; }
    action step5_calc_loc_mul_7() { eg_md.tmp_c = eg_md.tmp_c - eg_md.tmp_b; } // loc_mul_7 tmp_c
    action step6_calc_buffer_idx() { eg_md.tmp_a = eg_md.tmp_a + eg_md.tmp_c; } // buffer_idx eg_md.tmp_a
    action step7a_set_offset_from_rid() { eg_md.tmp_b = eg_md.egress_rid; }
    action step7a_set_offset_from_eg() { eg_md.tmp_b = eg_md.tx_offset_val; }
    action step7b_add_offset() { eg_md.tmp_a = eg_md.tmp_a + eg_md.tmp_b; } // buffer_idx eg_md.tmp_a

    action step1_calc_psn_add() { eg_md.psn = eg_md.psn + eg_md.egress_rid; } // packet offset eg_md.eg_rank_id
    action step2_write_bth_psn() { hdr.bth.psn = eg_md.psn; }

    apply {
        
        if (eg_intr_md.egress_port == LOOPBACK_PORT) {
            hdr.bth.opcode = RDMA_OP_WRITE_FIRST;
            hdr.reth.setValid();
            hdr.reth.addr = eg_md.next_token_addr;
            hdr.reth.len = TOKEN_SIZE;
            hdr.payload.setValid();
            if (!eg_md.is_loopback) { hdr.payload_first_word.data = eg_md.tx_loc_val; }
            tbl_rx_info.apply();
            set_write_first_len();
            hdr.aeth.setInvalid();
            return;
        }
        
        if (eg_intr_md.egress_port != LOOPBACK_PORT && eg_md.is_loopback) {
            step1_calc_psn_add();
            step2_write_bth_psn();
            
            step1_calc_buffer_idx();
            step2_calc_buffer_idx();
            step3_calc_buffer_idx();
            step4a_set_loc_from_tx_loc();
            step4b_calc_loc_mul_8();
            step5_calc_loc_mul_7();
            step6_calc_buffer_idx();
            step7a_set_offset_from_rid();
            step7b_add_offset();
            
            do_read_agg();
            
            hdr.payload_first_word.setValid();
            hdr.payload_first_word.data = eg_md.tmp_b;
            
            if (eg_md.eg_rank_id == 0) {
                hdr.bth.opcode = RDMA_OP_WRITE_FIRST;
                hdr.reth.setValid();
                hdr.reth.len = TOKEN_SIZE;
                set_write_first_len();
            } else if (eg_md.eg_rank_id == TOKEN_PACKETS - 1) {
                hdr.bth.opcode = RDMA_OP_WRITE_LAST;
                hdr.reth.setInvalid();
                set_write_middle_len();
            } else {
                hdr.bth.opcode = RDMA_OP_WRITE_MIDDLE;
                hdr.reth.setInvalid();
                set_write_middle_len();
            }
            hdr.aeth.setInvalid();
            return;
        }
        
        if (eg_md.conn_semantics == CONN_SEMANTICS.CONN_TX && eg_intr_md.egress_port != LOOPBACK_PORT) {
            step1_calc_buffer_idx();
            step2_calc_buffer_idx();
            step3_calc_buffer_idx();
            step4a_set_loc_from_tx_loc();
            step4b_calc_loc_mul_8();
            step5_calc_loc_mul_7();
            step6_calc_buffer_idx();
            step7a_set_offset_from_eg();
            step7b_add_offset();
        
            eg_md.tmp_b = hdr.payload_first_word.data;

            if (eg_md.agg_op == AGG_OP.STORE) { do_store(); }
            else { do_aggregate(); }
            
            swap_l2_l3_l4();
            set_ack_len();
            hdr.aeth.setValid();
            hdr.bth.opcode = RDMA_OP_ACK;
            hdr.reth.setInvalid();
            hdr.payload.setInvalid();
            return;
        }
        
        if (eg_md.conn_semantics == CONN_SEMANTICS.CONN_CONTROL) {
            hdr.udp.length = 156;
            hdr.ipv4.total_len = 176;
            hdr.udp.checksum = 0;
            swap_l2_l3_l4();
            hdr.reth.setInvalid();
            hdr.payload.setValid();
            hdr.bth.opcode = RDMA_OP_READ_RES_ONLY;
            return;
        }

        if (eg_md.has_aeth) {
            swap_l2_l3_l4();
            set_ack_len();
            hdr.reth.setInvalid();
            hdr.payload.setInvalid();
            hdr.bth.opcode = RDMA_OP_ACK;
            return;
        }
    }
}
