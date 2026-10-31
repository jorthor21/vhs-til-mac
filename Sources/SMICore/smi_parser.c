/*
 * smi_parser.c – VHS til Mac
 * Reconstructs interlaced UYVY frames (ITU-R BT.656 embedded sync) and
 * stereo PCM audio from the SMI2021 isochronous block stream.
 *
 * Stream layout (documented by the smi2021 / easycap-somagic projects):
 *   every isochronous packet = N blocks of 0x400 bytes
 *   block header AA AA 00 00 -> 0x3fc bytes of BT.656 video stream
 *   block header AA AA 00 01 -> 0x3fc bytes of audio (S32LE stereo 48 kHz,
 *                               low byte of every sample is 0x00)
 *   video lines: FF 00 00 SAV, 1440 bytes UYVY, FF 00 00 EAV
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include "smi_core.h"

#include <stdlib.h>
#include <string.h>

#define FRAME_BYTES (SMI_BYTES_PER_LINE * SMI_MAX_LINES_PER_FIELD * 2)
#define AUDIO_TMP   (SMI_BLOCK_PAYLOAD + 16)

struct smi_parser {
    smi_standard standard;
    int height;
    int lines_per_field;
    bool swap_fields;
    bool emit_partial;

    smi_frame_fn frame_cb;
    smi_audio_fn audio_cb;
    void *user;

    uint8_t *frame;

    /* BT.656 sync state */
    int  match;        /* 0: none, 1: FF, 2: FF 00, 3: FF 00 00 */
    int  field;        /* current F bit, -1 = unknown */
    bool synced;       /* a field-2 -> field-1 transition has been seen */
    bool damaged;      /* data lost during the current frame */
    bool in_active;    /* copying an active video line */
    int  cur_row;      /* frame row for current line, -1 = discard */
    int  col;          /* bytes received in current line */
    int  lines[2];
    uint64_t sequence;

    /* audio */
    uint8_t  audio_left[8];
    int      audio_left_len;
    int32_t  audio_out[AUDIO_TMP / 4];
    uint8_t  audio_tmp[AUDIO_TMP];

    smi_parser_stats st;
};

static const uint8_t k_valid_xy[8] = { 0x80, 0x9d, 0xab, 0xb6, 0xc7, 0xda, 0xec, 0xf1 };

bool smi_trc_is_valid(uint8_t xy)
{
    for (int i = 0; i < 8; i++)
        if (k_valid_xy[i] == xy) return true;
    return false;
}

static int xy_index(uint8_t xy)
{
    for (int i = 0; i < 8; i++)
        if (k_valid_xy[i] == xy) return i;
    return -1;
}

static void apply_standard(smi_parser *p, smi_standard s)
{
    p->standard = s;
    p->height = (s == SMI_STD_NTSC) ? 480 : 576;
    p->lines_per_field = p->height / 2;
}

smi_parser *smi_parser_create(smi_standard standard, smi_frame_fn frame_cb,
                              smi_audio_fn audio_cb, void *user)
{
    smi_parser *p = calloc(1, sizeof(*p));
    if (!p) return NULL;
    p->frame = calloc(1, FRAME_BYTES);
    if (!p->frame) { free(p); return NULL; }
    /* Fill with black (UYVY 80 10 80 10) so partial frames look sane. */
    for (size_t i = 0; i < FRAME_BYTES; i += 2) { p->frame[i] = 0x80; p->frame[i + 1] = 0x10; }
    p->frame_cb = frame_cb;
    p->audio_cb = audio_cb;
    p->user = user;
    p->emit_partial = true;
    apply_standard(p, standard);
    smi_parser_reset(p);
    return p;
}

void smi_parser_destroy(smi_parser *p)
{
    if (!p) return;
    free(p->frame);
    free(p);
}

void smi_parser_reset(smi_parser *p)
{
    p->match = 0;
    p->field = -1;
    p->synced = false;
    p->damaged = false;
    p->in_active = false;
    p->cur_row = -1;
    p->col = 0;
    p->lines[0] = p->lines[1] = 0;
    p->audio_left_len = 0;
    memset(&p->st, 0, sizeof(p->st));
}

void smi_parser_set_standard(smi_parser *p, smi_standard s)
{
    apply_standard(p, s);
    p->synced = false;
    p->lines[0] = p->lines[1] = 0;
}

