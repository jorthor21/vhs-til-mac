/*
 * smi_usb.c – VHS til Mac
 * libusb based user-space driver for the Somagic ezcap Video Grabber
 * (1c88:1001) and other SMI2021 adapters that need no firmware upload.
 *
 * Nothing here requires a kernel extension. Interface 0 of the adapter is
 * vendor specific and has no macOS driver attached, so a normal app can
 * claim it. Interface 1 (a HID "keyboard", the snapshot button) is left
 * alone and stays with macOS.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include "smi_core.h"

#include <libusb.h>

#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define SMI_CORE_VERSION "0.2.0"

#define EP_VIDEO          0x82
#define I2C_DECODER       0x4a
#define REQ_VENDOR        0x01
#define CTRL_TIMEOUT_MS   1000

static const uint16_t k_supported_pids[] = { 0x1001, 0x003c, 0x003d, 0x003e, 0x003f };

struct smi_context {
    libusb_context *usb;
    smi_log_fn log;
    void *user;
};

struct smi_device {
    smi_context *ctx;
    libusb_device_handle *h;
    uint16_t pid;
    int iso_packet_size;
    bool claimed;

    pthread_mutex_t ctrl_lock;
    pthread_mutex_t stats_lock;

    pthread_t thread;
    bool thread_started;
    volatile int stop_flag;
    int pending;
    bool cancelled;

    struct libusb_transfer **xfers;
    uint8_t **bufs;
    int nxfers;

    smi_parser *parser;
    smi_config cfg;
    smi_frame_fn fcb;
    smi_audio_fn acb;
    void *user;
    volatile int swap_request;   /* -1 none, 0/1 new value */

    smi_stream_stats stats;
    struct timespec t_start;

    uint8_t *tap;
    size_t tap_cap;
    size_t tap_len;
};

/* ------------------------------------------------------------- logging */

static smi_context *g_log_ctx;   /* libusb's log callback has no user pointer */

static void logf_(smi_context *ctx, int level, const char *fmt, ...)
#if defined(__GNUC__)
    __attribute__((format(printf, 3, 4)))
#endif
    ;

static void logf_(smi_context *ctx, int level, const char *fmt, ...)
{
    char msg[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof(msg), fmt, ap);
    va_end(ap);
    if (ctx && ctx->log) ctx->log(ctx->user, level, msg);
    else fprintf(stderr, "[smi] %s\n", msg);
}

static void LIBUSB_CALL libusb_log_bridge(libusb_context *c, enum libusb_log_level level, const char *str)
{
    (void)c;
    if (!g_log_ctx || !str) return;
    char tmp[1024];
    snprintf(tmp, sizeof(tmp), "libusb: %s", str);
    size_t n = strlen(tmp);
    while (n && (tmp[n - 1] == '\n' || tmp[n - 1] == '\r')) tmp[--n] = 0;
    int l = level == LIBUSB_LOG_LEVEL_ERROR ? SMI_LOG_ERROR :
            level == LIBUSB_LOG_LEVEL_WARNING ? SMI_LOG_WARN : SMI_LOG_DEBUG;
    logf_(g_log_ctx, l, "%s", tmp);
}

const char *smi_version(void) { return SMI_CORE_VERSION; }

const char *smi_error_name(int code)
{
    switch (code) {
    case SMI_OK: return "OK";
    case SMI_ERR_NOT_FOUND: return "SMI_ERR_NOT_FOUND";
    case SMI_ERR_NO_MEMORY: return "SMI_ERR_NO_MEMORY";
    case SMI_ERR_BAD_DESCRIPTOR: return "SMI_ERR_BAD_DESCRIPTOR";
    case SMI_ERR_ALREADY: return "SMI_ERR_ALREADY";
    case SMI_ERR_NOT_RUNNING: return "SMI_ERR_NOT_RUNNING";
    case SMI_ERR_THREAD: return "SMI_ERR_THREAD";
    case SMI_ERR_CONTROL: return "SMI_ERR_CONTROL";
    case SMI_ERR_ARGUMENT: return "SMI_ERR_ARGUMENT";
    default: return libusb_error_name(code);
    }
}

