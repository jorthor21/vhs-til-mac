/*
 * smi-diag – command line diagnostics for developers (Linux/macOS).
 * Not needed by end users; the app contains the same functions.
 *
 *   smi-diag                 read-only descriptor report
 *   smi-diag --access        + open/claim test (no commands sent)
 *   smi-diag --stream 5      + 5 s capture test, writes snapshot.ppm / raw.bin
 *   options: --ntsc --svideo --mode N --no-audio
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include "smi_core.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static uint8_t *g_snapshot;
static int g_w, g_h;
static long g_audio;

static void logcb(void *u, int level, const char *msg) {
    (void)u;
    static const char *n[] = { "DEBUG", "INFO", "ADVARSEL", "FEIL" };
    fprintf(stderr, "[%s] %s\n", n[level & 3], msg);
}

static void on_frame(void *u, const smi_frame_info *f) {
    (void)u;
    if (!g_snapshot) g_snapshot = malloc((size_t)f->stride * (size_t)f->height);
    memcpy(g_snapshot, f->data, (size_t)f->stride * (size_t)f->height);
    g_w = f->width; g_h = f->height;
}

static void on_audio(void *u, const int32_t *s, int n) { (void)u; (void)s; g_audio += n; }

static void write_ppm(const char *path) {
    FILE *f = fopen(path, "wb");
    if (!f) return;
    fprintf(f, "P6\n%d %d\n255\n", g_w, g_h);
    for (int y = 0; y < g_h; y++) {
        const uint8_t *r = g_snapshot + (size_t)y * 1440;
        for (int x = 0; x < g_w; x += 2) {
            int u = r[x * 2] - 128, y0 = r[x * 2 + 1] - 16, v = r[x * 2 + 2] - 128, y1 = r[x * 2 + 3] - 16;
            for (int k = 0; k < 2; k++) {
                int yy = k ? y1 : y0;
                int R = (298 * yy + 409 * v + 128) >> 8;
                int G = (298 * yy - 100 * u - 208 * v + 128) >> 8;
                int B = (298 * yy + 516 * u + 128) >> 8;
                fputc(R < 0 ? 0 : R > 255 ? 255 : R, f);
                fputc(G < 0 ? 0 : G > 255 ? 255 : G, f);
                fputc(B < 0 ? 0 : B > 255 ? 255 : B, f);
            }
        }
    }
    fclose(f);
}

int main(int argc, char **argv) {
    int stream_s = 0, access = 0;
    smi_config cfg;
    smi_config_default(&cfg);
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--access")) access = 1;
        else if (!strcmp(argv[i], "--stream") && i + 1 < argc) { stream_s = atoi(argv[++i]); access = 1; }
        else if (!strcmp(argv[i], "--ntsc")) cfg.standard = SMI_STD_NTSC;
        else if (!strcmp(argv[i], "--svideo")) cfg.input = SMI_INPUT_SVIDEO;
        else if (!strcmp(argv[i], "--mode") && i + 1 < argc) cfg.composite_mode = (uint8_t)atoi(argv[++i]);
        else if (!strcmp(argv[i], "--no-audio")) cfg.enable_audio = false;
        else { fprintf(stderr, "Ukjent valg %s\n", argv[i]); return 2; }
    }
    smi_context *ctx = smi_context_create(logcb, NULL);
    if (!ctx) return 1;
    static char report[65536];
    int r = smi_describe(ctx, report, sizeof(report));
    fputs(report, stdout);
    if (r != SMI_OK) { smi_context_destroy(ctx); return 1; }
    if (access) {
        report[0] = 0;
        smi_test_access(ctx, report, sizeof(report));
        fputs(report, stdout);
    }
    if (stream_s > 0) {
        smi_device *dev = NULL;
        r = smi_open(ctx, &dev);
        if (r != SMI_OK) { printf("Åpning feilet: %s\n", smi_error_name(r)); smi_context_destroy(ctx); return 1; }
        size_t cap = 8u << 20;
        uint8_t *tap = malloc(cap);
        smi_set_raw_tap(dev, tap, cap);
        r = smi_start(dev, &cfg, on_frame, on_audio, NULL);
        if (r != SMI_OK) { printf("Start feilet: %s\n", smi_error_name(r)); smi_close(dev); smi_context_destroy(ctx); return 1; }
        for (int s = 0; s < stream_s; s++) {
            sleep(1);
            smi_stream_stats st; smi_get_stats(dev, &st);
            uint8_t status = 0;
            int sr = smi_read_decoder_status(dev, &status);
            printf("t=%2ds  %.2f MB  pakker ok %llu feil %llu tomme %llu  video %llu lyd %llu ukjent %llu  "
                   "rammer %llu (+%llu delvise)  linjer %u/%u  status 0x%02x%s\n",
                   s + 1, st.bytes_received / 1e6,
                   (unsigned long long)st.iso_packets_ok, (unsigned long long)st.iso_packets_error,
                   (unsigned long long)st.iso_packets_empty,
                   (unsigned long long)st.parser.video_blocks, (unsigned long long)st.parser.audio_blocks,
                   (unsigned long long)st.parser.unknown_blocks,
                   (unsigned long long)st.parser.frames_complete, (unsigned long long)st.parser.frames_partial,
                   st.parser.last_lines_field[0], st.parser.last_lines_field[1], status,
                   sr != SMI_OK ? " (lesefeil)" : (status & 0x40) ? " INGEN SIGNAL" : " signal låst");
        }
        smi_stop(dev);
        size_t tl = smi_raw_tap_length(dev);
        FILE *f = fopen("raw.bin", "wb");
        if (f) { fwrite(tap, 1, tl, f); fclose(f); }
        if (g_snapshot) { write_ppm("snapshot.ppm"); printf("Lagret snapshot.ppm (%dx%d)\n", g_w, g_h); }
        printf("Lagret raw.bin (%zu byte), lydsampler: %ld\n", tl, g_audio);
        smi_close(dev);
        free(tap);
    }
    smi_context_destroy(ctx);
    return 0;
}
