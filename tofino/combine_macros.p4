/**
 * @file combine_macros.p4
 * @brief Macros for Combine control register management
 *
 * Provides macro-based register declarations and operations for the
 * Combine phase. Using macros instead of sub-controls avoids variable
 * duplication issues in the Tofino compiler.
 */

/* =============================================================================
 * Queue Pointer Slot Macros
 *
 * Manages circular queue pointers (head/tail) for token buffering.
 *
 * Usage:
 *   QUEUE_PTR_SLOT_DECLARE(queue_head_0)  - Declare registers and actions
 *   QUEUE_PTR_COND_INC(queue_head_0)      - Conditional increment
 *   QUEUE_PTR_READ(queue_head_0)          - Read current value
 *   QUEUE_PTR_INC(queue_head_0)           - Unconditional increment
 *   QUEUE_PTR_READ_ADD(queue_head_0)      - Read and add 8 (circular)
 *
 * Output: ig_md.tmp_c contains the result
 * ============================================================================= */

#define QUEUE_PTR_SLOT_DECLARE(NAME) \
    Register<bit<32>, bit<32>>(NUM_COMBINE_CHANNELS_PER_RX) NAME##_reg; \
    \
    /* Conditional increment: increment only if value equals tx_loc_val */ \
    RegisterAction<bit<32>, bit<32>, bit<32>>(NAME##_reg) NAME##_ra_cond_inc = { \
        void apply(inout bit<32> value, out bit<32> result) { \
            result = value; \
            if (value == ig_md.tx_loc_val) { \
                if (value == 63) { \
                    value = 0; \
                } else { \
                    value = value + 1; \
                } \
            } \
        } \
    }; \
    \
    /* Read current value */ \
    RegisterAction<bit<32>, bit<32>, bit<32>>(NAME##_reg) NAME##_ra_read = { \
        void apply(inout bit<32> value, out bit<32> res) { \
            res = value; \
        } \
    }; \
    \
    /* Unconditional increment with wraparound */ \
    RegisterAction<bit<32>, bit<32>, void>(NAME##_reg) NAME##_ra_inc = { \
        void apply(inout bit<32> value) { \
            if (value == COMBINE_QUEUE_LENGTH - 1) { \
                value = 0; \
            } else { \
                value = value + 1; \
            } \
        } \
    }; \
    \
    /* Read and add 8 with wraparound (for bitmap batch operations) */ \
    RegisterAction<bit<32>, bit<32>, bit<32>>(NAME##_reg) NAME##_ra_read_add = { \
        void apply(inout bit<32> value, out bit<32> res) { \
            res = value; \
            if (value >= COMBINE_QUEUE_LENGTH - 8) { \
                value = value + 8 - COMBINE_QUEUE_LENGTH; \
            } else { \
                value = value + 8; \
            } \
        } \
    }; \
    \
    action NAME##_do_cond_inc() { \
        ig_md.tmp_c = NAME##_ra_cond_inc.execute(ig_md.channel_class); \
    } \
    action NAME##_do_read() { \
        ig_md.tmp_c = NAME##_ra_read.execute(ig_md.channel_class); \
    } \
    action NAME##_do_inc() { \
        NAME##_ra_inc.execute(ig_md.channel_class); \
    } \
    action NAME##_do_read_add() { \
        ig_md.tmp_c = NAME##_ra_read_add.execute(ig_md.channel_class); \
    }

/* Queue pointer operation macros */
#define QUEUE_PTR_COND_INC(NAME) NAME##_do_cond_inc()
#define QUEUE_PTR_READ(NAME)     NAME##_do_read()
#define QUEUE_PTR_INC(NAME)      NAME##_do_inc()
#define QUEUE_PTR_READ_ADD(NAME) NAME##_do_read_add()


/* =============================================================================
 * Bitmap Slot Macros
 *
 * Manages bitmaps for tracking which endpoints have contributed data.
 *
 * Usage:
 *   BITMAP_SLOT_DECLARE(bitmap_0)     - Declare registers and actions
 *   BITMAP_READ(bitmap_0)             - Read current bitmap
 *   BITMAP_WRITE(bitmap_0)            - Write new bitmap
 *   BITMAP_CLEAR_BIT(bitmap_0)        - XOR to clear specific bit(s)
 *   BITMAP_RESET(bitmap_0)            - Reset to zero
 *
 * Input:  ig_md.tmp_b = slot index
 *         ig_md.tmp_c = value to write or clear mask
 * Output: ig_md.tmp_c = result value
 * ============================================================================= */

