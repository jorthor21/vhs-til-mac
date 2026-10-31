/*
 * smi_core.h – VHS til Mac
 *
 * Native user-space driver core for the Somagic "ezcap Video Grabber"
 * (USB 1c88:1001) and related SMI2021-based capture adapters.
 *
 * The protocol knowledge used here (vendor control request layout,
 * SMI2021 register writes, GM7113C/SAA7113 decoder register values,
 * 0x400-byte block framing with 0xAAAA0000 / 0xAAAA0001 headers, BT.656
 * timing reference codes and the 32-bit/48 kHz audio format) is documented
 * in the GPL-licensed projects:
 *   - smi2021 Linux kernel driver (Jon Arne Jørgensen et al.)
 *   - easycap-somagic-linux (Tony Brown, Michal Demin, Jeffry Johnston)
 * which were themselves derived from USB traffic logs of the Windows driver.
 * This file is an independent implementation and is distributed under
 * GPL-2.0-or-later, see LICENSE.
 */
#ifndef SMI_CORE_H
#define SMI_CORE_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SMI_VENDOR_ID            0x1c88
#define SMI_PRODUCT_EZCAP_1001   0x1001

#define SMI_WIDTH                720
#define SMI_BYTES_PER_LINE       1440
#define SMI_MAX_LINES_PER_FIELD  320
#define SMI_BLOCK_SIZE           0x400
#define SMI_BLOCK_PAYLOAD        (SMI_BLOCK_SIZE - 4)

#define SMI_AUDIO_RATE           48000
#define SMI_AUDIO_CHANNELS       2

typedef enum {
    SMI_STD_PAL  = 0,   /* 625 lines / 50 Hz – 720x576 @ 25 fps */
    SMI_STD_NTSC = 1    /* 525 lines / 60 Hz – 720x480 @ 29.97 fps */
} smi_standard;

typedef enum {
    SMI_INPUT_COMPOSITE = 0,
    SMI_INPUT_SVIDEO    = 1
} smi_input;

typedef enum {
    SMI_LOG_DEBUG = 0,
    SMI_LOG_INFO  = 1,
    SMI_LOG_WARN  = 2,
    SMI_LOG_ERROR = 3
} smi_log_level;

/* Error codes (negative). Values >= -99 are passed through from libusb. */
enum {
    SMI_OK                 = 0,
    SMI_ERR_NOT_FOUND      = -1001,
    SMI_ERR_NO_MEMORY      = -1002,
    SMI_ERR_BAD_DESCRIPTOR = -1003,
    SMI_ERR_ALREADY        = -1004,
    SMI_ERR_NOT_RUNNING    = -1005,
    SMI_ERR_THREAD         = -1006,
    SMI_ERR_CONTROL        = -1007,
    SMI_ERR_ARGUMENT       = -1008
};

typedef void (*smi_log_fn)(void *user, int level, const char *message);

/* ------------------------------------------------------------------------
 * Stream parser (pure C, no USB). Turns the payload of isochronous packets
 * into complete interlaced UYVY frames and 32-bit stereo audio samples.
 * --------------------------------------------------------------------- */

typedef struct {
    const uint8_t *data;      /* UYVY 4:2:2, interlaced (both fields woven) */
    size_t         stride;    /* bytes per row = SMI_BYTES_PER_LINE */
    int            width;     /* 720 */
    int            height;    /* 576 (PAL) or 480 (NTSC) */
    int            lines_field[2]; /* active lines received in field 1 / field 2 */
    bool           complete;  /* both fields (nearly) complete */
    uint64_t       sequence;  /* running frame number */
} smi_frame_info;

/* Called once per reconstructed frame. 'frame->data' is only valid during
 * the call – copy it. */
typedef void (*smi_frame_fn)(void *user, const smi_frame_info *frame);

/* Called with interleaved stereo samples (L,R,L,R…), signed 32-bit,
 * 48000 Hz. The adapter delivers 24 significant bits in the upper bytes. */
