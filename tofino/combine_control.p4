/**
 * @file combine_control.p4
 * @brief Combine phase control logic for A2A communication
 *
 * Implements the gather/combine phase of All-to-All collective with
 * in-network aggregation. Uses macros for register management to avoid
 * variable duplication issues in the Tofino compiler.
 */

#include "combine_macros.p4"

/* =============================================================================
 * Configuration Constants
 * ============================================================================= */

#define NUM_COMBINE_CHANNELS_PER_RX 8
#define COMBINE_QUEUE_LENGTH        64
#define TOKEN_SIZE                  7168
#define PAYLOAD_LEN                 1024
#define TOKEN_PACKETS               (TOKEN_SIZE / PAYLOAD_LEN)
#define N_AGG_SLOTS                 32
#define BYTES_PER_SLOT              4
#define BITMAP_PER_PACKET           8

/* Derived constants */
#define COMBINE_CHANNELS_TOTAL          (EP_SIZE * NUM_COMBINE_CHANNELS_PER_RX)
#define PACKET_NUM_PER_CHANNEL_BUFFER   (COMBINE_QUEUE_LENGTH * TOKEN_PACKETS)
#define COMBINE_BUFFER_ENTRIES          (COMBINE_CHANNELS_TOTAL * PACKET_NUM_PER_CHANNEL_BUFFER)
#define COMBINE_TX_ENTRIES              (COMBINE_CHANNELS_TOTAL * EP_SIZE)
#define COMBINE_BITMAP_ENTRIES          (COMBINE_CHANNELS_TOTAL * COMBINE_QUEUE_LENGTH)


/* =============================================================================
 * Combine Ingress Control
 *
 * Handles incoming data for aggregation:
 *   - TX data: tracks PSN/MSN, stores token location
 *   - Bitmap updates: manages completion tracking
 *   - Loopback: handles aggregated data distribution
 *   - Control: provides queue state information
 * ============================================================================= */

