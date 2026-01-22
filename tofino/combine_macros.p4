/*******************************************************************************
 * Macros for Combine Control - Replace sub-controls with inline registers
 ******************************************************************************/

/*******************************************************************************
 * Queue Pointer Slot Macros
 * Usage:
 *   QUEUE_PTR_SLOT_DECLARE(queue_head_0)
 *   QUEUE_PTR_SLOT_INIT(queue_head_0)
 *   QUEUE_PTR_SLOT_READ(queue_head_0)
 *   QUEUE_PTR_SLOT_INC(queue_head_0)
 *   QUEUE_PTR_SLOT_READ_ADD(queue_head_0)
 ******************************************************************************/

#define QUEUE_PTR_SLOT_DECLARE(NAME) \
    Register<bit<32>, bit<32>>(NUM_COMBINE_CHANNELS_PER_RX) NAME##_reg; \
    RegisterAction<bit<32>, bit<32>, void>(NAME##_reg) NAME##_ra_init = { \
        void apply(inout bit<32> value) { \
            value = 0; \
        } \
    }; \
    RegisterAction<bit<32>, bit<32>, bit<32>>(NAME##_reg) NAME##_ra_read = { \
        void apply(inout bit<32> value, out bit<32> res) { \
            res = value; \
        } \
    }; \
    RegisterAction<bit<32>, bit<32>, void>(NAME##_reg) NAME##_ra_inc = { \
        void apply(inout bit<32> value) { \
            if (value == COMBINE_QUEUE_LENGTH - 1) { \
                value = 0; \
            } else { \
                value = value + 1; \
            } \
        } \
    }; \
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
    action NAME##_do_init() { \
        NAME##_ra_init.execute(ig_md.channel_class); \
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

// Simplified call macros
#define QUEUE_PTR_INIT(NAME)      NAME##_do_init()
#define QUEUE_PTR_READ(NAME)      NAME##_do_read()
#define QUEUE_PTR_INC(NAME)       NAME##_do_inc()
#define QUEUE_PTR_READ_ADD(NAME)  NAME##_do_read_add()


/*******************************************************************************
 * Bitmap Slot Macros
 * Usage:
 *   BITMAP_SLOT_DECLARE(bitmap_0)
 *   BITMAP_SLOT_READ(bitmap_0)
 *   BITMAP_SLOT_WRITE(bitmap_0)
 *   BITMAP_SLOT_CLEAR_BIT(bitmap_0)
 *   BITMAP_SLOT_RESET(bitmap_0)
 * tmp_b as slot_index
 * tmp_c as bitmap_write_val bitmap_clear_val
 * tmp_c as return 
 ******************************************************************************/

#define BITMAP_SLOT_DECLARE(NAME) \
    Register<bitmap_tofino_t, bit<32>>(COMBINE_BITMAP_ENTRIES >> 3) NAME##_reg; \
    RegisterAction<bitmap_tofino_t, bit<32>, bitmap_tofino_t>(NAME##_reg) NAME##_ra_read = { \
        void apply(inout bitmap_tofino_t value, out bitmap_tofino_t res) { \
            res = value; \
        } \
    }; \
    RegisterAction<bitmap_tofino_t, bit<32>, void>(NAME##_reg) NAME##_ra_write = { \
        void apply(inout bitmap_tofino_t value) { \
            value = ig_md.tmp_c; \
        } \
    }; \
    RegisterAction<bitmap_tofino_t, bit<32>, bitmap_tofino_t>(NAME##_reg) NAME##_ra_clear_bit = { \
        void apply(inout bitmap_tofino_t value, out bitmap_tofino_t res) { \
            value = value ^ ig_md.tmp_c; \
            res = value; \
        } \
    }; \
    RegisterAction<bitmap_tofino_t, bit<32>, void>(NAME##_reg) NAME##_ra_reset = { \
        void apply(inout bitmap_tofino_t value) { \
            value = 0; \
        } \
    }; \
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

// Simplified call macros
#define BITMAP_READ(NAME)       NAME##_do_read()
#define BITMAP_WRITE(NAME)      NAME##_do_write()
#define BITMAP_CLEAR_BIT(NAME)  NAME##_do_clear_bit()
#define BITMAP_RESET(NAME)      NAME##_do_reset()


/*******************************************************************************
 * Addr Slot Macros
 * Usage:
 *   ADDR_SLOT_DECLARE(addr_0)
 *   ADDR_SLOT_READ(addr_0)
 *   ADDR_SLOT_WRITE(addr_0)
 * tmp_b as slot_index
 * tmp_d, tmp_e as write read value 
 ******************************************************************************/

#define ADDR_SLOT_DECLARE(NAME) \
    Register<addr_half_t, bit<32>>(COMBINE_BITMAP_ENTRIES >> 3) NAME##_reg_lo; \
    Register<addr_half_t, bit<32>>(COMBINE_BITMAP_ENTRIES >> 3) NAME##_reg_hi; \
    RegisterAction<addr_half_t, bit<32>, addr_half_t>(NAME##_reg_lo) NAME##_ra_lo_read = { \
        void apply(inout addr_half_t value, out addr_half_t res) { \
            res = value; \
        } \
    }; \
    RegisterAction<addr_half_t, bit<32>, void>(NAME##_reg_lo) NAME##_ra_lo_write = { \
        void apply(inout addr_half_t value) { \
            value = ig_md.tmp_d; \
        } \
    }; \
    RegisterAction<addr_half_t, bit<32>, addr_half_t>(NAME##_reg_hi) NAME##_ra_hi_read = { \
        void apply(inout addr_half_t value, out addr_half_t res) { \
            res = value; \
        } \
    }; \
    RegisterAction<addr_half_t, bit<32>, void>(NAME##_reg_hi) NAME##_ra_hi_write = { \
        void apply(inout addr_half_t value) { \
            value = ig_md.tmp_e; \
        } \
    }; \
    action NAME##_do_read() { \
        ig_md.tmp_d = NAME##_ra_lo_read.execute(ig_md.tmp_b); \
        ig_md.tmp_e = NAME##_ra_hi_read.execute(ig_md.tmp_b); \
    } \
    action NAME##_do_write() { \
        NAME##_ra_lo_write.execute(ig_md.tmp_b); \
        NAME##_ra_hi_write.execute(ig_md.tmp_b); \
    }

// Simplified call macros  
#define ADDR_READ(NAME)   NAME##_do_read()
#define ADDR_WRITE(NAME)  NAME##_do_write()