typedef void (*smi_audio_fn)(void *user, const int32_t *samples, int frame_count);

typedef struct {
    uint64_t packets;           /* iso packets fed */
    uint64_t packet_bytes;
    uint64_t odd_sized_packets; /* not a multiple of 0x400 */
    uint64_t video_blocks;      /* 0xAAAA0000 */
    uint64_t audio_blocks;      /* 0xAAAA0001 */
    uint64_t unknown_blocks;
    uint32_t last_unknown_header;
    uint64_t trc_valid;         /* valid BT.656 timing reference codes */
    uint64_t trc_invalid;       /* FF 00 00 xx with bad protection bits */
    uint64_t sav_active;        /* lines of active video started */
    uint64_t sav_blank;         /* vertical blanking lines */
    uint64_t long_lines;        /* active lines longer than 1440 bytes */
    uint64_t short_lines;       /* active lines shorter than 1440 bytes */
    uint64_t frames_complete;
    uint64_t frames_partial;
    uint64_t discontinuities;
    uint64_t audio_sample_frames;
    uint64_t audio_realign;
    uint32_t last_lines_field[2];
    uint32_t max_lines_field[2];
    uint32_t trc_histogram[8];  /* counts for 0x80,0x9d,0xab,0xb6,0xc7,0xda,0xec,0xf1 */
} smi_parser_stats;

typedef struct smi_parser smi_parser;

smi_parser *smi_parser_create(smi_standard standard,
                              smi_frame_fn frame_cb,
                              smi_audio_fn audio_cb,
                              void *user);
void smi_parser_destroy(smi_parser *p);
void smi_parser_reset(smi_parser *p);
void smi_parser_set_standard(smi_parser *p, smi_standard standard);
/* Put field 2 (F=1) on the top line instead of field 1. Default: false. */
void smi_parser_set_swap_fields(smi_parser *p, bool swap);
/* Emit frames even if one field is incomplete (default true; such frames
 * have complete=false). */
void smi_parser_set_emit_partial(smi_parser *p, bool emit);
/* Feed the payload of one isochronous packet (a whole number of 0x400
 * blocks, each starting with a 4-byte header). */
void smi_parser_feed_packet(smi_parser *p, const uint8_t *data, size_t len);
/* Feed raw BT.656 bytes (without the 4-byte block headers). Mainly for tests. */
void smi_parser_feed_video(smi_parser *p, const uint8_t *data, size_t len);
/* Feed raw audio payload bytes (without block headers). */
void smi_parser_feed_audio(smi_parser *p, const uint8_t *data, size_t len);
/* Tell the parser that data was lost (USB error) so it re-synchronises. */
void smi_parser_discontinuity(smi_parser *p);
void smi_parser_get_stats(const smi_parser *p, smi_parser_stats *out);

/* Validate a BT.656 XY byte (the 4th byte of a timing reference code). */
bool smi_trc_is_valid(uint8_t xy);

/* ------------------------------------------------------------------------
 * Image helpers
 * --------------------------------------------------------------------- */

/* Motion-adaptive (comb detecting) deinterlacer for UYVY 4:2:2.
 * Keeps the top field, and replaces bottom-field pixels by vertical
 * interpolation only where combing is detected. threshold ~ 100-400. */
void smi_deinterlace_uyvy(const uint8_t *src, size_t src_stride,
                          uint8_t *dst, size_t dst_stride,
                          int width, int height, int threshold);

/* Mean luma and luma standard deviation of a UYVY image (signal check). */
void smi_uyvy_luma_stats(const uint8_t *src, size_t stride, int width, int height,
                         double *mean, double *stddev);

/* ------------------------------------------------------------------------
 * USB device layer (libusb)
 * --------------------------------------------------------------------- */

typedef struct smi_context smi_context;
typedef struct smi_device  smi_device;

typedef struct {
    bool     found;
    uint16_t vendor_id;
    uint16_t product_id;
    uint16_t bcd_device;
    uint8_t  bus;
    uint8_t  address;
    int      speed;           /* libusb_speed */
    int      somagic_count;   /* number of 1c88:* devices present */
} smi_presence;