control CombineIngress(
    inout a2a_headers_t                         hdr,
    inout a2a_ingress_metadata_t                ig_md,
    in    ingress_intrinsic_metadata_t          ig_intr_md,
    inout ingress_intrinsic_metadata_for_deparser_t ig_dprsr_md,
    inout ingress_intrinsic_metadata_for_tm_t   ig_tm_md)
{
    /* =========================================================================
     * TX State Registers
     * ========================================================================= */

    Register<bit<32>, bit<32>>(COMBINE_TX_ENTRIES, 0) reg_tx_epsn;
    Register<bit<32>, bit<32>>(COMBINE_TX_ENTRIES)    reg_tx_msn;
    Register<bit<32>, bit<32>>(COMBINE_TX_ENTRIES)    reg_tx_loc;
    Register<bit<32>, bit<32>>(COMBINE_TX_ENTRIES)    reg_tx_packet_offset;

    /* TX EPSN: conditional increment on PSN match */
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

    /* TX MSN: read and read-increment operations */
    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_tx_msn) ra_read_tx_msn = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
        }
    };

    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_tx_msn) ra_read_inc_tx_msn = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
            value = value + 1;
        }
    };

    RegisterAction<bit<32>, bit<32>, void>(reg_tx_msn) ra_init_tx_msn = {
        void apply(inout bit<32> value) {
            value = 0;
        }
    };

    /* TX location: current token queue position */
    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_tx_loc) ra_read_tx_loc = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
        }
    };

    RegisterAction<bit<32>, bit<32>, void>(reg_tx_loc) ra_write_tx_loc = {
        void apply(inout bit<32> value) {
            value = ig_md.tx_loc_val;
        }
    };

    /* TX packet offset: tracks position within token */
    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_tx_packet_offset) ra_read_inc_tx_offset = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
            value = value + 1;
        }
    };

    RegisterAction<bit<32>, bit<32>, void>(reg_tx_packet_offset) ra_reset_tx_offset = {
        void apply(inout bit<32> value) {
            value = 1;
        }
    };

    /* TX register access actions */
    action do_read_cond_inc_tx_epsn(bit<32> idx) { ig_md.tmp_a = ra_read_cond_inc_tx_epsn.execute(idx); }
    action do_init_tx_epsn(bit<32> idx)          { ra_init_tx_epsn.execute(idx); }
    action do_read_tx_msn(bit<32> idx)           { ig_md.tmp_b = ra_read_tx_msn.execute(idx); }
    action do_read_inc_tx_msn(bit<32> idx)       { ig_md.tmp_b = ra_read_inc_tx_msn.execute(idx); }
    action do_init_tx_msn(bit<32> idx)           { ra_init_tx_msn.execute(idx); }
    action do_read_tx_loc(bit<32> idx)           { ig_md.tx_loc_val = ra_read_tx_loc.execute(idx); }
    action do_write_tx_loc(bit<32> idx)          { ra_write_tx_loc.execute(idx); }
    action do_read_inc_tx_offset(bit<32> idx)    { ig_md.tx_offset_val = ra_read_inc_tx_offset.execute(idx); }
    action do_reset_tx_offset(bit<32> idx)       { ra_reset_tx_offset.execute(idx); }

    /* =========================================================================
     * RX State Registers
     * ========================================================================= */

    Register<bit<32>, bit<32>>(COMBINE_CHANNELS_TOTAL, 0) reg_rx_bitmap_epsn;
    Register<bit<32>, bit<32>>(COMBINE_CHANNELS_TOTAL, 0) reg_rx_token_epsn;
    Register<bit<32>, bit<32>>(COMBINE_CHANNELS_TOTAL, 0) reg_rx_token_msn;

    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_rx_bitmap_epsn) ra_read_rx_bitmap_epsn = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
        }
    };

    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_rx_bitmap_epsn) ra_read_cond_inc_rx_bitmap_epsn = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
            if (ig_md.psn == value) {
                value = value + 1;
            }
        }
    };

    RegisterAction<bit<32>, bit<32>, void>(reg_rx_bitmap_epsn) ra_init_rx_bitmap_epsn = {
        void apply(inout bit<32> value) {
            value = 0;
        }
    };

    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_rx_token_epsn) ra_read_rx_token_epsn = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
        }
    };

    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_rx_token_epsn) ra_read_add_rx_token_epsn = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
            value = value + TOKEN_PACKETS;
        }
    };

    RegisterAction<bit<32>, bit<32>, void>(reg_rx_token_epsn) ra_init_rx_token_epsn = {
        void apply(inout bit<32> value) {
            value = 0;
        }
    };

    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_rx_token_msn) ra_read_inc_rx_token_msn = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
            value = value + 1;
        }
    };

    /* RX register access actions */
    action do_read_cond_inc_rx_bitmap_epsn(bit<32> idx) { ig_md.tmp_a = ra_read_cond_inc_rx_bitmap_epsn.execute(idx); }
    action do_read_rx_token_epsn(bit<32> idx)          { ig_md.tmp_a = ra_read_rx_token_epsn.execute(idx); }
    action do_read_add_rx_token_epsn(bit<32> idx)      { ig_md.tmp_a = ra_read_add_rx_token_epsn.execute(idx); }
    action do_init_rx_token_epsn(bit<32> idx)          { ra_init_rx_token_epsn.execute(idx); }
    action do_read_inc_rx_token_msn(bit<32> idx)       { ig_md.tmp_a = ra_read_inc_rx_token_msn.execute(idx); }

    /* =========================================================================
     * Queue Pointer Slots (8 instances for head and tail)
     * ========================================================================= */

    QUEUE_PTR_SLOT_DECLARE(queue_head_0)
    QUEUE_PTR_SLOT_DECLARE(queue_head_1)
    QUEUE_PTR_SLOT_DECLARE(queue_head_2)
    QUEUE_PTR_SLOT_DECLARE(queue_head_3)
    QUEUE_PTR_SLOT_DECLARE(queue_head_4)
    QUEUE_PTR_SLOT_DECLARE(queue_head_5)
    QUEUE_PTR_SLOT_DECLARE(queue_head_6)
    QUEUE_PTR_SLOT_DECLARE(queue_head_7)

    QUEUE_PTR_SLOT_DECLARE(queue_tail_0)
    QUEUE_PTR_SLOT_DECLARE(queue_tail_1)
    QUEUE_PTR_SLOT_DECLARE(queue_tail_2)
    QUEUE_PTR_SLOT_DECLARE(queue_tail_3)
    QUEUE_PTR_SLOT_DECLARE(queue_tail_4)
    QUEUE_PTR_SLOT_DECLARE(queue_tail_5)
    QUEUE_PTR_SLOT_DECLARE(queue_tail_6)
    QUEUE_PTR_SLOT_DECLARE(queue_tail_7)

    /* =========================================================================
     * Queue Incomplete Register
     * ========================================================================= */

    Register<bit<32>, bit<32>>(COMBINE_CHANNELS_TOTAL) reg_queue_incomplete;

    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_queue_incomplete) ra_read_queue_incomplete = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
        }
    };

    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_queue_incomplete) ra_read_cond_inc_queue_incomplete = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
            if (value == ig_md.tx_loc_val) {
                if (value >= COMBINE_QUEUE_LENGTH - 1) {
                    value = 0;
                } else {
                    value = value + 1;
                }
            }
        }
    };

    RegisterAction<bit<32>, bit<32>, void>(reg_queue_incomplete) ra_init_queue_incomplete = {
        void apply(inout bit<32> value) {
            value = 0;
        }
    };

    action do_read_cond_inc_queue_incomplete(bit<32> idx) {
        ig_md.tmp_a = ra_read_cond_inc_queue_incomplete.execute(idx);
    }

    action do_init_queue_incomplete(bit<32> idx) {
        ra_init_queue_incomplete.execute(idx);
    }

    /* =========================================================================
     * Bitmap Slots (8 instances)
     * ========================================================================= */

    BITMAP_SLOT_DECLARE(bitmap_0)
    BITMAP_SLOT_DECLARE(bitmap_1)
    BITMAP_SLOT_DECLARE(bitmap_2)
    BITMAP_SLOT_DECLARE(bitmap_3)
    BITMAP_SLOT_DECLARE(bitmap_4)
    BITMAP_SLOT_DECLARE(bitmap_5)
    BITMAP_SLOT_DECLARE(bitmap_6)
    BITMAP_SLOT_DECLARE(bitmap_7)

    /* =========================================================================
     * Address Slots (8 instances)
     * ========================================================================= */

    ADDR_SLOT_DECLARE(addr_0)
    ADDR_SLOT_DECLARE(addr_1)
    ADDR_SLOT_DECLARE(addr_2)
    ADDR_SLOT_DECLARE(addr_3)
    ADDR_SLOT_DECLARE(addr_4)
    ADDR_SLOT_DECLARE(addr_5)
    ADDR_SLOT_DECLARE(addr_6)
    ADDR_SLOT_DECLARE(addr_7)

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

    action swap_l2_l3_l4() {
        bit<48> tmp_mac  = hdr.eth.src_addr;
        hdr.eth.src_addr = hdr.eth.dst_addr;
        hdr.eth.dst_addr = tmp_mac;

        bit<32> tmp_ip    = hdr.ipv4.src_addr;
        hdr.ipv4.src_addr = hdr.ipv4.dst_addr;
        hdr.ipv4.dst_addr = tmp_ip;

        bit<16> tmp_port = hdr.udp.src_port;
        hdr.udp.src_port = hdr.udp.dst_port;
        hdr.udp.dst_port = tmp_port;
    }

    action set_ack_len() {
        hdr.udp.length     = 28;
        hdr.ipv4.total_len = 48;
        hdr.udp.checksum   = 0;
    }

    /* =========================================================================
     * Bitmap Clear Mask Table
     * ========================================================================= */

    action set_bitmap_clear_mask(bitmap_tofino_t m) {
        ig_md.tmp_c = m;
    }

    table tbl_rank_to_clear_mask {
        key = {
            ig_md.ing_rank_id: exact;
        }
        actions = {
            set_bitmap_clear_mask;
        }
        size = 8;
        default_action = set_bitmap_clear_mask((bitmap_tofino_t)0);
        const entries = {
            0: set_bitmap_clear_mask((bitmap_tofino_t)8w0x01);
            1: set_bitmap_clear_mask((bitmap_tofino_t)8w0x02);
            2: set_bitmap_clear_mask((bitmap_tofino_t)8w0x04);
            3: set_bitmap_clear_mask((bitmap_tofino_t)8w0x08);
            4: set_bitmap_clear_mask((bitmap_tofino_t)8w0x10);
            5: set_bitmap_clear_mask((bitmap_tofino_t)8w0x20);
            6: set_bitmap_clear_mask((bitmap_tofino_t)8w0x40);
            7: set_bitmap_clear_mask((bitmap_tofino_t)8w0x80);
        }
    }

    /* =========================================================================
     * PSN Comparison Table
     * ========================================================================= */

    action set_cmp(bit<8> cmp) {
        ig_md.psn_cmp = cmp;
    }

    table tbl_compare_psn {
        key = {
            ig_md.psn_diff: ternary;
        }
        actions = {
            set_cmp;
        }
    }

    /* =========================================================================
     * Slot Calculation Table
     * ========================================================================= */

    action cal_slot(bit<32> slot_id, bit<32> slot_index) {
        ig_md.tmp_a = slot_id;
        ig_md.tmp_b = slot_index;
    }

    table tbl_cal_slot {
        key = {
            ig_md.tmp_c    : exact;
            ig_md.channel_id: exact;
        }
        actions = {
            cal_slot;
        }
        size = 128;
    }

    /* =========================================================================
     * Index Calculation Actions
     * ========================================================================= */

    action step1_calc_token_idx_from_tail()      { ig_md.tmp_a = ig_md.channel_id * 64; }
    action step2_calc_token_idx_from_tail()      { ig_md.tmp_b = ig_md.tmp_c; }
    action step3_calc_token_idx_from_tail()      { ig_md.tmp_b = ig_md.tmp_b + ig_md.tmp_a; }

    action calc_slot_index_from_token_idx()      { ig_md.tmp_b = ig_md.tmp_b >> 3; }
    action calc_slot_id_from_token_idx()         { ig_md.tmp_a = ig_md.tmp_b & 0x7; }

    action calc_slot_index_from_next_token_idx() { ig_md.tmp_b = ig_md.tmp_b >> 3; }
    action calc_slot_id_from_next_token_idx()    { ig_md.tmp_a = ig_md.tmp_b & 0x7; }

    action step1_calc_token_idx_from_tx_loc()    { ig_md.tmp_a = ig_md.channel_id * 64; }
    action step2_calc_token_idx_from_tx_loc()    { ig_md.tmp_b = ig_md.tx_loc_val; }
    action step3_calc_token_idx_from_tx_loc()    { ig_md.tmp_b = ig_md.tmp_b + ig_md.tmp_a; }

    action step1_calc_next_token_idx()           { ig_md.tmp_a = ig_md.channel_id * 64; }
    action step2_calc_next_token_idx()           { ig_md.tmp_b = ig_md.tx_offset_val; }
    action step3_calc_next_token_idx()           { ig_md.tmp_b = ig_md.tmp_b + ig_md.tmp_a; }

    /* =========================================================================
     * Apply Block
     * ========================================================================= */

    apply {
        /* ---------------------------------------------------------------------
         * Phase 1: Handle connection-specific PSN tracking
         * --------------------------------------------------------------------- */
        if (ig_md.conn_semantics == CONN_SEMANTICS.CONN_BITMAP) {
            do_read_cond_inc_rx_bitmap_epsn(ig_md.channel_id);
        }
        else if (ig_md.conn_semantics == CONN_SEMANTICS.CONN_TX) {
            do_read_cond_inc_tx_epsn(ig_md.tx_reg_idx);
            do_read_inc_tx_msn(ig_md.tx_reg_idx);
            ig_md.msn = ig_md.tmp_b;

            /* Only process WRITE_LAST packets for token completion */
            if (hdr.bth.opcode != RDMA_OP_WRITE_LAST) {
                return;
            }

            ig_md.tx_loc_val    = hdr.reth.addr[63:32];
            ig_md.tx_offset_val = 0;

            /* Handle first/only vs middle/last packets */
            if (hdr.bth.opcode == RDMA_OP_WRITE_FIRST ||
                hdr.bth.opcode == RDMA_OP_WRITE_ONLY) {
                do_write_tx_loc(ig_md.tx_reg_idx);
                do_reset_tx_offset(ig_md.tx_reg_idx);
            } else {
                do_read_tx_loc(ig_md.tx_reg_idx);
                do_read_inc_tx_offset(ig_md.tx_reg_idx);
            }
        }
        else if (ig_md.conn_semantics == CONN_SEMANTICS.CONN_LOOPBACK) {
            /* Prepare for loopback distribution */
            do_read_add_rx_token_epsn(ig_md.channel_id);
            ig_md.psn       = ig_md.tmp_a;
            hdr.bth.psn     = ig_md.psn;
            ig_md.is_loopback = true;
            ig_tm_md.mcast_grp_a = (bit<16>)ig_md.root_rank_id;
            ig_md.tx_loc_val = hdr.payload.data00;

            /* Calculate next location with wraparound */
            if (ig_md.tx_loc_val == 63) {
                ig_md.tx_offset_val = 0;
            } else {
                ig_md.tx_offset_val = ig_md.tx_loc_val + 1;
            }
        }

        /* ---------------------------------------------------------------------
         * Phase 2: Connection-specific processing
         * --------------------------------------------------------------------- */
        if (ig_md.conn_semantics == CONN_SEMANTICS.CONN_CONTROL) {
            /* Read all queue tails and populate response payload */
            QUEUE_PTR_READ(queue_tail_0);
            hdr.payload.data00 = ig_md.tmp_c;
            QUEUE_PTR_READ(queue_tail_1);
            hdr.payload.data01 = ig_md.tmp_c;
            QUEUE_PTR_READ(queue_tail_2);
            hdr.payload.data02 = ig_md.tmp_c;
            QUEUE_PTR_READ(queue_tail_3);
            hdr.payload.data03 = ig_md.tmp_c;
            QUEUE_PTR_READ(queue_tail_4);
            hdr.payload.data04 = ig_md.tmp_c;
            QUEUE_PTR_READ(queue_tail_5);
            hdr.payload.data05 = ig_md.tmp_c;
            QUEUE_PTR_READ(queue_tail_6);
            hdr.payload.data06 = ig_md.tmp_c;
            QUEUE_PTR_READ(queue_tail_7);
            hdr.payload.data07 = ig_md.tmp_c;
        }
        else if (ig_md.conn_semantics == CONN_SEMANTICS.CONN_BITMAP) {
            /* Read and increment queue tail for this rank */
            if (ig_md.ing_rank_id == 0) { QUEUE_PTR_READ_ADD(queue_tail_0); }
            if (ig_md.ing_rank_id == 1) { QUEUE_PTR_READ_ADD(queue_tail_1); }
            if (ig_md.ing_rank_id == 2) { QUEUE_PTR_READ_ADD(queue_tail_2); }
            if (ig_md.ing_rank_id == 3) { QUEUE_PTR_READ_ADD(queue_tail_3); }
            if (ig_md.ing_rank_id == 4) { QUEUE_PTR_READ_ADD(queue_tail_4); }
            if (ig_md.ing_rank_id == 5) { QUEUE_PTR_READ_ADD(queue_tail_5); }
            if (ig_md.ing_rank_id == 6) { QUEUE_PTR_READ_ADD(queue_tail_6); }
            if (ig_md.ing_rank_id == 7) { QUEUE_PTR_READ_ADD(queue_tail_7); }

            /* Write bitmaps from payload */
            ig_md.tmp_c = hdr.payload.data00;
            BITMAP_WRITE(bitmap_0);
            ig_md.tmp_c = hdr.payload.data01;
            BITMAP_WRITE(bitmap_1);
            ig_md.tmp_c = hdr.payload.data02;
            BITMAP_WRITE(bitmap_2);
            ig_md.tmp_c = hdr.payload.data03;
            BITMAP_WRITE(bitmap_3);
            ig_md.tmp_c = hdr.payload.data04;
            BITMAP_WRITE(bitmap_4);
            ig_md.tmp_c = hdr.payload.data05;
            BITMAP_WRITE(bitmap_5);
            ig_md.tmp_c = hdr.payload.data06;
            BITMAP_WRITE(bitmap_6);
            ig_md.tmp_c = hdr.payload.data07;
            BITMAP_WRITE(bitmap_7);
        }
        else if (ig_md.conn_semantics == CONN_SEMANTICS.CONN_TX) {
            /* Clear this sender's bit from the bitmap */
            tbl_rank_to_clear_mask.apply();

            if (ig_md.tmp_a == 0)      { BITMAP_CLEAR_BIT(bitmap_0); }
            if (ig_md.tmp_a == 1)      { BITMAP_CLEAR_BIT(bitmap_1); }
            if (ig_md.tmp_a == 2)      { BITMAP_CLEAR_BIT(bitmap_2); }
            if (ig_md.tmp_a == 3)      { BITMAP_CLEAR_BIT(bitmap_3); }
            if (ig_md.tmp_a == 4)      { BITMAP_CLEAR_BIT(bitmap_4); }
            if (ig_md.tmp_a == 5)      { BITMAP_CLEAR_BIT(bitmap_5); }
            if (ig_md.tmp_a == 6)      { BITMAP_CLEAR_BIT(bitmap_6); }
            else                       { BITMAP_CLEAR_BIT(bitmap_7); }

            /* Conditionally increment queue head */
            if (ig_md.ing_rank_id == 0) { QUEUE_PTR_COND_INC(queue_head_0); }
            if (ig_md.ing_rank_id == 1) { QUEUE_PTR_COND_INC(queue_head_1); }
            if (ig_md.ing_rank_id == 2) { QUEUE_PTR_COND_INC(queue_head_2); }
            if (ig_md.ing_rank_id == 3) { QUEUE_PTR_COND_INC(queue_head_3); }
            if (ig_md.ing_rank_id == 4) { QUEUE_PTR_COND_INC(queue_head_4); }
            if (ig_md.ing_rank_id == 5) { QUEUE_PTR_COND_INC(queue_head_5); }
            if (ig_md.ing_rank_id == 6) { QUEUE_PTR_COND_INC(queue_head_6); }
            if (ig_md.ing_rank_id == 7) { QUEUE_PTR_COND_INC(queue_head_7); }

            /* Check if aggregation is complete for this token */
            if (ig_md.tmp_c != ig_md.tx_loc_val) {
                return;
            } else {
                ig_tm_md.mcast_grp_b = LOOPBACK_MCAST_GRP;
            }
        }
        else if (ig_md.conn_semantics == CONN_SEMANTICS.CONN_LOOPBACK) {
            /* Read queue tail for this root rank */
            if (ig_md.root_rank_id == 0) { QUEUE_PTR_READ(queue_tail_0); }
            if (ig_md.root_rank_id == 1) { QUEUE_PTR_READ(queue_tail_1); }
            if (ig_md.root_rank_id == 2) { QUEUE_PTR_READ(queue_tail_2); }
            if (ig_md.root_rank_id == 3) { QUEUE_PTR_READ(queue_tail_3); }
            if (ig_md.root_rank_id == 4) { QUEUE_PTR_READ(queue_tail_4); }
            if (ig_md.root_rank_id == 5) { QUEUE_PTR_READ(queue_tail_5); }
            if (ig_md.root_rank_id == 6) { QUEUE_PTR_READ(queue_tail_6); }
            if (ig_md.root_rank_id == 7) { QUEUE_PTR_READ(queue_tail_7); }

            /* Check if next position equals tail (queue full) */
            if (ig_md.tx_offset_val == ig_md.tmp_c) {
                return;
            }

            /* Read bitmap for completion check */
            if (ig_md.tmp_a == 0)      { BITMAP_READ(bitmap_0); }
            if (ig_md.tmp_a == 1)      { BITMAP_READ(bitmap_1); }
            if (ig_md.tmp_a == 2)      { BITMAP_READ(bitmap_2); }
            if (ig_md.tmp_a == 3)      { BITMAP_READ(bitmap_3); }
            if (ig_md.tmp_a == 4)      { BITMAP_READ(bitmap_4); }
            if (ig_md.tmp_a == 5)      { BITMAP_READ(bitmap_5); }
            if (ig_md.tmp_a == 6)      { BITMAP_READ(bitmap_6); }
            else                       { BITMAP_READ(bitmap_7); }

            /* If bitmap not zero, aggregation not complete */
            if (ig_md.tmp_c != 0) {
                return;
            } else {
                /* Store next location in payload for loopback */
                hdr.payload.data00 = ig_md.tx_offset_val;
                ig_tm_md.mcast_grp_b = LOOPBACK_MCAST_GRP;
            }

            /* Increment queue head for completed token */
            if (ig_md.root_rank_id == 0) { QUEUE_PTR_INC(queue_head_0); }
            if (ig_md.root_rank_id == 1) { QUEUE_PTR_INC(queue_head_1); }
            if (ig_md.root_rank_id == 2) { QUEUE_PTR_INC(queue_head_2); }
            if (ig_md.root_rank_id == 3) { QUEUE_PTR_INC(queue_head_3); }
            if (ig_md.root_rank_id == 4) { QUEUE_PTR_INC(queue_head_4); }
            if (ig_md.root_rank_id == 5) { QUEUE_PTR_INC(queue_head_5); }
            if (ig_md.root_rank_id == 6) { QUEUE_PTR_INC(queue_head_6); }
            if (ig_md.root_rank_id == 7) { QUEUE_PTR_INC(queue_head_7); }
        }
    }
}


