apply {
    
    ig_md.tx_reg_idx = ig_md.ing_rank_id + ig_md.channel_class;

    // ================================================================
    // STAGE 1: PSN Processing
    // ================================================================
    
    // No PSN check needed for CONTROL

    if (ig_md.conn_semantics == CONN_SEMANTICS.CONN_BITMAP) {
        do_read_cond_inc_rx_bitmap_epsn(ig_md.channel_id);
        ig_md.psn_diff = ig_md.psn - ig_md.tmp_a;
        // ig_md.psn_cmp set by comparison
        if(ig_md.psn_cmp == 1) { // psn < epsn
            ig_md.msn = ig_md.tmp_a;
            mul_256();
            set_aeth_syndrome(AETH_NAK_SEQ_ERR);
            set_aeth_msn();
            set_aeth_psn(ig_md.tmp_a - 1);
            ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
            return;
        }
        else if(ig_md.psn_cmp == 2) {
            ig_md.msn = ig_md.tmp_a;
            mul_256();
            set_aeth_syndrome(AETH_ACK_CREDIT_INVALID);
            set_aeth_msn();
            set_aeth_psn(ig_md.tmp_a - 1);
            ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
            return;
        }
    }
    else if (ig_md.conn_semantics == CONN_SEMANTICS.CONN_TX) {
        if (ig_intr_md.ingress_port != LOOPBACK_PORT) {
            do_read_cond_inc_tx_epsn(ig_md.tx_reg_idx);
            // ig_md.psn_cmp set by comparison
    
            if (ig_md.cmp = 1){ // loss data
                do_read_tx_msn(ig_md.tx_reg_idx); //bit<32> current_msn = ig_md.tmp_b;
                ig_md.msn = ig_md.tmp_b;
                mul_256();
                set_aeth_syndrome(AETH_NAK_SEQ_ERR);
                set_aeth_msn();
                set_aeth_psn(ig_md.tmp_a - 1);
                ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
                return;
            }
            else if(ig_md.cmp = 2){ // loss ack
                do_read_tx_msn(ig_md.tx_reg_idx); //bit<32> current_msn = ig_md.tmp_b;
                ig_md.msn = ig_md.tmp_b;
                mul_256();
                set_aeth_syndrome(AETH_ACK_CREDIT_INVALID);
                set_aeth_msn();
                set_aeth_psn(ig_md.tmp_a - 1);
                ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
                return;
            }
            else if(hdr.bth.opcode != RDMA_OP_WRITE_ONLY && hdr.bth.opcode != RDMA_OP_WRITE_LAST){
                    do_read_tx_msn(ig_md.tx_reg_idx); //bit<32> current_msn = ig_md.tmp_b;
                    ig_md.msn = ig_md.tmp_b;
                    mul_256();
                    set_aeth_syndrome(AETH_ACK_CREDIT_INVALID);
                    set_aeth_msn();
                    set_aeth_psn(ig_md.tmp_a);
                    ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
                    return;

            }
            else {
                do_read_inc_tx_msn(ig_md.tx_reg_idx);
                ig_md.msn = ig_md.tmp_b;
                mul_256();
                set_aeth_syndrome(AETH_ACK_CREDIT_INVALID);
                set_aeth_msn();
                set_aeth_psn(ig_md.tmp_a);
                ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
            }
            
        }
        else {
            
            do_read_add_rx_token_epsn(ig_md.channel_id);
            ig_md.psn = ig_md.tmp_a;
            hdr.bth.psn = ig_md.psn;
            ig_md.is_loopback = true;
            ig_tm_md.mcast_grp_a = (bit<16>)ig_md.root_rank_id;
        }
    }

    
    // ================================================================
    // STAGE 2: Token Location/Offset
    // ================================================================
    if (ig_md.conn_semantics == CONN_SEMANTICS.CONN_TX) {
        if(ig_intr_md.ingress_port != LOOPBACK_PORT){
            ig_md.tx_loc_val = hdr.reth.addr[63:32];
            ig_md.tx_offset_val = 0;
            if (hdr.bth.opcode == RDMA_OP_WRITE_FIRST || hdr.bth.opcode == RDMA_OP_WRITE_ONLY) {     
                do_write_tx_loc(ig_md.tx_reg_idx);
                do_reset_tx_offset(ig_md.tx_reg_idx);
            } else {
                do_read_tx_loc(ig_md.tx_reg_idx);
                do_read_inc_tx_offset(ig_md.tx_reg_idx);
            }
        }
        else{
            bit<8> token_loc = (bit<8>)hdr.payload.data00;
            ig_md.tx_loc_val = hdr.payload.data00;
            if (token_loc == 63) { ig_md.tx_offset_val = 0; }
            else { ig_md.tx_offset_val = ig_md.tx_loc_val + 1; } // payload,tx_offset_val, next_loc ,  to save space.
        }
        
    }

    // ================================================================
    // STAGE 3: Queue Tail Operations (MUST be before Token Index for BITMAP)
    // ================================================================
    if (ig_md.conn_semantics == CONN_SEMANTICS.CONN_CONTROL) {
            QUEUE_PTR_READ(queue_tail_0); // queue_tail -> tmp_c
            hdr.payload.data00 = ig_md.tmp_c;
            // QUEUE_PTR_READ(queue_tail_1); // queue_tail -> tmp_c
            // hdr.payload.data01 = ig_md.tmp_c;
            // QUEUE_PTR_READ(queue_tail_2); // queue_tail -> tmp_c
            // hdr.payload.data02 = ig_md.tmp_c;
            // QUEUE_PTR_READ(queue_tail_3); // queue_tail -> tmp_c
            // hdr.payload.data03 = ig_md.tmp_c;
            // QUEUE_PTR_READ(queue_tail_4); // queue_tail -> tmp_c
            // hdr.payload.data04 = ig_md.tmp_c;
            // QUEUE_PTR_READ(queue_tail_5); // queue_tail -> tmp_c
            // hdr.payload.data05 = ig_md.tmp_c;
            // QUEUE_PTR_READ(queue_tail_6); // queue_tail -> tmp_c
            // hdr.payload.data06 = ig_md.tmp_c;
            // QUEUE_PTR_READ(queue_tail_7); // queue_tail -> tmp_c
            // hdr.payload.data07 = ig_md.tmp_c;


    }
    else if (ig_md.conn_semantics == CONN_SEMANTICS.CONN_BITMAP) {
            // Read and increment queue tail, result in tmp_c
            if (ig_md.ing_rank_id == 0) { QUEUE_PTR_READ_ADD(queue_tail_0);  }
            // if (ig_md.ing_rank_id == 1) { QUEUE_PTR_READ_ADD(queue_tail_1);  }
            // if (ig_md.ing_rank_id == 2) { QUEUE_PTR_READ_ADD(queue_tail_2);  }
            // if (ig_md.ing_rank_id == 3) { QUEUE_PTR_READ_ADD(queue_tail_3);  }
            // if (ig_md.ing_rank_id == 4) { QUEUE_PTR_READ_ADD(queue_tail_4);  }
            // if (ig_md.ing_rank_id == 5) { QUEUE_PTR_READ_ADD(queue_tail_5);  }
            // if (ig_md.ing_rank_id == 6) { QUEUE_PTR_READ_ADD(queue_tail_6);  }
            // if (ig_md.ing_rank_id == 7) { QUEUE_PTR_READ_ADD(queue_tail_7);  }
    }
    else if (ig_md.conn_semantics == CONN_SEMANTICS.CONN_TX) {
        if (ig_intr_md.ingress_port == LOOPBACK_PORT) {
            if (ig_md.root_rank_id == 0)      { QUEUE_PTR_READ(queue_tail_0);  }
            // if (ig_md.root_rank_id == 1) { QUEUE_PTR_READ(queue_tail_1);  }
            // if (ig_md.root_rank_id == 2) { QUEUE_PTR_READ(queue_tail_2);  }
            // if (ig_md.root_rank_id == 3) { QUEUE_PTR_READ(queue_tail_3);  }
            // if (ig_md.root_rank_id == 4) { QUEUE_PTR_READ(queue_tail_4);  }
            // if (ig_md.root_rank_id == 5) { QUEUE_PTR_READ(queue_tail_5);  }
            // if (ig_md.root_rank_id == 6) { QUEUE_PTR_READ(queue_tail_6);  }
            // if (ig_md.root_rank_id == 7) { QUEUE_PTR_READ(queue_tail_7);  }
            if (ig_md.tx_offset_val == ig_md.tmp_c) { return; }
        }
    }

    // ================================================================
    // STAGE 4: Token Index Calculation (uses queue_tail from STAGE 3 for BITMAP)
    // ================================================================
    if (ig_md.conn_semantics == CONN_SEMANTICS.CONN_BITMAP) {
        // Uses tmp_c (queue_tail) from STAGE 3
        ig_md.tmp_a = ig_md.channel_id * 64;
        ig_md.tmp_b = ig_md.tmp_c + ig_md.tmp_a; // tmp_b = token_idx
        ig_md.tmp_a = ig_md.tmp_b & 0x7; // tmp_a = slot_id
        ig_md.tmp_b = ig_md.tmp_b >> 3; // tmp_b = slot_index
    }
    else if (ig_md.conn_semantics == CONN_SEMANTICS.CONN_TX) {
        if (ig_intr_md.ingress_port != LOOPBACK_PORT) {
            // Uses tx_loc_val from STAGE 2 (NOT queue_tail)
            ig_md.tmp_a = ig_md.channel_id * 64;
            ig_md.tmp_b = ig_md.tx_loc_val + ig_md.tmp_a; // tmp_b = token_idx
            ig_md.tmp_a = ig_md.tmp_b & 0x7; // tmp_a = slot_id
            ig_md.tmp_b = ig_md.tmp_b >> 3; // tmp_b = slot_index
            tbl_rank_to_clear_mask.apply(); // ig_md.tmp_c clear_mask
        }
        else {
            ig_md.tmp_a = ig_md.channel_id * 64;
            ig_md.tmp_b = ig_md.tmp_a + ig_md.tx_offset_val; // tmp_b = next_token_idx
            ig_md.tmp_a = ig_md.tmp_b & 0x7; // tmp_a = next_slot_id
            ig_md.tmp_b = ig_md.tmp_b >> 3; // tmp_b = next_slot_index
        }
    }

    // ================================================================
    // STAGE 5: Bitmap Operations
    // ================================================================
    if (ig_md.conn_semantics == CONN_SEMANTICS.CONN_BITMAP) {
            ig_md.tmp_c = hdr.payload.data00; 
            BITMAP_WRITE(bitmap_0);
            // ig_md.tmp_c = hdr.payload.data01; 
            // BITMAP_WRITE(bitmap_1);
            // ig_md.tmp_c = hdr.payload.data02; 
            // BITMAP_WRITE(bitmap_2);
            // ig_md.tmp_c = hdr.payload.data03; 
            // BITMAP_WRITE(bitmap_3);
            // ig_md.tmp_c = hdr.payload.data04; 
            // BITMAP_WRITE(bitmap_4);
            // ig_md.tmp_c = hdr.payload.data05; 
            // BITMAP_WRITE(bitmap_5);
            // ig_md.tmp_c = hdr.payload.data06; 
            // BITMAP_WRITE(bitmap_6);
            // ig_md.tmp_c = hdr.payload.data07; 
            // BITMAP_WRITE(bitmap_7);
    }
    else if (ig_md.conn_semantics == CONN_SEMANTICS.CONN_TX) {
        if (ig_intr_md.ingress_port != LOOPBACK_PORT) {
            // BITMAP_CLEAR_BIT based on tmp_a (slot_id)
            if (ig_md.tmp_a == 0)      { BITMAP_CLEAR_BIT(bitmap_0);} // ig_md.tmp_c bitmap_result 
            // if (ig_md.tmp_a == 1) { BITMAP_CLEAR_BIT(bitmap_1); }
            // if (ig_md.tmp_a == 2) { BITMAP_CLEAR_BIT(bitmap_2); }
            // if (ig_md.tmp_a == 3) { BITMAP_CLEAR_BIT(bitmap_3); }
            // if (ig_md.tmp_a == 4) { BITMAP_CLEAR_BIT(bitmap_4); }
            // if (ig_md.tmp_a == 5) { BITMAP_CLEAR_BIT(bitmap_5); }
            // if (ig_md.tmp_a == 6) { BITMAP_CLEAR_BIT(bitmap_6); }
            // else                  { BITMAP_CLEAR_BIT(bitmap_7); }

        }
        else if (ig_intr_md.ingress_port == LOOPBACK_PORT) {
            if (ig_md.tmp_a == 0)      { BITMAP_READ(bitmap_0);} // ig_md.tmp_c bitmap_result 
            // if (ig_md.tmp_a == 1) { BITMAP_READ(bitmap_1); }
            // if (ig_md.tmp_a == 2) { BITMAP_READ(bitmap_2); }
            // if (ig_md.tmp_a == 3) { BITMAP_READ(bitmap_3); }
            // if (ig_md.tmp_a == 4) { BITMAP_READ(bitmap_4); }
            // if (ig_md.tmp_a == 5) { BITMAP_READ(bitmap_5); }
            // if (ig_md.tmp_a == 6) { BITMAP_READ(bitmap_6); }
            // else                  { BITMAP_READ(bitmap_7); }
        }

        if(ig_md.tmp_c != 0) { return; } // token aggregation finished
    }

    // ================================================================
    // STAGE 6: Queue Head / Incomplete Operations
    // ================================================================
    if (ig_md.conn_semantics == CONN_SEMANTICS.CONN_TX) {
        if (ig_intr_md.ingress_port != LOOPBACK_PORT) {
            if (ig_md.ing_rank_id == 0)      { QUEUE_PTR_COND_INC(queue_head_0); }
            // if (ig_md.ing_rank_id == 1) { QUEUE_PTR_COND_INC(queue_head_1); }
            // if (ig_md.ing_rank_id == 2) { QUEUE_PTR_COND_INC(queue_head_2); }
            // if (ig_md.ing_rank_id == 3) { QUEUE_PTR_COND_INC(queue_head_3); }
            // if (ig_md.ing_rank_id == 4) { QUEUE_PTR_COND_INC(queue_head_4); }
            // if (ig_md.ing_rank_id == 5) { QUEUE_PTR_COND_INC(queue_head_5); }
            // if (ig_md.ing_rank_id == 6) { QUEUE_PTR_COND_INC(queue_head_6); }
            // if (ig_md.ing_rank_id == 7) { QUEUE_PTR_COND_INC(queue_head_7); }

            if(ig_md.tmp_c != ig_md.tx_loc_val) { return; }
            else { ig_tm_md.mcast_grp_b = LOOPBACK_MCAST_GRP; }

        }

        else {
            
            if (ig_md.root_rank_id == 0)    { QUEUE_PTR_INC(queue_head_0); }
            // if (ig_md.root_rank_id == 1) { QUEUE_PTR_INC(queue_head_1); }
            // if (ig_md.root_rank_id == 2) { QUEUE_PTR_INC(queue_head_2); }
            // if (ig_md.root_rank_id == 3) { QUEUE_PTR_INC(queue_head_3); }
            // if (ig_md.root_rank_id == 4) { QUEUE_PTR_INC(queue_head_4); }
            // if (ig_md.root_rank_id == 5) { QUEUE_PTR_INC(queue_head_5); }
            // if (ig_md.root_rank_id == 6) { QUEUE_PTR_INC(queue_head_6); }
            // if (ig_md.root_rank_id == 7) { QUEUE_PTR_INC(queue_head_7); }
            
            hdr.payload.data00 = ig_md.tx_offset_val;
            ig_tm_md.mcast_grp_b = LOOPBACK_MCAST_GRP;
            
        }
    }

    // ================================================================
    // STAGE 7: Address Operations
    // ================================================================
    if (ig_md.conn_semantics == CONN_SEMANTICS.CONN_BITMAP) {
        // ADDR_WRITE based on slot
        ig_md.tmp_d = hdr.payload.data08;
        ig_md.tmp_e = hdr.payload.data09;
        ADDR_WRITE(addr_0);
        // ... addr_1..7
    }
    else if (ig_md.conn_semantics == CONN_SEMANTICS.CONN_TX) {
        if (ig_md.tmp_a == 0)    { ADDR_READ(bitmap_0);} // ig_md.tmp_d, ig_md.tmp_e
        // if (ig_md.tmp_a == 1) { ADDR_READ(bitmap_1); }
        // if (ig_md.tmp_a == 2) { ADDR_READ(bitmap_2); }
        // if (ig_md.tmp_a == 3) { ADDR_READ(bitmap_3); }
        // if (ig_md.tmp_a == 4) { ADDR_READ(bitmap_4); }
        // if (ig_md.tmp_a == 5) { ADDR_READ(bitmap_5); }
        // if (ig_md.tmp_a == 6) { ADDR_READ(bitmap_6); }
        // else                  { ADDR_READ(bitmap_7); }

        ig_md.next_token_addr[31:0] = ig_md.tmp_d;
        ig_md.next_token_addr[63:32] = ig_md.tmp_e;
    }

}