void smi_parser_set_swap_fields(smi_parser *p, bool swap) { p->swap_fields = swap; }
void smi_parser_set_emit_partial(smi_parser *p, bool emit) { p->emit_partial = emit; }

void smi_parser_get_stats(const smi_parser *p, smi_parser_stats *out) { *out = p->st; }

void smi_parser_discontinuity(smi_parser *p)
{
    p->st.discontinuities++;
    p->match = 0;
    p->in_active = false;
    p->cur_row = -1;
    p->damaged = true;
    p->audio_left_len = 0;
}

/* ---------------------------------------------------------------- video */

static inline void put_run(smi_parser *p, const uint8_t *d, size_t n)
{
    if (!p->in_active) return;
    if (p->cur_row >= 0 && p->col < SMI_BYTES_PER_LINE) {
        size_t room = (size_t)(SMI_BYTES_PER_LINE - p->col);
        size_t c = n < room ? n : room;
        int y = 2 * p->cur_row + ((p->field ^ (p->swap_fields ? 1 : 0)) & 1);
        memcpy(p->frame + (size_t)y * SMI_BYTES_PER_LINE + (size_t)p->col, d, c);
    }
    p->col += (int)n;
}

static inline void put_byte(smi_parser *p, uint8_t b) { put_run(p, &b, 1); }

static void finish_line(smi_parser *p)
{
    if (!p->in_active) return;
    if (p->col > SMI_BYTES_PER_LINE) p->st.long_lines++;
    else if (p->col < SMI_BYTES_PER_LINE) p->st.short_lines++;
    p->in_active = false;
    p->cur_row = -1;
}

static void emit_frame(smi_parser *p)
{
    int l0 = p->lines[0] < p->lines_per_field ? p->lines[0] : p->lines_per_field;
    int l1 = p->lines[1] < p->lines_per_field ? p->lines[1] : p->lines_per_field;
    bool complete = !p->damaged &&
                    l0 >= p->lines_per_field - 8 &&
                    l1 >= p->lines_per_field - 8;

    p->st.last_lines_field[0] = (uint32_t)p->lines[0];
    p->st.last_lines_field[1] = (uint32_t)p->lines[1];
    for (int f = 0; f < 2; f++)
        if ((uint32_t)p->lines[f] > p->st.max_lines_field[f])
            p->st.max_lines_field[f] = (uint32_t)p->lines[f];

    if (complete) p->st.frames_complete++;
    else p->st.frames_partial++;

    if (p->frame_cb && (complete || p->emit_partial)) {
        smi_frame_info fi;
        fi.data = p->frame;
        fi.stride = SMI_BYTES_PER_LINE;
        fi.width = SMI_WIDTH;
        fi.height = p->height;
        fi.lines_field[0] = l0;
        fi.lines_field[1] = l1;
        fi.complete = complete;
        fi.sequence = p->sequence;
        p->frame_cb(p->user, &fi);
    }
    p->sequence++;
}

static void handle_xy(smi_parser *p, uint8_t xy)
{
    int idx = xy_index(xy);
    if (idx < 0) {
        /* 0x00 here is a sliced-data ID (ancillary), anything else is noise. */
        p->st.trc_invalid++;
        return;
    }
    p->st.trc_valid++;
    p->st.trc_histogram[idx]++;

    int f = (xy >> 6) & 1;
    int v = (xy >> 5) & 1;
    int h = (xy >> 4) & 1;

    if (h) {                 /* EAV: end of a line */
        finish_line(p);
        return;
    }

    /* SAV: start of a line. Terminate a line whose EAV was lost. */
    finish_line(p);

    if (f != p->field) {
        if (p->field == 1 && f == 0) {
            /* Field 2 -> field 1: a whole frame has been received. */
            if (p->synced) emit_frame(p);
            p->synced = true;
            p->damaged = false;
            p->lines[0] = p->lines[1] = 0;
        } else {
            p->lines[f] = 0;
        }
        p->field = f;
    }

    if (v) {                 /* vertical blanking */
        p->st.sav_blank++;
        return;
    }

    p->st.sav_active++;
    int row = p->lines[f]++;
    p->cur_row = (row < p->lines_per_field) ? row : -1;
    p->col = 0;
    p->in_active = true;
}