/* =============================================================================
 * Combine Egress Control
 *
 * Processes egress packets for the combine phase:
 *   - TX: performs aggregation and generates ACK/loopback responses
 *   - Control: generates queue state response
 *   - Bitmap: generates ACK response
 * ============================================================================= */

control CombineEgress(
    inout a2a_headers_t                            hdr,
    inout a2a_egress_metadata_t                    eg_md,
    in    egress_intrinsic_metadata_t              eg_intr_md,
    inout egress_intrinsic_metadata_for_deparser_t eg_dprsr_md)
{
    /* =========================================================================
     * Aggregation Buffer Register
     * ========================================================================= */

    Register<bit<32>, bit<32>>(COMBINE_BUFFER_ENTRIES) reg_agg;

    RegisterAction<bit<32>, bit<32>, void>(reg_agg) ra_store = {
        void apply(inout bit<32> value) {
            value = eg_md.tmp_b;
        }
    };

    RegisterAction<bit<32>, bit<32>, void>(reg_agg) ra_aggregate = {
        void apply(inout bit<32> value) {
            value = value + eg_md.tmp_b;
        }
    };

    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_agg) ra_read_agg = {
        void apply(inout bit<32> value, out bit<32> res) {
            res = value;
        }
    };

    action do_store()     { ra_store.execute(eg_md.tmp_a); }
    action do_aggregate() { ra_aggregate.execute(eg_md.tmp_a); }
    action do_read_agg()  { eg_md.tmp_b = ra_read_agg.execute(eg_md.tmp_a); }

    /* =========================================================================
     * Utility Actions
     * ========================================================================= */

    action swap_l2_l3_l4() {
        bit<48> tmp_mac  = hdr.eth.src_addr;
        hdr.eth.src_addr = hdr.eth.dst_addr;
        hdr.eth.dst_addr = tmp_mac;

        bit<32> tmp_ip    = hdr.ipv4.src_addr;
        hdr.ipv4.src_addr = hdr.ipv4.dst_addr;
        hdr.ipv4.dst_addr = tmp_ip;

        bit<16> tmp_port = hdr.udp.src_port;
        hdr.udp.src_port = hdr.udp.dst_port;
        hdr.udp.dst_port = tmp_port;
    }

    action set_ack_len() {
        hdr.udp.length     = 28;
        hdr.ipv4.total_len = 48;
        hdr.udp.checksum   = 0;
    }

    action set_write_first_len() {
        hdr.udp.length     = 8 + 12 + 16 + PAYLOAD_LEN + 4;
        hdr.ipv4.total_len = 20 + 8 + 12 + 16 + PAYLOAD_LEN + 4;
        hdr.udp.checksum   = 0;
    }

    action set_write_middle_len() {
        hdr.udp.length     = 8 + 12 + PAYLOAD_LEN + 4;
        hdr.ipv4.total_len = 20 + 8 + 12 + PAYLOAD_LEN + 4;
        hdr.udp.checksum   = 0;
    }

    /* =========================================================================
     * RX Info Lookup Table
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

    table tbl_rx_info {
        key = {
            eg_md.channel_id   : exact;
            eg_md.root_rank_id : exact;
        }
        actions = {
            set_rx_info;
            NoAction;
        }
        size = 128;
        default_action = NoAction;
    }

    /* =========================================================================
     * PSN Calculation Actions
     * ========================================================================= */

    action step1_calc_psn_add() { eg_md.psn = eg_md.psn + eg_md.egress_rid; }
    action step2_write_bth_psn() { hdr.bth.psn = eg_md.psn; }

    /* =========================================================================
     * Buffer Index Calculation Table
     * ========================================================================= */

    action cal_buffer_idx(bit<32> buffer_idx) {
        eg_md.tmp_a = buffer_idx;
    }

    table tbl_buffer_idx {
        key = {
            eg_md.channel_id : exact;
            eg_md.tx_loc_val : exact;
            eg_md.tmp_b      : exact;
        }
        actions = {
            cal_buffer_idx;
        }
        size = 128;
    }

    /* =========================================================================
     * Apply Block
     * ========================================================================= */

    apply {
        /* ---------------------------------------------------------------------
         * TX Data Processing
         * --------------------------------------------------------------------- */
        if (eg_md.conn_semantics == CONN_SEMANTICS.CONN_TX) {

            /* Loopback port: prepare write-first packet to root */
            if (eg_intr_md.egress_port == LOOPBACK_PORT) {
                hdr.bth.opcode = RDMA_OP_WRITE_FIRST;
                hdr.reth.setValid();
                hdr.reth.addr = eg_md.next_token_addr;
                hdr.reth.len  = TOKEN_SIZE;

                /* Non-loopback: set first word to token location */
                if (!eg_md.is_loopback) {
                    hdr.payload_first_word.data = eg_md.tx_loc_val;
                }

                tbl_rx_info.apply();
                set_write_first_len();
                hdr.aeth.setInvalid();
            }
            /* Regular egress port: perform aggregation or read */
            else {
                /* Determine packet offset */
                if (eg_md.is_loopback) {
                    eg_md.tmp_b = eg_md.egress_rid;
                } else {
                    eg_md.tmp_b = eg_md.tx_offset_val;
                }

                /* Calculate buffer index */
                tbl_buffer_idx.apply();

                /* Get payload data */
                hdr.payload_first_word.setValid();
                eg_md.tmp_b = hdr.payload_first_word.data;

                /* Loopback: read aggregated value; Normal: aggregate */
                if (eg_md.is_loopback) {
                    eg_md.tmp_b = ra_read_agg.execute(eg_md.tmp_a);
                } else {
                    ra_aggregate.execute(eg_md.tmp_a);
                }

                /* Generate appropriate response */
                if (eg_md.is_loopback) {
                    /* Write aggregated data to destination */
                    hdr.payload_first_word.data = eg_md.tmp_b;
                    eg_md.psn = eg_md.psn + eg_md.egress_rid;
                    hdr.bth.psn = eg_md.psn;

                    /* Set opcode based on position in token */
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
                } else {
                    /* Generate ACK for sender */
                    swap_l2_l3_l4();
                    set_ack_len();
                    hdr.aeth.setValid();
                    hdr.bth.opcode = RDMA_OP_ACK;
                    hdr.reth.setInvalid();
                    hdr.payload.setInvalid();
                }
            }
        }

        /* ---------------------------------------------------------------------
         * Control Connection: Return Queue State
         * --------------------------------------------------------------------- */
        else if (eg_md.conn_semantics == CONN_SEMANTICS.CONN_CONTROL) {
            hdr.udp.length     = 156;
            hdr.ipv4.total_len = 176;
            hdr.udp.checksum   = 0;
            swap_l2_l3_l4();
            hdr.reth.setInvalid();
            hdr.payload.setValid();
            hdr.bth.opcode = RDMA_OP_READ_RES_ONLY;
        }

        /* ---------------------------------------------------------------------
         * Bitmap Update: Generate ACK
         * --------------------------------------------------------------------- */
        else if (eg_md.conn_semantics == CONN_SEMANTICS.CONN_BITMAP) {
            swap_l2_l3_l4();
            set_ack_len();
            hdr.reth.setInvalid();
            hdr.payload.setInvalid();
            hdr.bth.opcode = RDMA_OP_ACK;
        }
    }
}
