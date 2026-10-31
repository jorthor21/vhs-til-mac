/*
 * Unit tests for the SMI stream parser and image helpers.
 * These tests use SYNTHETIC data that follows the documented stream format.
 * They verify the parsing logic only – not the physical adapter.
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include "smi_core.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf("  FEIL: " __VA_ARGS__); printf("  (%s:%d)\n", __FILE__, __LINE__); } } while (0)

/* ------------------------------------------------------------ generator */

typedef struct { uint8_t *d; size_t len, cap; } bytes;
static void push(bytes *b, uint8_t v) {
    if (b->len == b->cap) { b->cap = b->cap ? b->cap * 2 : 65536; b->d = realloc(b->d, b->cap); }
    b->d[b->len++] = v;
}
static void push_trc(bytes *b, int f, int v, int h) {
    static const uint8_t xy[8] = { 0x80, 0x9d, 0xab, 0xb6, 0xc7, 0xda, 0xec, 0xf1 };
    push(b, 0xff); push(b, 0x00); push(b, 0x00); push(b, xy[(f << 2) | (v << 1) | h]);
}
/* Deterministic pixel value for frame n, field f, active line r, byte x. Never 0x00/0xff. */
static uint8_t pix(int n, int f, int r, int x) {
    if ((x & 1) == 0) return (uint8_t)(0x40 + ((f * 37 + n * 11) & 0x7f));  /* chroma */
    return (uint8_t)(16 + ((r * 3 + x / 2 + n * 7 + f * 101) % 219));        /* luma */
}

static void gen_field(bytes *b, int n, int f, int active, int blank_before) {
    for (int i = 0; i < blank_before; i++) {
        push_trc(b, f, 1, 1);
        for (int k = 0; k < 280; k++) push(b, (k & 1) ? 0x10 : 0x80);
        push_trc(b, f, 1, 0);
        for (int k = 0; k < 1440; k++) push(b, (k & 1) ? 0x10 : 0x80);
    }
    for (int r = 0; r < active; r++) {
        push_trc(b, f, 0, 1);
        for (int k = 0; k < 280; k++) push(b, (k & 1) ? 0x10 : 0x80);
        push_trc(b, f, 0, 0);
        for (int x = 0; x < 1440; x++) push(b, pix(n, f, r, x));
    }
}

/* Audio sample generator: 24-bit value in the upper 3 bytes, low byte 0. */
static int32_t audio_sample(long i, int ch) {
    double v = sin((double)i * 2.0 * M_PI * (ch ? 1000.0 : 440.0) / 48000.0) * 0.5;
    int32_t s24 = (int32_t)(v * 8388607.0);
    return (int32_t)((uint32_t)s24 << 8);
}

/* Interleave video stream and audio stream into 0x400 blocks, 3 per packet. */
typedef struct { uint8_t *d; size_t len; } packet;

static packet *packetize(const bytes *video, long audio_frames, int *npk, int audio_every) {
    bytes a = {0};
    for (long i = 0; i < audio_frames; i++)
        for (int ch = 0; ch < 2; ch++) {
            uint32_t u = (uint32_t)audio_sample(i, ch);
            push(&a, (uint8_t)u); push(&a, (uint8_t)(u >> 8)); push(&a, (uint8_t)(u >> 16)); push(&a, (uint8_t)(u >> 24));
        }
    size_t vpos = 0, apos = 0;
    int cap = 1024, n = 0;
    packet *pk = calloc((size_t)cap, sizeof(packet));
    int block = 0;
    while (vpos < video->len) {
        if (n == cap) { cap *= 2; pk = realloc(pk, (size_t)cap * sizeof(packet)); }
        pk[n].d = calloc(3, 0x400);
        pk[n].len = 0;
        for (int k = 0; k < 3 && vpos < video->len; k++, block++) {
            uint8_t *blk = pk[n].d + pk[n].len;
            bool is_audio = audio_every && (block % audio_every == audio_every - 1) && apos + 0x3fc <= a.len;
            blk[0] = 0xaa; blk[1] = 0xaa; blk[2] = 0x00; blk[3] = is_audio ? 0x01 : 0x00;
            if (is_audio) { memcpy(blk + 4, a.d + apos, 0x3fc); apos += 0x3fc; }
            else {
                size_t c = video->len - vpos < 0x3fc ? video->len - vpos : 0x3fc;
                memcpy(blk + 4, video->d + vpos, c);
                for (size_t z = c; z < 0x3fc; z++) blk[4 + z] = 0x80;
                vpos += c;
            }
            pk[n].len += 0x400;
        }
        n++;
    }
    free(a.d);
    *npk = n;
    return pk;
}

/* ------------------------------------------------------------- receiver */

typedef struct {
    int frames, complete, partial;
    int height;
    int bad_pixels_last;
    int verified;
    uint64_t first_seq;
    int32_t *audio; long audio_n, audio_cap;
    int expect_offset;   /* generator frame index of first emitted frame */
    bool swap;
    int skip_verify_until;
} rx;