void smi_parser_feed_video(smi_parser *p, const uint8_t *d, size_t len)
{
    size_t i = 0;
    while (i < len) {
        if (p->match == 0) {
            /* Fast path: copy everything up to the next 0xFF. */
            const uint8_t *ff = memchr(d + i, 0xff, len - i);
            size_t run = ff ? (size_t)(ff - (d + i)) : (len - i);
            if (run) put_run(p, d + i, run);
            i += run;
            if (i < len) { p->match = 1; i++; }
            continue;
        }
        uint8_t b = d[i++];
        switch (p->match) {
        case 1:
            if (b == 0x00) p->match = 2;
            else { put_byte(p, 0xff); if (b == 0xff) p->match = 1; else { p->match = 0; put_byte(p, b); } }
            break;
        case 2:
            if (b == 0x00) p->match = 3;
            else {
                put_byte(p, 0xff); put_byte(p, 0x00);
                if (b == 0xff) p->match = 1; else { p->match = 0; put_byte(p, b); }
            }
            break;
        case 3:
            p->match = 0;
            handle_xy(p, b);
            break;
        }
    }
}

/* ---------------------------------------------------------------- audio */

static int zero_score(const uint8_t *d, size_t n, int phase)
{
    int z = 0;
    for (size_t k = (size_t)phase; k < n; k += 4)
        if (d[k] == 0) z++;
    return z;
}

void smi_parser_feed_audio(smi_parser *p, const uint8_t *d, size_t len)
{
    if (len > SMI_BLOCK_PAYLOAD) len = SMI_BLOCK_PAYLOAD;
    size_t n = (size_t)p->audio_left_len;
    memcpy(p->audio_tmp, p->audio_left, n);
    memcpy(p->audio_tmp + n, d, len);
    n += len;

    /* Every 32-bit sample starts (little endian) with a 0x00 byte. Check the
     * current alignment and re-align if it is clearly wrong. */
    int samples = (int)(n / 4);
    int start = 0;
    if (samples >= 16) {
        int s0 = zero_score(p->audio_tmp, n, 0);
        if (s0 < (samples * 3) / 4) {
            int best = 0, best_score = s0;
            for (int ph = 1; ph < 4; ph++) {
                int s = zero_score(p->audio_tmp, n, ph);
                if (s > best_score) { best = ph; best_score = s; }
            }
            if (best != 0 && best_score >= (samples * 3) / 4) {
                start = best;
                p->st.audio_realign++;
            }
        }
    }

    size_t usable = n - (size_t)start;
    int frames = (int)(usable / 8);
    const uint8_t *s = p->audio_tmp + start;
    for (int k = 0; k < frames * 2; k++) {
        const uint8_t *q = s + (size_t)k * 4;
        uint32_t u = (uint32_t)q[0] | ((uint32_t)q[1] << 8) | ((uint32_t)q[2] << 16) | ((uint32_t)q[3] << 24);
        p->audio_out[k] = (int32_t)u;
    }
    size_t used = (size_t)frames * 8;
    p->audio_left_len = (int)(usable - used);
    memcpy(p->audio_left, s + used, (size_t)p->audio_left_len);

    p->st.audio_sample_frames += (uint64_t)frames;
    if (frames > 0 && p->audio_cb) p->audio_cb(p->user, p->audio_out, frames);
}

/* -------------------------------------------------------------- packets */

void smi_parser_feed_packet(smi_parser *p, const uint8_t *d, size_t len)
{
    p->st.packets++;
    p->st.packet_bytes += len;
    if (len % SMI_BLOCK_SIZE) p->st.odd_sized_packets++;

    for (size_t pos = 0; pos + SMI_BLOCK_SIZE <= len; pos += SMI_BLOCK_SIZE) {
        const uint8_t *b = d + pos;
        if (b[0] == 0xaa && b[1] == 0xaa && b[2] == 0x00 && b[3] == 0x00) {
            p->st.video_blocks++;
            smi_parser_feed_video(p, b + 4, SMI_BLOCK_PAYLOAD);
        } else if (b[0] == 0xaa && b[1] == 0xaa && b[2] == 0x00 && b[3] == 0x01) {
            p->st.audio_blocks++;
            smi_parser_feed_audio(p, b + 4, SMI_BLOCK_PAYLOAD);
        } else {
            p->st.unknown_blocks++;
            p->st.last_unknown_header = ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) |
                                        ((uint32_t)b[2] << 8) | (uint32_t)b[3];
        }
    }
}
