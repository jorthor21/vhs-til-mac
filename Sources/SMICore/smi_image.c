/*
 * smi_image.c – VHS til Mac
 * Deinterlacing and simple image statistics for UYVY 4:2:2 frames.
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include "smi_core.h"

#include <math.h>
#include <string.h>

/*
 * Comb-detecting ("motion adaptive") deinterlacer.
 * Rows of the top field (even rows) are kept unchanged. For every pixel pair
 * (one UYVY macropixel) of a bottom-field row we compare the luma with the
 * rows above and below. If the pixel lies clearly outside the range spanned
 * by its vertical neighbours ((c-a)*(c-b) > threshold) the two fields
 * disagree there (motion) and the macropixel is replaced by the vertical
 * average of the neighbours. Static areas keep full vertical resolution.
 */
void smi_deinterlace_uyvy(const uint8_t *src, size_t src_stride,
                          uint8_t *dst, size_t dst_stride,
                          int width, int height, int threshold)
{
    const size_t row_bytes = (size_t)width * 2;
    for (int y = 0; y < height; y++) {
        const uint8_t *c = src + (size_t)y * src_stride;
        uint8_t *o = dst + (size_t)y * dst_stride;
        if ((y & 1) == 0 || y == height - 1) {
            memcpy(o, c, row_bytes);
            continue;
        }
        const uint8_t *a = c - src_stride;
        const uint8_t *b = c + src_stride;
        for (size_t x = 0; x < row_bytes; x += 4) {
            int comb = 0;
            for (int k = 1; k < 4; k += 2) {           /* the two Y samples */
                int ca = (int)c[x + k] - (int)a[x + k];
                int cb = (int)c[x + k] - (int)b[x + k];
                if (ca * cb > threshold) { comb = 1; break; }
            }
            if (comb) {
                o[x + 0] = (uint8_t)(((int)a[x + 0] + (int)b[x + 0] + 1) >> 1);
                o[x + 1] = (uint8_t)(((int)a[x + 1] + (int)b[x + 1] + 1) >> 1);
                o[x + 2] = (uint8_t)(((int)a[x + 2] + (int)b[x + 2] + 1) >> 1);
                o[x + 3] = (uint8_t)(((int)a[x + 3] + (int)b[x + 3] + 1) >> 1);
            } else {
                memcpy(o + x, c + x, 4);
            }
        }
    }
}

void smi_uyvy_luma_stats(const uint8_t *src, size_t stride, int width, int height,
                         double *mean, double *stddev)
{
    double sum = 0, sum2 = 0;
    size_t n = 0;
    for (int y = 0; y < height; y += 2) {
        const uint8_t *r = src + (size_t)y * stride;
        for (int x = 1; x < width * 2; x += 8) {
            double v = r[x];
            sum += v; sum2 += v * v; n++;
        }
    }
    if (n == 0) { if (mean) *mean = 0; if (stddev) *stddev = 0; return; }
    double m = sum / (double)n;
    double var = sum2 / (double)n - m * m;
    if (mean) *mean = m;
    if (stddev) *stddev = var > 0 ? sqrt(var) : 0;
}