static void on_frame(void *u, const smi_frame_info *f) {
    rx *r = u;
    r->frames++;
    if (f->complete) r->complete++; else r->partial++;
    r->height = f->height;
    if (!f->complete || r->frames <= r->skip_verify_until) return;
    int n = r->expect_offset + r->frames - 1;
    int bad = 0;
    for (int y = 0; y < f->height; y++) {
        int field = (y & 1) ^ (r->swap ? 1 : 0);
        int line = y / 2;
        const uint8_t *row = f->data + (size_t)y * f->stride;
        for (int x = 0; x < 1440; x++)
            if (row[x] != pix(n, field, line, x)) bad++;
    }
    r->bad_pixels_last = bad;
    if (bad == 0) r->verified++;
}

static void on_audio(void *u, const int32_t *s, int frames) {
    rx *r = u;
    if (r->audio_n + frames * 2 > r->audio_cap) {
        r->audio_cap = (r->audio_n + frames * 2) * 2;
        r->audio = realloc(r->audio, (size_t)r->audio_cap * sizeof(int32_t));
    }
    memcpy(r->audio + r->audio_n, s, (size_t)frames * 2 * sizeof(int32_t));
    r->audio_n += frames * 2;
}

static bytes make_video(int nframes, int lines, int blank) {
    bytes v = {0};
    /* Start in the middle of field 2 so the parser has to synchronise. */
    gen_field(&v, -1, 1, lines / 2, 2);
    for (int n = 0; n < nframes; n++) {
        gen_field(&v, n, 0, lines, blank);
        gen_field(&v, n, 1, lines, blank);
    }
    /* trailing field-1 SAV so the last frame is flushed */
    gen_field(&v, nframes, 0, 2, 2);
    return v;
}

/* ---------------------------------------------------------------- tests */

static void test_trc_codes(void) {
    printf("Test: BT.656 TRC-validering\n");
    int valid = 0;
    for (int i = 0; i < 256; i++) if (smi_trc_is_valid((uint8_t)i)) valid++;
    CHECK(valid == 8, "forventet 8 gyldige koder, fikk %d", valid);
    CHECK(smi_trc_is_valid(0x80) && smi_trc_is_valid(0xf1) && !smi_trc_is_valid(0x00), "feil koder");
}

static void run_standard(const char *name, smi_standard std, int lines, bool swap) {
    printf("Test: %s, %d linjer per felt%s\n", name, lines, swap ? ", byttede felt" : "");
    rx r = {0};
    r.swap = swap;
    smi_parser *p = smi_parser_create(std, on_frame, on_audio, &r);
    smi_parser_set_swap_fields(p, swap);
    bytes v = make_video(5, lines, std == SMI_STD_PAL ? 24 : 20);
    int npk = 0;
    long afr = 48000 / 2;
    packet *pk = packetize(&v, afr, &npk, 8);
    for (int i = 0; i < npk; i++) smi_parser_feed_packet(p, pk[i].d, pk[i].len);
    smi_parser_stats st; smi_parser_get_stats(p, &st);
    CHECK(r.frames == 5, "forventet 5 rammer, fikk %d", r.frames);
    CHECK(r.complete == 5, "forventet 5 komplette, fikk %d", r.complete);
    CHECK(r.verified == 5, "pikselinnhold feil (siste ramme %d feil byte)", r.bad_pixels_last);
    CHECK(r.height == (std == SMI_STD_PAL ? 576 : 480), "høyde %d", r.height);
    CHECK(st.trc_invalid == 0, "%llu ugyldige TRC", (unsigned long long)st.trc_invalid);
    CHECK(st.long_lines == 0 && st.short_lines == 0, "linjelengde feil long=%llu short=%llu",
          (unsigned long long)st.long_lines, (unsigned long long)st.short_lines);
    CHECK(st.max_lines_field[0] == (uint32_t)lines, "maks linjer felt 1 = %u", st.max_lines_field[0]);
    printf("  %d rammer, %d verifisert piksel for piksel, %llu videoblokker, %llu lydblokker\n",
           r.frames, r.verified, (unsigned long long)st.video_blocks, (unsigned long long)st.audio_blocks);

    /* audio: compare with generator */
    long frames_rx = r.audio_n / 2;
    long mism = 0;
    for (long i = 0; i < frames_rx; i++)
        for (int ch = 0; ch < 2; ch++)
            if (r.audio[i * 2 + ch] != audio_sample(i, ch)) mism++;
    CHECK(frames_rx > 1000, "for få lydsampler: %ld", frames_rx);
    CHECK(mism == 0, "%ld lydsampler avviker", mism);
    CHECK(st.audio_realign == 0, "uventet lydomjustering %llu", (unsigned long long)st.audio_realign);
    printf("  %ld stereo lydsampler mottatt og verifisert (24-bit i 32-bit LE)\n", frames_rx);

    for (int i = 0; i < npk; i++) free(pk[i].d);
    free(pk); free(v.d); free(r.audio);
    smi_parser_destroy(p);
}