static double now_seconds(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

/* ------------------------------------------------------------- context */

smi_context *smi_context_create(smi_log_fn log, void *user)
{
    smi_context *ctx = calloc(1, sizeof(*ctx));
    if (!ctx) return NULL;
    ctx->log = log;
    ctx->user = user;
    int r = libusb_init(&ctx->usb);
    if (r < 0) {
        logf_(ctx, SMI_LOG_ERROR, "libusb_init feilet: %s", libusb_error_name(r));
        free(ctx);
        return NULL;
    }
    g_log_ctx = ctx;
    libusb_set_log_cb(ctx->usb, libusb_log_bridge, LIBUSB_LOG_CB_CONTEXT);
    libusb_set_option(ctx->usb, LIBUSB_OPTION_LOG_LEVEL, LIBUSB_LOG_LEVEL_WARNING);
    const struct libusb_version *v = libusb_get_version();
    logf_(ctx, SMI_LOG_INFO, "SMI-kjerne %s, libusb %u.%u.%u", SMI_CORE_VERSION,
          v->major, v->minor, v->micro);
    return ctx;
}

void smi_context_destroy(smi_context *ctx)
{
    if (!ctx) return;
    if (g_log_ctx == ctx) g_log_ctx = NULL;
    libusb_exit(ctx->usb);
    free(ctx);
}

static bool pid_supported(uint16_t pid)
{
    for (size_t i = 0; i < sizeof(k_supported_pids) / sizeof(k_supported_pids[0]); i++)
        if (k_supported_pids[i] == pid) return true;
    return false;
}

/* Find the best device: 1c88:1001 first, then the other known IDs. */
static libusb_device *find_device(smi_context *ctx, smi_presence *pres)
{
    libusb_device **list = NULL;
    libusb_device *best = NULL;
    int best_rank = 1000;
    if (pres) memset(pres, 0, sizeof(*pres));
    ssize_t n = libusb_get_device_list(ctx->usb, &list);
    if (n < 0) return NULL;
    for (ssize_t i = 0; i < n; i++) {
        struct libusb_device_descriptor dd;
        if (libusb_get_device_descriptor(list[i], &dd) != 0) continue;
        if (dd.idVendor != SMI_VENDOR_ID) continue;
        if (pres) pres->somagic_count++;
        int rank = 1000;
        for (size_t k = 0; k < sizeof(k_supported_pids) / sizeof(k_supported_pids[0]); k++)
            if (k_supported_pids[k] == dd.idProduct) rank = (int)k;
        if (rank == 1000) rank = 500;      /* unknown Somagic product */
        if (rank < best_rank) {
            best_rank = rank;
            best = list[i];
            if (pres) {
                pres->found = true;
                pres->vendor_id = dd.idVendor;
                pres->product_id = dd.idProduct;
                pres->bcd_device = dd.bcdDevice;
                pres->bus = libusb_get_bus_number(list[i]);
                pres->address = libusb_get_device_address(list[i]);
                pres->speed = libusb_get_device_speed(list[i]);
            }
        }
    }
    if (best) libusb_ref_device(best);
    libusb_free_device_list(list, 1);
    return best;
}

int smi_find(smi_context *ctx, smi_presence *out)
{
    if (!ctx || !out) return SMI_ERR_ARGUMENT;
    libusb_device *d = find_device(ctx, out);
    if (!d) return SMI_ERR_NOT_FOUND;
    libusb_unref_device(d);
    return SMI_OK;
}

/* ---------------------------------------------------------- diagnostics */

typedef struct { char *buf; size_t cap; size_t len; } sbuf;

static void sb_printf(sbuf *s, const char *fmt, ...)
#if defined(__GNUC__)
    __attribute__((format(printf, 2, 3)))
#endif
    ;

static void sb_printf(sbuf *s, const char *fmt, ...)
{
    if (!s->buf || s->len + 1 >= s->cap) return;
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(s->buf + s->len, s->cap - s->len, fmt, ap);
    va_end(ap);
    if (n > 0) {
        s->len += (size_t)n;
        if (s->len >= s->cap) s->len = s->cap - 1;
    }
}

static const char *speed_name(int speed)
{
    switch (speed) {
    case LIBUSB_SPEED_LOW: return "Low speed (1.5 Mb/s)";
    case LIBUSB_SPEED_FULL: return "Full speed (12 Mb/s)";
    case LIBUSB_SPEED_HIGH: return "High speed (480 Mb/s)";
    case LIBUSB_SPEED_SUPER: return "SuperSpeed (5 Gb/s)";
    case LIBUSB_SPEED_SUPER_PLUS: return "SuperSpeed+ (10 Gb/s)";
    default: return "ukjent";
    }
}

static const char *xfer_type_name(uint8_t attr)
{
    switch (attr & 0x03) {
    case LIBUSB_ENDPOINT_TRANSFER_TYPE_CONTROL: return "control";
    case LIBUSB_ENDPOINT_TRANSFER_TYPE_ISOCHRONOUS: return "isokron";
    case LIBUSB_ENDPOINT_TRANSFER_TYPE_BULK: return "bulk";
    default: return "interrupt";
    }
}

static int ep_effective_size(uint16_t wmax)
{
    return (wmax & 0x07ff) * (1 + ((wmax >> 11) & 0x3));
}

static void describe_one(smi_context *ctx, libusb_device *dev, sbuf *s, bool *matches_smi2021)
{
    struct libusb_device_descriptor dd;
    libusb_get_device_descriptor(dev, &dd);
    sb_printf(s, "Enhet %04x:%04x  (bus %u, adresse %u)\n", dd.idVendor, dd.idProduct,
              libusb_get_bus_number(dev), libusb_get_device_address(dev));
    uint8_t ports[8];
    int np = libusb_get_port_numbers(dev, ports, (int)sizeof(ports));
    if (np > 0) {
        sb_printf(s, "  Portsti: ");
        for (int i = 0; i < np; i++) sb_printf(s, "%s%u", i ? "." : "", ports[i]);
        sb_printf(s, "  (%d nivå%s med hub før Mac-en)\n", np - 1, np - 1 == 1 ? "" : "er");
    }
    sb_printf(s, "  Hastighet: %s\n", speed_name(libusb_get_device_speed(dev)));
    sb_printf(s, "  bcdUSB %x.%02x, bcdDevice %x.%02x, klasse %02x/%02x/%02x, EP0 %u byte, %u konfig.\n",
              dd.bcdUSB >> 8, dd.bcdUSB & 0xff, dd.bcdDevice >> 8, dd.bcdDevice & 0xff,
              dd.bDeviceClass, dd.bDeviceSubClass, dd.bDeviceProtocol, dd.bMaxPacketSize0,
              dd.bNumConfigurations);

    libusb_device_handle *h = NULL;
    int r = libusb_open(dev, &h);
    if (r == 0 && h) {
        unsigned char str[256];
        if (dd.iManufacturer && libusb_get_string_descriptor_ascii(h, dd.iManufacturer, str, sizeof(str)) > 0)
            sb_printf(s, "  Produsent: %s\n", str);
        if (dd.iProduct && libusb_get_string_descriptor_ascii(h, dd.iProduct, str, sizeof(str)) > 0)
            sb_printf(s, "  Produkt:   %s\n", str);
        if (dd.iSerialNumber) sb_printf(s, "  Serienummer: (utelatt fra rapporten)\n");
    } else {
        sb_printf(s, "  (Kunne ikke åpne enheten for strengbeskrivelser: %s)\n", libusb_error_name(r));
    }

    struct libusb_config_descriptor *cfg = NULL;
    r = libusb_get_active_config_descriptor(dev, &cfg);
    if (r != 0) r = libusb_get_config_descriptor(dev, 0, &cfg);
    if (r != 0 || !cfg) {
        sb_printf(s, "  Konfigurasjonsbeskrivelse: FEIL %s\n", libusb_error_name(r));
        if (h) libusb_close(h);
        return;
    }
    sb_printf(s, "  Konfigurasjon %u: %u grensesnitt, wTotalLength %u, attributter 0x%02x, MaxPower %u mA\n",
              cfg->bConfigurationValue, cfg->bNumInterfaces, cfg->wTotalLength,
              cfg->bmAttributes, cfg->MaxPower * 2);

    bool iface0_vendor = false, alt_count_ok = false, alt2_iso82 = false;
    int alt2_size = 0;

    for (int i = 0; i < cfg->bNumInterfaces; i++) {
        const struct libusb_interface *itf = &cfg->interface[i];
        for (int a = 0; a < itf->num_altsetting; a++) {
            const struct libusb_interface_descriptor *id = &itf->altsetting[a];
            const char *cls = id->bInterfaceClass == 0xff ? "leverandørspesifikk" :
                              id->bInterfaceClass == 0x03 ? "HID" :
                              id->bInterfaceClass == 0x01 ? "lyd" :
                              id->bInterfaceClass == 0x0e ? "video (UVC)" : "annen";
            sb_printf(s, "    Grensesnitt %u alt %u: klasse %02x/%02x/%02x (%s), %u endepunkt\n",
                      id->bInterfaceNumber, id->bAlternateSetting, id->bInterfaceClass,
                      id->bInterfaceSubClass, id->bInterfaceProtocol, cls, id->bNumEndpoints);
            if (id->bInterfaceNumber == 0 && id->bInterfaceClass == 0xff) iface0_vendor = true;
            if (id->bInterfaceNumber == 0 && itf->num_altsetting == 3) alt_count_ok = true;
            for (int e = 0; e < id->bNumEndpoints; e++) {
                const struct libusb_endpoint_descriptor *ep = &id->endpoint[e];
                int eff = ep_effective_size(ep->wMaxPacketSize);
                sb_printf(s, "      EP 0x%02x %s %s, wMaxPacketSize 0x%04x (= %d byte per mikroramme), bInterval %u\n",
                          ep->bEndpointAddress, (ep->bEndpointAddress & 0x80) ? "INN" : "UT",
                          xfer_type_name(ep->bmAttributes), ep->wMaxPacketSize, eff, ep->bInterval);
                if (id->bInterfaceNumber == 0 && id->bAlternateSetting == 2 &&
                    ep->bEndpointAddress == EP_VIDEO &&
                    (ep->bmAttributes & 3) == LIBUSB_ENDPOINT_TRANSFER_TYPE_ISOCHRONOUS) {
                    alt2_iso82 = true;
                    alt2_size = eff;
                }
            }
        }
        if (h) {
            int k = libusb_kernel_driver_active(h, i);
            const char *own = k == 1 ? "et systemdriver (macOS) eier grensesnittet" :
                              k == 0 ? "ingen systemdriver – appen kan bruke det" :
                              k == LIBUSB_ERROR_NOT_SUPPORTED ? "ikke støttet å sjekke på denne plattformen" :
                              libusb_error_name(k);
            sb_printf(s, "    -> Grensesnitt %d eierskap: %s\n", i, own);
        }
    }
    libusb_free_config_descriptor(cfg);
    if (h) libusb_close(h);

    bool ok = iface0_vendor && alt_count_ok && alt2_iso82 && alt2_size >= 3072;
    if (matches_smi2021) *matches_smi2021 = ok;
    sb_printf(s, "  Analyse:\n");
    sb_printf(s, "    Grensesnitt 0 leverandørspesifikt ............ %s\n", iface0_vendor ? "JA" : "NEI");
    sb_printf(s, "    Grensesnitt 0 har 3 alternative innstillinger . %s\n", alt_count_ok ? "JA" : "NEI");
    sb_printf(s, "    Alt 2 har isokront EP 0x82 INN ................ %s (%d byte/mikroramme)\n",
              alt2_iso82 ? "JA" : "NEI", alt2_size);
    sb_printf(s, "    => Struktur %s SMI2021-protokollen som appen bruker.\n",
              ok ? "SAMSVARER med" : "AVVIKER fra");
    if (dd.idProduct == 0x0007)
        sb_printf(s, "    MERK: 1c88:0007 er en adapter som trenger firmware-opplasting. Det støttes ikke.\n");
    (void)ctx;
}

int smi_describe(smi_context *ctx, char *buf, size_t buflen)
{
    if (!ctx || !buf || buflen == 0) return SMI_ERR_ARGUMENT;
    sbuf s = { buf, buflen, 0 };
    buf[0] = 0;
    libusb_device **list = NULL;
    ssize_t n = libusb_get_device_list(ctx->usb, &list);
    if (n < 0) {
        sb_printf(&s, "Kunne ikke liste USB-enheter: %s\n", libusb_error_name((int)n));
        return (int)n;
    }
    int found = 0;
    sb_printf(&s, "USB-enheter totalt: %zd (kun Somagic-enheter, VID 1c88, beskrives)\n\n", n);
    for (ssize_t i = 0; i < n; i++) {
        struct libusb_device_descriptor dd;
        if (libusb_get_device_descriptor(list[i], &dd) != 0) continue;
        if (dd.idVendor != SMI_VENDOR_ID) continue;
        found++;
        bool ok = false;
        describe_one(ctx, list[i], &s, &ok);
        sb_printf(&s, "  Produkt-ID støttet av appen: %s\n\n", pid_supported(dd.idProduct) ? "JA" : "NEI (ukjent variant)");
    }
    libusb_free_device_list(list, 1);
    if (!found) {
        sb_printf(&s, "Ingen Somagic-enhet (1c88:xxxx) funnet.\n");
        return SMI_ERR_NOT_FOUND;
    }
    return SMI_OK;
}

int smi_test_access(smi_context *ctx, char *buf, size_t buflen)
{
    if (!ctx || !buf || buflen == 0) return SMI_ERR_ARGUMENT;
    sbuf s = { buf, buflen, strlen(buf) };
    libusb_device *dev = find_device(ctx, NULL);
    if (!dev) { sb_printf(&s, "Tilgangstest: ingen enhet funnet.\n"); return SMI_ERR_NOT_FOUND; }
    libusb_device_handle *h = NULL;
    int r = libusb_open(dev, &h);
    libusb_unref_device(dev);
    if (r != 0) {
        sb_printf(&s, "Tilgangstest: åpne enhet FEILET: %s\n", libusb_error_name(r));
        return r;
    }
    sb_printf(&s, "Tilgangstest: åpne enhet OK\n");
    int c = 0;
    r = libusb_get_configuration(h, &c);
    sb_printf(&s, "Tilgangstest: aktiv konfigurasjon = %d (%s)\n", c, libusb_error_name(r));
    r = libusb_claim_interface(h, 0);
    if (r != 0) {
        sb_printf(&s, "Tilgangstest: gjøre krav på grensesnitt 0 FEILET: %s\n", libusb_error_name(r));
        libusb_close(h);
        return r;
    }
    sb_printf(&s, "Tilgangstest: gjøre krav på grensesnitt 0 OK (ingen kommandoer sendt)\n");
    libusb_release_interface(h, 0);
    libusb_close(h);
    sb_printf(&s, "Tilgangstest: grensesnitt frigitt.\n");
    return SMI_OK;
}

/* ---------------------------------------------------- control transfers */

static int ctrl_out(smi_device *d, uint16_t wvalue, uint8_t *data, uint16_t len)
{
    return libusb_control_transfer(d->h,
        LIBUSB_ENDPOINT_OUT | LIBUSB_REQUEST_TYPE_VENDOR | LIBUSB_RECIPIENT_DEVICE,
        REQ_VENDOR, wvalue, 0, data, len, CTRL_TIMEOUT_MS);
}

static int ctrl_in(smi_device *d, uint16_t wvalue, uint8_t *data, uint16_t len)
{
    return libusb_control_transfer(d->h,
        LIBUSB_ENDPOINT_IN | LIBUSB_REQUEST_TYPE_VENDOR | LIBUSB_RECIPIENT_DEVICE,
        REQ_VENDOR, wvalue, 0, data, len, CTRL_TIMEOUT_MS);
}

/* SMI2021 internal register (16-bit address). */
static int write_smi_reg(smi_device *d, uint16_t reg, uint8_t val)
{
    uint8_t b[8] = { 0x0b, 0x00, 0x00, 0x82, 0x01, (uint8_t)(reg >> 8), (uint8_t)(reg & 0xff), val };
    int r = ctrl_out(d, 0x0b, b, 8);
    if (r != 8) {
        logf_(d->ctx, SMI_LOG_ERROR, "Skriv SMI-register 0x%04x=0x%02x feilet: %s",
              reg, val, r < 0 ? libusb_error_name(r) : "kort overføring");
        return r < 0 ? r : SMI_ERR_CONTROL;
    }
    return SMI_OK;
}

/* Video decoder register over the adapter's I2C bus. */
static int write_i2c(smi_device *d, uint8_t reg, uint8_t val)
{
    uint8_t b[8] = { 0x0b, I2C_DECODER, 0xc0, 0x01, 0x01, reg, val, 0x00 };
    int r = ctrl_out(d, 0x0b, b, 8);
    if (r != 8) {
        logf_(d->ctx, SMI_LOG_ERROR, "Skriv dekoder-register 0x%02x=0x%02x feilet: %s",
              reg, val, r < 0 ? libusb_error_name(r) : "kort overføring");
        return r < 0 ? r : SMI_ERR_CONTROL;
    }
    return SMI_OK;
}

static int read_i2c(smi_device *d, uint8_t reg, uint8_t *val)
{
    uint8_t b[13];
    memset(b, 0, sizeof(b));
    b[0] = 0x0b; b[1] = I2C_DECODER; b[2] = 0x84; b[3] = 0x00; b[4] = 0x01; b[5] = reg;
    int r = ctrl_out(d, 0x0b, b, 13);
    if (r < 0) return r;
    usleep(18 * 1000);
    memset(b, 0, sizeof(b));
    b[0] = 0x0b; b[1] = I2C_DECODER; b[2] = 0xa0; b[3] = 0x00; b[4] = 0x01;
    r = ctrl_out(d, 0x0b, b, 13);
    if (r < 0) return r;
    memset(b, 0xff, sizeof(b));
    r = ctrl_in(d, 0x0b, b, 13);
    if (r < 0) return r;
    if (r < 6) return SMI_ERR_CONTROL;
    *val = b[5];
    return SMI_OK;
}

static int set_mode(smi_device *d, uint8_t mode)
{
    uint8_t b[2] = { 0x01, mode };
    int r = ctrl_out(d, 0x01, b, 2);
    if (r != 2) {
        logf_(d->ctx, SMI_LOG_ERROR, "Sett modus 0x%02x feilet: %s", mode,
              r < 0 ? libusb_error_name(r) : "kort overføring");
        return r < 0 ? r : SMI_ERR_CONTROL;
    }
    return SMI_OK;
}

/* ------------------------------------------------------------ open/close */

void smi_config_default(smi_config *c)
{
    memset(c, 0, sizeof(*c));
    c->standard = SMI_STD_PAL;
    c->input = SMI_INPUT_COMPOSITE;
    c->composite_mode = 0;
    c->enable_audio = true;
    c->brightness = 0x80;
    c->contrast = 0x47;
    c->saturation = 0x40;
    c->hue = 0;
    c->num_transfers = 8;
    c->packets_per_transfer = 64;
    c->alt_setting = 2;
    c->swap_fields = false;
}

int smi_open(smi_context *ctx, smi_device **out)
{
    if (!ctx || !out) return SMI_ERR_ARGUMENT;
    *out = NULL;
    smi_presence pres;
    libusb_device *dev = find_device(ctx, &pres);
    if (!dev) return SMI_ERR_NOT_FOUND;

    if (!pid_supported(pres.product_id)) {
        logf_(ctx, SMI_LOG_WARN, "Somagic-enhet 1c88:%04x er ikke en kjent variant – prøver likevel.",
              pres.product_id);
    }
    if (pres.speed != LIBUSB_SPEED_HIGH && pres.speed != LIBUSB_SPEED_UNKNOWN) {
        logf_(ctx, SMI_LOG_WARN, "Adapteren kjører i %s, ikke USB 2.0 High speed. Video krever High speed.",
              speed_name(pres.speed));
    }

    /* Effective iso packet size of interface 0 / alt 2 / EP 0x82. */
    int iso_size = 0;
    struct libusb_config_descriptor *cfg = NULL;
    if (libusb_get_active_config_descriptor(dev, &cfg) == 0 || libusb_get_config_descriptor(dev, 0, &cfg) == 0) {
        if (cfg->bNumInterfaces > 0) {
            const struct libusb_interface *itf = &cfg->interface[0];
            for (int a = 0; a < itf->num_altsetting; a++) {
                const struct libusb_interface_descriptor *id = &itf->altsetting[a];
                if (id->bAlternateSetting != 2) continue;
                for (int e = 0; e < id->bNumEndpoints; e++)
                    if (id->endpoint[e].bEndpointAddress == EP_VIDEO)
                        iso_size = ep_effective_size(id->endpoint[e].wMaxPacketSize);
            }
        }
        libusb_free_config_descriptor(cfg);
    }
    if (iso_size <= 0) {
        logf_(ctx, SMI_LOG_ERROR, "Fant ikke isokront endepunkt 0x82 i alt 2 – uventet USB-struktur.");
        libusb_unref_device(dev);
        return SMI_ERR_BAD_DESCRIPTOR;
    }

    smi_device *d = calloc(1, sizeof(*d));
    if (!d) { libusb_unref_device(dev); return SMI_ERR_NO_MEMORY; }
    d->ctx = ctx;
    d->pid = pres.product_id;
    d->iso_packet_size = iso_size;
    d->swap_request = -1;
    pthread_mutex_init(&d->ctrl_lock, NULL);
    pthread_mutex_init(&d->stats_lock, NULL);

    int r = libusb_open(dev, &d->h);
    libusb_unref_device(dev);
    if (r != 0) {
        logf_(ctx, SMI_LOG_ERROR, "Kunne ikke åpne USB-enheten: %s", libusb_error_name(r));
        pthread_mutex_destroy(&d->ctrl_lock);
        pthread_mutex_destroy(&d->stats_lock);
        free(d);
        return r;
    }
    /* On Linux a kernel driver may hold interface 0 (e.g. smi2021). On macOS
     * this call is not supported and is ignored. */
    libusb_set_auto_detach_kernel_driver(d->h, 1);

    r = libusb_claim_interface(d->h, 0);
    if (r != 0) {
        logf_(ctx, SMI_LOG_ERROR, "Kunne ikke gjøre krav på USB-grensesnitt 0: %s", libusb_error_name(r));
        libusb_close(d->h);
        pthread_mutex_destroy(&d->ctrl_lock);
        pthread_mutex_destroy(&d->stats_lock);
        free(d);
        return r;
    }
    d->claimed = true;
    r = libusb_set_interface_alt_setting(d->h, 0, 0);
    if (r != 0) logf_(ctx, SMI_LOG_WARN, "Sett alt 0 feilet: %s", libusb_error_name(r));

    logf_(ctx, SMI_LOG_INFO, "Åpnet 1c88:%04x, grensesnitt 0 gjort krav på, isokron pakke %d byte",
          d->pid, d->iso_packet_size);
    *out = d;
    return SMI_OK;
}

void smi_close(smi_device *d)
{
    if (!d) return;
    if (d->thread_started) smi_stop(d);
    if (d->claimed) {
        libusb_set_interface_alt_setting(d->h, 0, 0);
        libusb_release_interface(d->h, 0);
    }
    libusb_close(d->h);
    smi_parser_destroy(d->parser);
    pthread_mutex_destroy(&d->ctrl_lock);
    pthread_mutex_destroy(&d->stats_lock);
    free(d);
}

/* ---------------------------------------------------- decoder programme */

typedef struct { uint8_t reg, val; } regval;

static int decoder_table(const smi_config *c, regval *t, int max)
{
    int n = 0;
#define R(a, b) do { if (n < max) { t[n].reg = (a); t[n].val = (b); n++; } } while (0)
    bool sv = c->input == SMI_INPUT_SVIDEO;
    bool ntsc = c->standard == SMI_STD_NTSC;
    uint8_t mode = sv ? 0x07 : (uint8_t)(c->composite_mode & 0x0f);

    R(0x01, 0x08);                       /* horizontal increment delay */
    R(0x02, (uint8_t)(0xc0 | mode));     /* analog input control 1: input select */
    R(0x03, sv ? 0x31 : 0x33);           /* analog input control 2: AGC */
    R(0x04, 0x00);
    R(0x05, 0x00);
    R(0x06, 0xe9);                       /* horizontal sync start */
    R(0x07, 0x0d);                       /* horizontal sync stop */
    R(0x08, 0x98);                       /* sync control: automatic field detection (50/60 Hz) */
    R(0x09, sv ? 0x81 : 0x01);           /* luminance control (chroma trap bypassed for S-Video) */
    R(0x0a, c->brightness);
    R(0x0b, c->contrast);
    R(0x0c, c->saturation);
    R(0x0d, (uint8_t)c->hue);
    R(0x0e, 0x01);                       /* chroma control: PAL BGHI / NTSC M (auto by field rate) */
    R(0x0f, 0x2a);                       /* chroma gain: automatic */
    R(0x10, 0x48);                       /* V-flag from VREF, VRLN=1 (288/240 active lines) */
    R(0x11, 0x0c);                       /* output control 1: YUV output enabled */
    R(0x12, 0x01);
    R(0x13, sv ? 0x00 : 0x80);
    R(0x15, 0x00);
    R(0x16, 0x00);
    R(0x17, 0x00);
    R(0x40, ntsc ? 0x82 : 0x02);         /* slicer: 60 / 50 Hz field rate */
    if (!sv) {
        for (uint8_t r = 0x41; r <= 0x54; r++) R(r, 0x77);
        R(0x55, 0xff);
    }
    R(0x58, 0x00);
    R(0x59, 0x54);
    R(0x5a, ntsc ? 0x0a : 0x07);         /* vertical offset for 525 / 625 lines */
    R(0x5b, 0x83);
    R(0x5e, 0x00);
#undef R
    return n;
}

static int program_device(smi_device *d, const smi_config *c)
{
    int r;
    uint8_t st[2] = { 0, 0 };
    r = ctrl_in(d, 0x01, st, 2);
    if (r >= 0) logf_(d->ctx, SMI_LOG_INFO, "Statusord fra adapter: %02x %02x (%d byte)", st[0], st[1], r);
    else logf_(d->ctx, SMI_LOG_WARN, "Lese statusord feilet: %s (fortsetter)", libusb_error_name(r));

    /* SMI2021 port setup: releases the reset lines of decoder and audio ADC. */
    static const regval smi_init[] = {
        { 0x3a, 0x80 }, { 0x3b, 0x00 }, { 0x34, 0x01 }, { 0x35, 0x00 },
        { 0x34, 0x11 }, { 0x35, 0x11 }, { 0x3b, 0x80 }, { 0x3b, 0x00 },
    };
    for (size_t i = 0; i < sizeof(smi_init) / sizeof(smi_init[0]); i++) {
        r = write_smi_reg(d, smi_init[i].reg, smi_init[i].val);
        if (r != SMI_OK) { logf_(d->ctx, SMI_LOG_ERROR, "Initialisering stoppet ved SMI-steg %zu", i); return r; }
    }
    logf_(d->ctx, SMI_LOG_INFO, "SMI2021-porter initialisert (8 registre)");

    uint8_t id = 0;
    if (read_i2c(d, 0x00, &id) == SMI_OK)
        logf_(d->ctx, SMI_LOG_INFO, "Dekoder brikkeversjon (reg 0x00) = 0x%02x", id);

    regval tbl[64];
    int n = decoder_table(c, tbl, 64);
    for (int i = 0; i < n; i++) {
        r = write_i2c(d, tbl[i].reg, tbl[i].val);
        if (r != SMI_OK) { logf_(d->ctx, SMI_LOG_ERROR, "Initialisering stoppet ved dekoder-register 0x%02x", tbl[i].reg); return r; }
    }
    /* Windows driver behaviour (smi2021): set CDTO bit of reg 0x0e six times. */
    for (int i = 0; i < 6; i++) write_i2c(d, 0x0e, 0x81);
    logf_(d->ctx, SMI_LOG_INFO, "Videodekoder programmert: %s, %s%s",
          c->standard == SMI_STD_NTSC ? "NTSC" : "PAL",
          c->input == SMI_INPUT_SVIDEO ? "S-Video" : "kompositt",
          c->input == SMI_INPUT_SVIDEO ? "" : (c->composite_mode ? " (alternativ kanal)" : ""));

    /* Audio ADC reset sequence (easycap-somagic). */
    write_smi_reg(d, 0x1740, 0x40);
    write_smi_reg(d, 0x1740, 0x00);
    usleep(250 * 1000);
    write_smi_reg(d, 0x1740, 0x00);
    return SMI_OK;
}

/* ------------------------------------------------------------- streaming */

static void tap_packet(smi_device *d, const uint8_t *data, int len)
{
    if (!d->tap || len <= 0) return;
    size_t need = (size_t)len + 2;
    if (d->tap_len + need > d->tap_cap) return;
    d->tap[d->tap_len] = (uint8_t)(len & 0xff);
    d->tap[d->tap_len + 1] = (uint8_t)((len >> 8) & 0xff);
    memcpy(d->tap + d->tap_len + 2, data, (size_t)len);
    d->tap_len += need;
}

static void LIBUSB_CALL iso_callback(struct libusb_transfer *t)
{
    smi_device *d = t->user_data;
    int swap = d->swap_request;
    if (swap >= 0) { smi_parser_set_swap_fields(d->parser, swap == 1); d->swap_request = -1; }

    uint64_t ok = 0, err = 0, empty = 0, bytes = 0;
    int last_iso = 0;
    bool gone = false, terr = false;

    if (t->status == LIBUSB_TRANSFER_COMPLETED) {
        pthread_mutex_lock(&d->stats_lock);
        for (int i = 0; i < t->num_iso_packets; i++) {
            struct libusb_iso_packet_descriptor *pd = &t->iso_packet_desc[i];
            if (pd->status != LIBUSB_TRANSFER_COMPLETED) {
                err++; last_iso = pd->status;
                smi_parser_discontinuity(d->parser);
                continue;
            }
            if (pd->actual_length == 0) { empty++; continue; }
            const uint8_t *p = libusb_get_iso_packet_buffer_simple(t, (unsigned int)i);
            ok++; bytes += pd->actual_length;
            tap_packet(d, p, (int)pd->actual_length);
        }
        pthread_mutex_unlock(&d->stats_lock);
        /* Parse outside the stats lock: frame callbacks may take a while. */
        for (int i = 0; i < t->num_iso_packets; i++) {
            struct libusb_iso_packet_descriptor *pd = &t->iso_packet_desc[i];
            if (pd->status != LIBUSB_TRANSFER_COMPLETED || pd->actual_length == 0) continue;
            smi_parser_feed_packet(d->parser, libusb_get_iso_packet_buffer_simple(t, (unsigned int)i),
                                   pd->actual_length);
        }
    } else if (t->status == LIBUSB_TRANSFER_NO_DEVICE) {
        gone = true;
    } else if (t->status != LIBUSB_TRANSFER_CANCELLED) {
        terr = true;
        smi_parser_discontinuity(d->parser);
    }

    pthread_mutex_lock(&d->stats_lock);
    d->stats.transfers_completed++;
    d->stats.iso_packets_ok += ok;
    d->stats.iso_packets_error += err;
    d->stats.iso_packets_empty += empty;
    d->stats.bytes_received += bytes;
    if (err) d->stats.last_iso_status = last_iso;
    d->stats.last_transfer_status = t->status;
    if (terr) d->stats.transfer_errors++;
    if (gone) d->stats.device_gone = true;
    smi_parser_get_stats(d->parser, &d->stats.parser);
    pthread_mutex_unlock(&d->stats_lock);

    if (terr && d->stats.transfer_errors < 20)
        logf_(d->ctx, SMI_LOG_WARN, "Isokron overføring feilet med status %d", t->status);

    if (!d->stop_flag && !gone && t->status != LIBUSB_TRANSFER_CANCELLED) {
        int r = libusb_submit_transfer(t);
        if (r == 0) return;
        logf_(d->ctx, SMI_LOG_ERROR, "Ny innsending av isokron overføring feilet: %s", libusb_error_name(r));
        if (r == LIBUSB_ERROR_NO_DEVICE) {
            pthread_mutex_lock(&d->stats_lock);
            d->stats.device_gone = true;
            pthread_mutex_unlock(&d->stats_lock);
        }
    }
    d->pending--;
}

static void *event_thread(void *arg)
{
    smi_device *d = arg;
    double stop_t = 0;
    for (;;) {
        if (d->stop_flag && !d->cancelled) {
            for (int i = 0; i < d->nxfers; i++)
                if (d->xfers[i]) libusb_cancel_transfer(d->xfers[i]);
            d->cancelled = true;
            stop_t = now_seconds();
        }
        if (d->pending <= 0) break;
        if (d->cancelled && now_seconds() - stop_t > 3.0) {
            logf_(d->ctx, SMI_LOG_WARN, "%d overføringer ble ikke avsluttet innen 3 s", d->pending);
            break;
        }
        struct timeval tv = { 0, 100000 };
        libusb_handle_events_timeout_completed(d->ctx->usb, &tv, NULL);
    }
    pthread_mutex_lock(&d->stats_lock);
    d->stats.running = false;
    pthread_mutex_unlock(&d->stats_lock);
    return NULL;
}

static void free_transfers(smi_device *d)
{
    if (d->pending > 0) {
        /* Never free transfers the OS may still write into. */
        logf_(d->ctx, SMI_LOG_WARN, "Lar %d aktive overføringer ligge (frigjøres ikke).", d->pending);
        d->xfers = NULL; d->bufs = NULL; d->nxfers = 0;
        return;
    }
    for (int i = 0; i < d->nxfers; i++) {
        if (d->xfers && d->xfers[i]) libusb_free_transfer(d->xfers[i]);
        if (d->bufs) free(d->bufs[i]);
    }
    free(d->xfers); free(d->bufs);
    d->xfers = NULL; d->bufs = NULL; d->nxfers = 0;
}

int smi_start(smi_device *d, const smi_config *cfg_in, smi_frame_fn fcb, smi_audio_fn acb, void *user)
{
    if (!d) return SMI_ERR_ARGUMENT;
    if (d->thread_started) return SMI_ERR_ALREADY;
    smi_config cfg;
    if (cfg_in) cfg = *cfg_in; else smi_config_default(&cfg);
    if (cfg.num_transfers < 2) cfg.num_transfers = 2;
    if (cfg.num_transfers > 32) cfg.num_transfers = 32;
    if (cfg.packets_per_transfer < 8) cfg.packets_per_transfer = 8;
    cfg.packets_per_transfer = (cfg.packets_per_transfer / 8) * 8;
    if (cfg.alt_setting < 1 || cfg.alt_setting > 2) cfg.alt_setting = 2;
    d->cfg = cfg;
    d->fcb = fcb; d->acb = acb; d->user = user;

    smi_parser_destroy(d->parser);
    d->parser = smi_parser_create(cfg.standard, fcb, acb, user);
    if (!d->parser) return SMI_ERR_NO_MEMORY;
    smi_parser_set_swap_fields(d->parser, cfg.swap_fields);

    pthread_mutex_lock(&d->stats_lock);
    memset(&d->stats, 0, sizeof(d->stats));
    d->tap_len = 0;
    pthread_mutex_unlock(&d->stats_lock);

    pthread_mutex_lock(&d->ctrl_lock);
    int r = libusb_set_interface_alt_setting(d->h, 0, 0);
    if (r != 0) logf_(d->ctx, SMI_LOG_WARN, "Alt 0 før init: %s", libusb_error_name(r));
    r = program_device(d, &cfg);
    if (r != SMI_OK) { pthread_mutex_unlock(&d->ctrl_lock); return r; }

    r = set_mode(d, 0x05);              /* capture mode */
    if (r != SMI_OK) { pthread_mutex_unlock(&d->ctrl_lock); return r; }

    r = libusb_set_interface_alt_setting(d->h, 0, cfg.alt_setting);
    if (r != 0) {
        logf_(d->ctx, SMI_LOG_ERROR, "Kunne ikke velge alt %d (isokron båndbredde): %s",
              cfg.alt_setting, libusb_error_name(r));
        set_mode(d, 0x03);
        pthread_mutex_unlock(&d->ctrl_lock);
        return r;
    }
    logf_(d->ctx, SMI_LOG_INFO, "Alt %d aktivert (isokron strøm på EP 0x82)", cfg.alt_setting);

    write_smi_reg(d, 0x1740, cfg.enable_audio ? 0x1d : 0x00);
    usleep(30 * 1000);

    d->nxfers = cfg.num_transfers;
    d->xfers = calloc((size_t)d->nxfers, sizeof(*d->xfers));
    d->bufs = calloc((size_t)d->nxfers, sizeof(*d->bufs));
    if (!d->xfers || !d->bufs) { pthread_mutex_unlock(&d->ctrl_lock); free_transfers(d); return SMI_ERR_NO_MEMORY; }
    int pkt = d->iso_packet_size;
    int np = cfg.packets_per_transfer;
    d->stop_flag = 0;
    d->cancelled = false;
    d->pending = 0;
    for (int i = 0; i < d->nxfers; i++) {
        d->xfers[i] = libusb_alloc_transfer(np);
        d->bufs[i] = malloc((size_t)pkt * (size_t)np);
        if (!d->xfers[i] || !d->bufs[i]) { r = SMI_ERR_NO_MEMORY; break; }
        libusb_fill_iso_transfer(d->xfers[i], d->h, EP_VIDEO, d->bufs[i], pkt * np, np,
                                 iso_callback, d, 2000);
        libusb_set_iso_packet_lengths(d->xfers[i], (unsigned int)pkt);
    }
    if (r == SMI_ERR_NO_MEMORY) {
        pthread_mutex_unlock(&d->ctrl_lock);
        free_transfers(d);
        return r;
    }
    for (int i = 0; i < d->nxfers; i++) {
        r = libusb_submit_transfer(d->xfers[i]);
        if (r != 0) {
            logf_(d->ctx, SMI_LOG_ERROR, "Innsending av isokron overføring %d feilet: %s", i, libusb_error_name(r));
            break;
        }
        d->pending++;
    }
    if (d->pending == 0) {
        libusb_set_interface_alt_setting(d->h, 0, 0);
        set_mode(d, 0x03);
        pthread_mutex_unlock(&d->ctrl_lock);
        free_transfers(d);
        return r ? r : SMI_ERR_CONTROL;
    }

    r = write_smi_reg(d, 0x1800, 0x0d);   /* start the stream */
    pthread_mutex_unlock(&d->ctrl_lock);

    clock_gettime(CLOCK_MONOTONIC, &d->t_start);
    pthread_mutex_lock(&d->stats_lock);
    d->stats.running = true;
    pthread_mutex_unlock(&d->stats_lock);

    if (pthread_create(&d->thread, NULL, event_thread, d) != 0) {
        d->stop_flag = 1;
        /* drain synchronously */
        for (int i = 0; i < d->nxfers; i++) libusb_cancel_transfer(d->xfers[i]);
        double t0 = now_seconds();
        while (d->pending > 0 && now_seconds() - t0 < 3.0) {
            struct timeval tv = { 0, 100000 };
            libusb_handle_events_timeout_completed(d->ctx->usb, &tv, NULL);
        }
        free_transfers(d);
        return SMI_ERR_THREAD;
    }
    d->thread_started = true;
    logf_(d->ctx, SMI_LOG_INFO, "Strømming startet: %d overføringer x %d pakker x %d byte",
          d->nxfers, np, pkt);
    return SMI_OK;
}

int smi_stop(smi_device *d)
{
    if (!d) return SMI_ERR_ARGUMENT;
    if (!d->thread_started) return SMI_ERR_NOT_RUNNING;
    d->stop_flag = 1;
    pthread_join(d->thread, NULL);
    d->thread_started = false;
    free_transfers(d);

    bool gone;
    pthread_mutex_lock(&d->stats_lock);
    gone = d->stats.device_gone;
    d->stats.running = false;
    pthread_mutex_unlock(&d->stats_lock);

    if (!gone) {
        pthread_mutex_lock(&d->ctrl_lock);
        write_smi_reg(d, 0x1740, 0x00);
        set_mode(d, 0x03);                 /* standby */
        libusb_set_interface_alt_setting(d->h, 0, 0);
        pthread_mutex_unlock(&d->ctrl_lock);
    }
    logf_(d->ctx, SMI_LOG_INFO, "Strømming stoppet%s", gone ? " (adapteren ble koblet fra)" : "");
    return SMI_OK;
}

bool smi_is_running(smi_device *d) { return d && d->thread_started; }

void smi_get_stats(smi_device *d, smi_stream_stats *out)
{
    if (!d || !out) return;
    pthread_mutex_lock(&d->stats_lock);
    *out = d->stats;
    pthread_mutex_unlock(&d->stats_lock);
    if (d->thread_started) {
        struct timespec ts;
        clock_gettime(CLOCK_MONOTONIC, &ts);
        out->seconds_running = (double)(ts.tv_sec - d->t_start.tv_sec) +
                               (double)(ts.tv_nsec - d->t_start.tv_nsec) / 1e9;
    }
}

void smi_set_swap_fields(smi_device *d, bool swap)
{
    if (!d) return;
    d->cfg.swap_fields = swap;
    if (d->thread_started) d->swap_request = swap ? 1 : 0;
    else if (d->parser) smi_parser_set_swap_fields(d->parser, swap);
}

int smi_read_decoder_register(smi_device *d, uint8_t reg, uint8_t *value)
{
    if (!d || !value) return SMI_ERR_ARGUMENT;
    pthread_mutex_lock(&d->ctrl_lock);
    int r = read_i2c(d, reg, value);
    pthread_mutex_unlock(&d->ctrl_lock);
    return r;
}

int smi_read_decoder_status(smi_device *d, uint8_t *status)
{
    return smi_read_decoder_register(d, 0x1f, status);
}

int smi_set_picture(smi_device *d, uint8_t brightness, uint8_t contrast, uint8_t saturation, int8_t hue)
{
    if (!d) return SMI_ERR_ARGUMENT;
    pthread_mutex_lock(&d->ctrl_lock);
    int r = write_i2c(d, 0x0a, brightness);
    if (r == SMI_OK) r = write_i2c(d, 0x0b, contrast);
    if (r == SMI_OK) r = write_i2c(d, 0x0c, saturation);
    if (r == SMI_OK) r = write_i2c(d, 0x0d, (uint8_t)hue);
    pthread_mutex_unlock(&d->ctrl_lock);
    if (r == SMI_OK) {
        d->cfg.brightness = brightness; d->cfg.contrast = contrast;
        d->cfg.saturation = saturation; d->cfg.hue = hue;
    }
    return r;
}

int smi_set_input(smi_device *d, smi_input input, uint8_t composite_mode)
{
    if (!d) return SMI_ERR_ARGUMENT;
    bool sv = input == SMI_INPUT_SVIDEO;
    uint8_t mode = sv ? 0x07 : (uint8_t)(composite_mode & 0x0f);
    pthread_mutex_lock(&d->ctrl_lock);
    int r = write_i2c(d, 0x02, (uint8_t)(0xc0 | mode));
    if (r == SMI_OK) r = write_i2c(d, 0x03, sv ? 0x31 : 0x33);
    if (r == SMI_OK) r = write_i2c(d, 0x09, sv ? 0x81 : 0x01);
    if (r == SMI_OK) r = write_i2c(d, 0x13, sv ? 0x00 : 0x80);
    pthread_mutex_unlock(&d->ctrl_lock);
    if (r == SMI_OK) { d->cfg.input = input; d->cfg.composite_mode = composite_mode; }
    logf_(d->ctx, SMI_LOG_INFO, "Inngang byttet til %s (modus %u): %s", sv ? "S-Video" : "kompositt",
          mode, smi_error_name(r));
    return r;
}

int smi_set_audio_enabled(smi_device *d, bool enabled)
{
    if (!d) return SMI_ERR_ARGUMENT;
    pthread_mutex_lock(&d->ctrl_lock);
    int r = write_smi_reg(d, 0x1740, enabled ? 0x1d : 0x00);
    pthread_mutex_unlock(&d->ctrl_lock);
    if (r == SMI_OK) d->cfg.enable_audio = enabled;
    return r;
}

void smi_set_raw_tap(smi_device *d, uint8_t *buffer, size_t capacity)
{
    if (!d) return;
    pthread_mutex_lock(&d->stats_lock);
    d->tap = buffer;
    d->tap_cap = buffer ? capacity : 0;
    d->tap_len = 0;
    pthread_mutex_unlock(&d->stats_lock);
}

size_t smi_raw_tap_length(smi_device *d)
{
    if (!d) return 0;
    pthread_mutex_lock(&d->stats_lock);
    size_t n = d->tap_len;
    pthread_mutex_unlock(&d->stats_lock);
    return n;
}