typedef struct {
    smi_standard standard;
    smi_input    input;
    uint8_t      composite_mode;     /* GM7113C MODE bits for composite (0..5), default 0 */
    bool         enable_audio;
    uint8_t      brightness;         /* default 0x80 */
    uint8_t      contrast;           /* default 0x47 */
    uint8_t      saturation;         /* default 0x40 */
    int8_t       hue;                /* default 0 */
    int          num_transfers;      /* default 8 */
    int          packets_per_transfer; /* default 64 (multiple of 8) */
    int          alt_setting;        /* default 2 */
    bool         swap_fields;
} smi_config;

typedef struct {
    smi_parser_stats parser;
    uint64_t transfers_completed;
    uint64_t transfer_errors;
    uint64_t iso_packets_ok;
    uint64_t iso_packets_error;
    uint64_t iso_packets_empty;
    uint64_t bytes_received;
    int      last_transfer_status;   /* libusb_transfer_status */
    int      last_iso_status;
    bool     running;
    bool     device_gone;
    double   seconds_running;
} smi_stream_stats;

smi_context *smi_context_create(smi_log_fn log, void *user);
void smi_context_destroy(smi_context *ctx);

/* Cheap presence check, safe to poll. Never opens the device. */
int smi_find(smi_context *ctx, smi_presence *out);

/* Read-only diagnostics: full descriptor tree of all 1c88:* devices.
 * Writes a NUL-terminated text report. Returns SMI_OK or error. */
int smi_describe(smi_context *ctx, char *buf, size_t buflen);

/* Access test: open the device, claim interface 0, release, close.
 * Sends no vendor commands. Appends text to buf. */
int smi_test_access(smi_context *ctx, char *buf, size_t buflen);

void smi_config_default(smi_config *cfg);

/* Open the first supported device and claim interface 0 (alt 0). */
int smi_open(smi_context *ctx, smi_device **out);
void smi_close(smi_device *dev);

/* Initialise the adapter and start isochronous streaming on a private
 * event thread. Callbacks are invoked on that thread. */
int smi_start(smi_device *dev, const smi_config *cfg,
              smi_frame_fn frame_cb, smi_audio_fn audio_cb, void *user);
int smi_stop(smi_device *dev);
bool smi_is_running(smi_device *dev);

void smi_get_stats(smi_device *dev, smi_stream_stats *out);
void smi_set_swap_fields(smi_device *dev, bool swap);

/* Decoder (GM7113C/SAA7113 compatible, I2C 0x4a) status byte, register 0x1f.
 * bit 6 (HLVLN) = 1 -> no horizontal/vertical lock (no signal)
 * bit 5 (FIDT)  = 1 -> 60 Hz signal, 0 -> 50 Hz
 * bit 7 (INTL)  = 1 -> interlaced source */
int smi_read_decoder_status(smi_device *dev, uint8_t *status);
int smi_read_decoder_register(smi_device *dev, uint8_t reg, uint8_t *value);
int smi_set_picture(smi_device *dev, uint8_t brightness, uint8_t contrast,
                    uint8_t saturation, int8_t hue);
/* Change composite mode/input while streaming (writes decoder reg 0x02/0x03/0x09/0x13). */
int smi_set_input(smi_device *dev, smi_input input, uint8_t composite_mode);
int smi_set_audio_enabled(smi_device *dev, bool enabled);

/* Raw tap for diagnostics: the first 'capacity' bytes of iso packet payload
 * are copied into 'buffer' as records [uint16 little-endian length][data].
 * Pass NULL to disable. The buffer must stay valid while streaming. */
void smi_set_raw_tap(smi_device *dev, uint8_t *buffer, size_t capacity);
size_t smi_raw_tap_length(smi_device *dev);

const char *smi_error_name(int code);
const char *smi_version(void);

#ifdef __cplusplus
}
#endif

#endif /* SMI_CORE_H */