static void test_packet_loss(void) {
    printf("Test: pakketap og resynkronisering\n");
    rx r = {0};
    smi_parser *p = smi_parser_create(SMI_STD_PAL, on_frame, on_audio, &r);
    bytes v = make_video(6, 288, 24);
    int npk = 0;
    packet *pk = packetize(&v, 0, &npk, 0);
    int drop = npk / 2;                /* lose one packet in the middle of frame ~3 */
    for (int i = 0; i < npk; i++) {
        if (i == drop) { smi_parser_discontinuity(p); continue; }
        smi_parser_feed_packet(p, pk[i].d, pk[i].len);
    }
    smi_parser_stats st; smi_parser_get_stats(p, &st);
    CHECK(r.frames == 6, "forventet 6 rammer (én skadet), fikk %d", r.frames);
    CHECK(r.partial == 1, "forventet 1 ufullstendig ramme, fikk %d", r.partial);
    CHECK(r.verified == 5, "forventet 5 verifiserte rammer, fikk %d", r.verified);
    printf("  %d rammer, %d skadet, %d verifisert etter resynk\n", r.frames, r.partial, r.verified);
    for (int i = 0; i < npk; i++) free(pk[i].d);
    free(pk); free(v.d); free(r.audio);
    smi_parser_destroy(p);
}

static void test_audio_realign(void) {
    printf("Test: lydjustering etter tapte byte\n");
    rx r = {0};
    smi_parser *p = smi_parser_create(SMI_STD_PAL, NULL, on_audio, &r);
    bytes a = {0};
    for (long i = 0; i < 4000; i++)
        for (int ch = 0; ch < 2; ch++) {
            uint32_t u = (uint32_t)audio_sample(i, ch);
            push(&a, (uint8_t)u); push(&a, (uint8_t)(u >> 8)); push(&a, (uint8_t)(u >> 16)); push(&a, (uint8_t)(u >> 24));
        }
    /* skip 3 bytes at the start: parser must find the sample boundary */
    size_t pos = 3;
    while (pos + 0x3fc <= a.len) { smi_parser_feed_audio(p, a.d + pos, 0x3fc); pos += 0x3fc; }
    smi_parser_stats st; smi_parser_get_stats(p, &st);
    CHECK(st.audio_realign >= 1, "ingen omjustering registrert");
    /* the received stream should match the generator from sample index 1 (channel may shift) */
    long good = 0;
    for (long i = 0; i + 1 < r.audio_n; i++) {
        long k = i + 1;   /* first full sample starts at byte 4 -> generator index 1 (ch 1) */
        int ch = (int)(k % 2); long idx = k / 2;
        if (r.audio[i] == audio_sample(idx, ch)) good++;
    }
    CHECK(good > r.audio_n * 9 / 10, "kun %ld av %ld sampler korrekt etter justering", good, r.audio_n);
    printf("  omjusteringer: %llu, korrekte sampler: %ld/%ld\n", (unsigned long long)st.audio_realign, good, r.audio_n);
    free(a.d); free(r.audio);
    smi_parser_destroy(p);
}

static void test_deinterlace(void) {
    printf("Test: deinterlacing\n");
    int w = 720, h = 576;
    size_t stride = 1440;
    uint8_t *src = malloc(stride * (size_t)h), *dst = malloc(stride * (size_t)h);
    /* static gradient: both fields agree -> unchanged */
    for (int y = 0; y < h; y++)
        for (int x = 0; x < 1440; x++)
            src[y * stride + x] = (x & 1) ? (uint8_t)(16 + y * 200 / h) : 0x80;
    smi_deinterlace_uyvy(src, stride, dst, stride, w, h, 144);
    CHECK(memcmp(src, dst, stride * (size_t)h) == 0, "statisk bilde ble endret");
    /* moving object: bottom field shows a white bar where top field is black */
    for (int y = 0; y < h; y++)
        for (int x = 0; x < 1440; x++)
            src[y * stride + x] = (x & 1) ? ((y & 1) && x > 200 && x < 400 ? 235 : 16) : 0x80;
    smi_deinterlace_uyvy(src, stride, dst, stride, w, h, 144);
    int combed_left = 0;
    for (int y = 1; y < h - 1; y += 2)
        for (int x = 201; x < 400; x += 2)
            if (dst[y * stride + x] != 16) combed_left++;
    CHECK(combed_left == 0, "%d kamartefakter igjen", combed_left);
    double m, sd;
    smi_uyvy_luma_stats(src, stride, w, h, &m, &sd);
    CHECK(m > 15 && m < 40, "luma-snitt %f", m);
    printf("  statisk bilde uendret, bevegelseskam fjernet\n");
    free(src); free(dst);
}

int main(void) {
    printf("SMI-kjerne enhetstester (syntetiske data, ikke maskinvare)\n\n");
    test_trc_codes();
    run_standard("PAL", SMI_STD_PAL, 288, false);
    run_standard("NTSC", SMI_STD_NTSC, 240, false);
    run_standard("PAL", SMI_STD_PAL, 288, true);
    test_packet_loss();
    test_audio_realign();
    test_deinterlace();
    printf("\n%s (%d feil)\n", failures ? "MISLYKTES" : "ALLE TESTER BESTÅTT", failures);
    return failures ? 1 : 0;
}