#define BITMAP_SLOT_DECLARE(NAME) \
    Register<bitmap_tofino_t, bit<32>>(COMBINE_BITMAP_ENTRIES >> 3) NAME##_reg; \
    \
    /* Read current bitmap value */ \
    RegisterAction<bitmap_tofino_t, bit<32>, bitmap_tofino_t>(NAME##_reg) NAME##_ra_read = { \
        void apply(inout bitmap_tofino_t value, out bitmap_tofino_t res) { \
            res = value; \
        } \
    }; \
    \
    /* Write new bitmap value */ \
    RegisterAction<bitmap_tofino_t, bit<32>, void>(NAME##_reg) NAME##_ra_write = { \
        void apply(inout bitmap_tofino_t value) { \
            value = ig_md.tmp_c; \
        } \
    }; \
    \
    /* XOR to clear specified bit(s), return result */ \
    RegisterAction<bitmap_tofino_t, bit<32>, bitmap_tofino_t>(NAME##_reg) NAME##_ra_clear_bit = { \
        void apply(inout bitmap_tofino_t value, out bitmap_tofino_t res) { \
            value = value ^ ig_md.tmp_c; \
            res = value; \
        } \
    }; \
    \
    /* Reset bitmap to zero */ \
    RegisterAction<bitmap_tofino_t, bit<32>, void>(NAME##_reg) NAME##_ra_reset = { \
        void apply(inout bitmap_tofino_t value) { \
            value = 0; \
        } \
    }; \
    \
    action NAME##_do_read() { \
        ig_md.tmp_c = NAME##_ra_read.execute(ig_md.tmp_b); \
    } \
    action NAME##_do_write() { \
        NAME##_ra_write.execute(ig_md.tmp_b); \
    } \
    action NAME##_do_clear_bit() { \
        ig_md.tmp_c = NAME##_ra_clear_bit.execute(ig_md.tmp_b); \
    } \
    action NAME##_do_reset() { \
        NAME##_ra_reset.execute(ig_md.tmp_b); \
    }

/* Bitmap operation macros */
#define BITMAP_READ(NAME)      NAME##_do_read()
#define BITMAP_WRITE(NAME)     NAME##_do_write()
#define BITMAP_CLEAR_BIT(NAME) NAME##_do_clear_bit()
#define BITMAP_RESET(NAME)     NAME##_do_reset()


/* =============================================================================
 * Address Slot Macros
 *
 * Manages 64-bit addresses using two 32-bit registers (lo/hi split).
 *
 * Usage:
 *   ADDR_SLOT_DECLARE(addr_0)   - Declare registers and actions
 *   ADDR_READ(addr_0)           - Read both halves
 *   ADDR_WRITE(addr_0)          - Write both halves
 *
 * Input:  ig_md.tmp_b = slot index
 *         ig_md.tmp_d = low 32 bits (for write)
 *         ig_md.tmp_e = high 32 bits (for write)
 * Output: ig_md.tmp_d = low 32 bits (for read)
 *         ig_md.tmp_e = high 32 bits (for read)
 * ============================================================================= */

#define ADDR_SLOT_DECLARE(NAME) \
    Register<addr_half_t, bit<32>>(COMBINE_BITMAP_ENTRIES >> 3) NAME##_reg_lo; \
    Register<addr_half_t, bit<32>>(COMBINE_BITMAP_ENTRIES >> 3) NAME##_reg_hi; \
    \
    /* Read low 32 bits */ \
    RegisterAction<addr_half_t, bit<32>, addr_half_t>(NAME##_reg_lo) NAME##_ra_lo_read = { \
        void apply(inout addr_half_t value, out addr_half_t res) { \
            res = value; \
        } \
    }; \
    \
    /* Write low 32 bits */ \
    RegisterAction<addr_half_t, bit<32>, void>(NAME##_reg_lo) NAME##_ra_lo_write = { \
        void apply(inout addr_half_t value) { \
            value = ig_md.tmp_d; \
        } \
    }; \
    \
    /* Read high 32 bits */ \
    RegisterAction<addr_half_t, bit<32>, addr_half_t>(NAME##_reg_hi) NAME##_ra_hi_read = { \
        void apply(inout addr_half_t value, out addr_half_t res) { \
            res = value; \
        } \
    }; \
    \
    /* Write high 32 bits */ \
    RegisterAction<addr_half_t, bit<32>, void>(NAME##_reg_hi) NAME##_ra_hi_write = { \
        void apply(inout addr_half_t value) { \
            value = ig_md.tmp_e; \
        } \
    }; \
    \
    action NAME##_do_read_lo() { \
        ig_md.tmp_d = NAME##_ra_lo_read.execute(ig_md.tmp_b); \
    } \
    action NAME##_do_read_hi() { \
        ig_md.tmp_e = NAME##_ra_hi_read.execute(ig_md.tmp_b); \
    } \
    action NAME##_do_write_lo() { \
        NAME##_ra_lo_write.execute(ig_md.tmp_b); \
    } \
    action NAME##_do_write_hi() { \
        NAME##_ra_hi_write.execute(ig_md.tmp_b); \
    }

/* Address operation macros */
#define ADDR_READ(NAME)  NAME##_do_read_lo(); NAME##_do_read_hi()
#define ADDR_WRITE(NAME) NAME##_do_write_lo(); NAME##_do_write_hi()