apply {

        //step1_cal_tx_reg_idx();
        //step2_cal_tx_reg_idx();

        ig_md.tx_reg_idx = ig_md.ing_rank_id + ig_md.channel_class;
        // ================================================================
        // CONN_CONTROL: query queue pointer (READ)
        // ================================================================
        if (ig_md.conn_semantics == CONN_SEMANTICS.CONN_CONTROL) {
            if (hdr.bth.opcode == RDMA_OP_READ_REQ) {
                QUEUE_PTR_READ(queue_head_0); ig_md.tmp_a = ig_md.tmp_c; // queue_head ig_md.tmp_a
                QUEUE_PTR_READ(queue_tail_0); 
                step1_calc_shift_head(); step2_calc_combine_tail(); step3_write_payload_data_0();

                // QUEUE_PTR_READ(queue_head_1); ig_md.tmp_a = ig_md.tmp_c;
                // QUEUE_PTR_READ(queue_tail_1); 
                // //step1_calc_shift_head(); step2_calc_combine_tail(); step3_write_payload_data_1();

                // QUEUE_PTR_READ(queue_head_2); ig_md.tmp_a = ig_md.tmp_c;
                // QUEUE_PTR_READ(queue_tail_2); 
                // //step1_calc_shift_head(); step2_calc_combine_tail(); step3_write_payload_data_2();

                // QUEUE_PTR_READ(queue_head_3); ig_md.tmp_a = ig_md.tmp_c;
                // QUEUE_PTR_READ(queue_tail_3); 
                // //step1_calc_shift_head(); step2_calc_combine_tail(); step3_write_payload_data_3();

                // QUEUE_PTR_READ(queue_head_4); ig_md.tmp_a = ig_md.tmp_c;
                // QUEUE_PTR_READ(queue_tail_4); 
                // //step1_calc_shift_head(); step2_calc_combine_tail(); step3_write_payload_data_4();

                // QUEUE_PTR_READ(queue_head_5); ig_md.tmp_a = ig_md.tmp_c;
                // QUEUE_PTR_READ(queue_tail_5); 
                // //step1_calc_shift_head(); step2_calc_combine_tail(); step3_write_payload_data_5();

                // QUEUE_PTR_READ(queue_head_6); ig_md.tmp_a = ig_md.tmp_c;
                // QUEUE_PTR_READ(queue_tail_6); 
                // //step1_calc_shift_head(); step2_calc_combine_tail(); step3_write_payload_data_6();

                // QUEUE_PTR_READ(queue_head_7); ig_md.tmp_a = ig_md.tmp_c;
                // QUEUE_PTR_READ(queue_tail_7); 
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
        else if (ig_md.conn_semantics == CONN_SEMANTICS.CONN_BITMAP) {
            if (hdr.bth.opcode != RDMA_OP_WRITE_ONLY) {
                ig_dprsr_md.drop_ctl = 1;
                return;
            }

            do_read_cond_inc_rx_bitmap_epsn(ig_md.channel_id);
            // bit<32> expected_psn = ig_md.tmp_a;
            
            ig_md.diff = ig_md.psn - ig_md.tmp_a;

            //tbl_compare_a.apply();

            if (ig_md.cmp == 0) {
                //if (ig_md.ing_rank_id == 0) { QUEUE_PTR_READ_ADD(queue_tail_0);  }
                // else if (ig_md.ing_rank_id == 1) { QUEUE_PTR_READ_ADD(queue_tail_1);  }
                // else if (ig_md.ing_rank_id == 2) { QUEUE_PTR_READ_ADD(queue_tail_2);  }
                // else if (ig_md.ing_rank_id == 3) { QUEUE_PTR_READ_ADD(queue_tail_3);  }
                // else if (ig_md.ing_rank_id == 4) { QUEUE_PTR_READ_ADD(queue_tail_4);  }
                // else if (ig_md.ing_rank_id == 5) { QUEUE_PTR_READ_ADD(queue_tail_5);  }
                // else if (ig_md.ing_rank_id == 6) { QUEUE_PTR_READ_ADD(queue_tail_6);  }
                // else if (ig_md.ing_rank_id == 7) { QUEUE_PTR_READ_ADD(queue_tail_7);  } // ig_md.queue_tail = ig_md.tmp_c;

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
        else if (ig_md.conn_semantics == CONN_SEMANTICS.CONN_TX) {
            if (hdr.bth.opcode != RDMA_OP_WRITE_FIRST && 
                hdr.bth.opcode != RDMA_OP_WRITE_MIDDLE &&
                hdr.bth.opcode != RDMA_OP_WRITE_LAST &&
                hdr.bth.opcode != RDMA_OP_WRITE_ONLY) {
                ig_dprsr_md.drop_ctl = 1;
                return;
            }

            if(ig_intr_md.ingress_port != LOOPBACK_PORT){
                //tbl_compare_a.apply();
                //ig_md.psn_to_read = ig_md.psn; 
                do_read_cond_inc_tx_epsn(ig_md.tx_reg_idx); //bit<32> expected_psn = ig_md.tmp_a;

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
                    
                    step1_calc_token_idx_from_tx_loc();
                    step2_calc_token_idx_from_tx_loc();
                    step3_calc_token_idx_from_tx_loc(); // ig_md.tmp_b token_idx
                    do_read_set_clear(); // ig_md.tmp_a
                    // ig_md.clear_offset = ig_md.tmp_a;

                    ig_md.diff = ig_md.tmp_a - ig_md.tx_offset_val;

                    //tbl_compare_b.apply();

                    if(ig_md.cmp == 1){
                        ig_md.agg_op = AGG_OP.AGGREGATE; // 不好，应该是都是+，发的时候要清空聚合器。
                    }
                    else{
                        ig_md.agg_op = AGG_OP.STORE;
                    }
                    
                    if (hdr.bth.opcode == RDMA_OP_WRITE_ONLY || hdr.bth.opcode == RDMA_OP_WRITE_LAST) {
                        calc_slot_index_from_token_idx(); // ig_md.tmp_b slot_index 
                        calc_slot_id_from_token_idx(); // ig_md.tmp_a slot_id
                        tbl_rank_to_clear_mask.apply(); // ig_md.tmp_c clear_mask
                        
                        //if (ig_md.tmp_a == 0)      { BITMAP_CLEAR_BIT(bitmap_0); ADDR_READ(addr_0); } // ig_md.tmp_c bitmap_result ig_md.tmp_d, ig_md.tmp_e
                        // else if (ig_md.tmp_a == 1) { BITMAP_CLEAR_BIT(bitmap_1); ADDR_READ(addr_1); }
                        // else if (ig_md.tmp_a == 2) { BITMAP_CLEAR_BIT(bitmap_2); ADDR_READ(addr_2); }
                        // else if (ig_md.tmp_a == 3) { BITMAP_CLEAR_BIT(bitmap_3); ADDR_READ(addr_3); }
                        // else if (ig_md.tmp_a == 4) { BITMAP_CLEAR_BIT(bitmap_4); ADDR_READ(addr_4); }
                        // else if (ig_md.tmp_a == 5) { BITMAP_CLEAR_BIT(bitmap_5); ADDR_READ(addr_5); }
                        // else if (ig_md.tmp_a == 6) { BITMAP_CLEAR_BIT(bitmap_6); ADDR_READ(addr_6); }
                        // else                   { BITMAP_CLEAR_BIT(bitmap_7); ADDR_READ(addr_7); }

                        //do_read_inc_tx_msn(ig_md.tx_reg_idx);
                        //ig_md.tmp_b = ra_read_inc_tx_msn.execute(ig_md.tx_reg_idx);

                        if (ig_md.tmp_c == 0) { // token全部聚合完成
                            do_read_cond_inc_queue_incomplete(ig_md.channel_id); 
                            // queue_incomplete = ig_md.tmp_a;
                            if (ig_md.tmp_a == ig_md.tx_loc_val) { // 下一个要发的就是我们当前处理的token
                                //if (ig_md.ing_rank_id == 0)      { QUEUE_PTR_INC(queue_head_0); }
                                // else if (ig_md.ing_rank_id == 1) { QUEUE_PTR_INC(queue_head_1); }
                                // else if (ig_md.ing_rank_id == 2) { QUEUE_PTR_INC(queue_head_2); }
                                // else if (ig_md.ing_rank_id == 3) { QUEUE_PTR_INC(queue_head_3); }
                                // else if (ig_md.ing_rank_id == 4) { QUEUE_PTR_INC(queue_head_4); }
                                // else if (ig_md.ing_rank_id == 5) { QUEUE_PTR_INC(queue_head_5); }
                                // else if (ig_md.ing_rank_id == 6) { QUEUE_PTR_INC(queue_head_6); }
                                // else if (ig_md.ing_rank_id == 7) { QUEUE_PTR_INC(queue_head_7); }
                                
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
                    //do_read_tx_msn(ig_md.tx_reg_idx); //bit<32> current_msn = ig_md.tmp_b;
                    //ig_md.tmp_b = ra_read_tx_msn.execute(ig_md.tx_reg_idx);
                    ig_md.msn = ig_md.tmp_b;
                    mul_256();
                    set_aeth_syndrome(AETH_ACK_CREDIT_INVALID);
                    set_aeth_msn();
                    set_aeth_psn(ig_md.tmp_a - 1);
                    ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
                } else {
                    //do_read_tx_msn(ig_md.tx_reg_idx); //bit<32> current_msn = ig_md.tmp_b;
                    //ig_md.tmp_b = ra_read_tx_msn.execute(ig_md.tx_reg_idx);
                    ig_md.msn = ig_md.tmp_b;
                    mul_256();
                    set_aeth_syndrome(AETH_NAK_SEQ_ERR);
                    set_aeth_msn();
                    set_aeth_psn(ig_md.tmp_a - 1);
                    ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
                }
                return;
            }
            else{
                // ================================================================
                // Loopback port processing
                // ================================================================
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
                
                //if (ig_md.root_rank_id == 0)      { QUEUE_PTR_READ(queue_tail_0);  }
                // else if (ig_md.root_rank_id == 1) { QUEUE_PTR_READ(queue_tail_1);  }
                // else if (ig_md.root_rank_id == 2) { QUEUE_PTR_READ(queue_tail_2);  }
                // else if (ig_md.root_rank_id == 3) { QUEUE_PTR_READ(queue_tail_3);  }
                // else if (ig_md.root_rank_id == 4) { QUEUE_PTR_READ(queue_tail_4);  }
                // else if (ig_md.root_rank_id == 5) { QUEUE_PTR_READ(queue_tail_5);  }
                // else if (ig_md.root_rank_id == 6) { QUEUE_PTR_READ(queue_tail_6);  }
                // else if (ig_md.root_rank_id == 7) { QUEUE_PTR_READ(queue_tail_7);  } // ig_md.queue_tail = ig_md.tmp_c;
                
                if (ig_md.tmp_b != ig_md.tmp_c) { // 下一个token的loc不是tail
                    step1_calc_next_token_idx_from_next_loc();
                    step2_calc_next_token_idx_from_next_loc(); // tmp_b next_token_idx
                    calc_slot_index_from_next_token(); // tmp_b slot_index
                    calc_slot_id_from_next_token_idx(); // tmp_a next_slot_id

                    //if (ig_md.tmp_a == 0)      { BITMAP_READ(bitmap_0); ADDR_READ(addr_0); } // next_bitmap_result as ig_md.bitmap_result as ig_md.tmp_c 
                    // else if (ig_md.tmp_a == 1) { BITMAP_READ(bitmap_1);  ADDR_READ(addr_1); }
                    // else if (ig_md.tmp_a == 2) { BITMAP_READ(bitmap_2);  ADDR_READ(addr_2); }
                    // else if (ig_md.tmp_a == 3) { BITMAP_READ(bitmap_3);  ADDR_READ(addr_3); }
                    // else if (ig_md.tmp_a == 4) { BITMAP_READ(bitmap_4);  ADDR_READ(addr_4); }
                    // else if (ig_md.tmp_a == 5) { BITMAP_READ(bitmap_5);  ADDR_READ(addr_5); }
                    // else if (ig_md.tmp_a == 6) { BITMAP_READ(bitmap_6);  ADDR_READ(addr_6); }
                    // else                        { BITMAP_READ(bitmap_7);  ADDR_READ(addr_7); }
                    
                    if (ig_md.tmp_c == 0) {
                        ig_md.tmp_b = ig_md.tx_loc_val; // current token loc as tmp_b
                        ig_md.tx_loc_val = tmp_next_loc;
                        do_read_cond_inc_queue_incomplete(ig_md.channel_id); // return tmp_a

                        ig_md.tx_loc_val = ig_md.tmp_b;
                        hdr.payload.data00 = tmp_next_loc;
                        
                        //if (ig_md.root_rank_id == 0)      { QUEUE_PTR_INC(queue_head_0); }
                        // else if (ig_md.root_rank_id == 1) { QUEUE_PTR_INC(queue_head_1); }
                        // else if (ig_md.root_rank_id == 2) { QUEUE_PTR_INC(queue_head_2); }
                        // else if (ig_md.root_rank_id == 3) { QUEUE_PTR_INC(queue_head_3); }
                        // else if (ig_md.root_rank_id == 4) { QUEUE_PTR_INC(queue_head_4); }
                        // else if (ig_md.root_rank_id == 5) { QUEUE_PTR_INC(queue_head_5); }
                        // else if (ig_md.root_rank_id == 6) { QUEUE_PTR_INC(queue_head_6); }
                        // else if (ig_md.root_rank_id == 7) { QUEUE_PTR_INC(queue_head_7); }
                        
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