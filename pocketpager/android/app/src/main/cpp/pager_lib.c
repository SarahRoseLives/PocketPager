/*
 * pager_lib.c  –  PocketPager native decoder library for Android
 *
 * Pipeline (runs on a background pthread):
 *   RTL-SDR IQ (uint8, 250 kHz, via rtlsdr_open2 USB fd)
 *     → FM quadrature discriminator  → float audio @ 250 kHz
 *     → linear-interpolation SRC     → float audio @ 22050 Hz
 *     → multimon-ng decoders (all parallel):
 *           POCSAG512, POCSAG1200, POCSAG2400, FLEX, FLEX_NEXT
 *     → pager_cb_t callback into Dart via NativeCallable.listener()
 *
 * Exported API (Dart FFI):
 *
 *   int32_t pager_open (int32_t fd, const char *device_path,
 *                       uint32_t frequency_hz, int32_t gain_tenths_db)
 *   int32_t pager_start(pager_cb_t callback)
 *   void    pager_stop (void)
 *   void    pager_free (void *ptr)   // free a malloc'd message string
 *
 * Callback (called from decode thread – safe with NativeCallable.listener):
 *   void cb(int32_t protocol_id,   // 0=POCSAG512 1=POCSAG1200 2=POCSAG2400
 *                                  // 3=FLEX 4=FLEX_NEXT
 *           uint32_t address,
 *           int32_t  function,     // POCSAG function 0-3, or FLEX capcode
 *           char    *message,      // malloc'd UTF-8; Dart must call pager_free
 *           int64_t  timestamp_ms)
 */

#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <math.h>
#include <time.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdbool.h>
#include <android/log.h>

#include "rtl-sdr.h"
#include "rtl-sdr-android.h"

/* multimon-ng headers & sources are compiled into this library via CMake */
#include "multimon.h"

#define LOG_TAG "PocketPager"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

/* ── RTL-SDR / audio parameters ────────────────────────────────────────── */

#define SAMPLE_RATE     250000u     /* IQ sample rate from RTL-SDR          */
#define AUDIO_RATE      22050u      /* multimon-ng expects this             */
#define RTL_BUF_COUNT   8
#define RTL_BUF_BYTES   (16384 * 2) /* 16384 IQ pairs per callback buffer   */
#define FM_BUF_SAMPLES  (RTL_BUF_BYTES / 2)

/* SRC output upper bound per callback (250000/22050 ≈ 11.34, so 1450 out
   per 16384 in; 4096 is very generous)                                     */
#define SRC_OUT_MAX     4096

/* ── Globals required by multimon-ng ────────────────────────────────────── */

int json_mode = 0;

void addJsonTimestamp(cJSON *json_output) { (void)json_output; }

/* ── Pager decoders table ───────────────────────────────────────────────── */

static const struct demod_param *demod_modes[] = {
    &demod_poc5,        /* POCSAG512  → protocol_id 0 */
    &demod_poc12,       /* POCSAG1200 → protocol_id 1 */
    &demod_poc24,       /* POCSAG2400 → protocol_id 2 */
    &demod_flex,        /* FLEX       → protocol_id 3 */
    &demod_flex_next,   /* FLEX_NEXT  → protocol_id 4 */
};
#define NUM_DEMODS 5

/* ── Callback type ──────────────────────────────────────────────────────── */

typedef void (*pager_cb_t)(int32_t protocol_id,
                            uint32_t address,
                            int32_t  function,
                            char    *message,
                            int64_t  timestamp_ms);

/* ── Library state ──────────────────────────────────────────────────────── */

static rtlsdr_dev_t    *g_dev      = NULL;
static volatile int     g_running  = 0;
static pthread_t        g_thread;
static pager_cb_t       g_callback = NULL;

static struct demod_state g_dem[NUM_DEMODS];

/* ── FM discriminator state ─────────────────────────────────────────────── */

static float g_prev_i = 0.0f;
static float g_prev_q = 0.0f;

static void fm_demod(const uint8_t *iq, int n_pairs, float *audio)
{
    for (int i = 0; i < n_pairs; i++) {
        float ci = (iq[i * 2]     - 127.5f) * (1.0f / 127.5f);
        float cq = (iq[i * 2 + 1] - 127.5f) * (1.0f / 127.5f);
        float cross = ci * g_prev_q - cq * g_prev_i;
        float dot   = ci * g_prev_i + cq * g_prev_q;
        audio[i]    = atan2f(cross, dot);
        g_prev_i = ci;
        g_prev_q = cq;
    }
}

/* ── Linear-interpolation sample-rate converter ─────────────────────────── *
 *
 * Converts SAMPLE_RATE → AUDIO_RATE using linear interpolation.
 * State: fractional read position within the input buffer.
 *
 * For sign-only decoders (POCSAG, FLEX) this quality is more than sufficient.
 */

static double g_src_phase = 0.0;  /* fractional position in input */

static int src_convert(const float *in, int n_in, float *out, int out_max)
{
    const double ratio = (double)AUDIO_RATE / SAMPLE_RATE; /* ≈ 0.08820 */
    int n_out = 0;

    while (n_out < out_max) {
        int   idx = (int)g_src_phase;
        if (idx + 1 >= n_in) break;
        float frac = (float)(g_src_phase - idx);
        out[n_out++] = in[idx] + frac * (in[idx + 1] - in[idx]);
        g_src_phase += 1.0 / ratio;
    }

    /* Carry over remaining fractional position for next call */
    int consumed = (int)g_src_phase;
    if (consumed > n_in) consumed = n_in;
    g_src_phase -= consumed;

    return n_out;
}

/* ── Pending message capture ────────────────────────────────────────────── *
 *
 * multimon-ng outputs decoded messages by calling _verbprintf(0, ...).
 * We intercept this to capture the output and fire the callback.
 *
 * Each _verbprintf(0,...) call appends to a line buffer.  When a newline
 * is seen we parse the completed line and invoke g_callback.
 *
 * Line format examples (from multimon-ng):
 *   "POCSAG1200: Address:  123456  Function: 3  Alpha:   Hello World\n"
 *   "POCSAG512: Address:  123456  Function: 0 \n"
 *   "FLEX: ..."
 */

/* Override _verbprintf so we can intercept decoded output.
 * The definition above (that logs to Android) is replaced here. */

static char   g_line[2048];
static size_t g_line_len = 0;

static int64_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void dispatch_line(const char *line)
{
    if (!g_callback) return;

    /* Identify protocol */
    int proto = -1;
    if      (strncmp(line, "POCSAG512:",  10) == 0) proto = 0;
    else if (strncmp(line, "POCSAG1200:", 11) == 0) proto = 1;
    else if (strncmp(line, "POCSAG2400:", 11) == 0) proto = 2;
    else if (strncmp(line, "FLEX:",        5) == 0) proto = 3;
    else if (strncmp(line, "FLEX_NEXT:",  10) == 0) proto = 4;
    else return;

    /* Parse address */
    const char *addr_p = strstr(line, "Address:");
    uint32_t address = 0;
    if (addr_p) address = (uint32_t)strtoul(addr_p + 8, NULL, 10);

    /* Parse function */
    const char *func_p = strstr(line, "Function:");
    int32_t function = -1;
    if (func_p) function = (int32_t)strtol(func_p + 9, NULL, 10);

    /* Extract message text (Alpha / Numeric / Skyper / FLEX payload) */
    const char *msg_start = NULL;
    const char *markers[] = { "Alpha:   ", "Numeric: ", "Skyper:  ", NULL };
    for (int i = 0; markers[i]; i++) {
        const char *p = strstr(line, markers[i]);
        if (p) { msg_start = p + strlen(markers[i]); break; }
    }

    /* FLEX messages come in various formats; fall back to rest of line */
    if (!msg_start && proto >= 3) {
        const char *colon = strchr(line, ':');
        if (colon) msg_start = colon + 2;
    }

    char *message = msg_start ? strdup(msg_start) : strdup("");

    /* Strip trailing whitespace/newlines from message */
    if (message) {
        size_t len = strlen(message);
        while (len > 0 && (message[len-1] == '\n' || message[len-1] == '\r' ||
                            message[len-1] == ' '))
            message[--len] = '\0';
    }

    g_callback(proto, address, function, message, now_ms());
}

void _verbprintf(int verb_level, const char *fmt, ...)
{
    va_list args;
    va_start(args, fmt);
    if (verb_level == 0) {
        /* Append to line buffer */
        int written = vsnprintf(g_line + g_line_len,
                                sizeof(g_line) - g_line_len, fmt, args);
        if (written > 0) g_line_len += (size_t)written;

        /* Dispatch complete lines */
        char *nl;
        while ((nl = memchr(g_line, '\n', g_line_len)) != NULL) {
            *nl = '\0';
            dispatch_line(g_line);
            size_t rest = g_line_len - (size_t)(nl + 1 - g_line);
            memmove(g_line, nl + 1, rest);
            g_line_len = rest;
        }

        /* Guard against buffer overflow */
        if (g_line_len >= sizeof(g_line) - 1) g_line_len = 0;
    }
    va_end(args);
}

/* ── Decode thread ──────────────────────────────────────────────────────── */

static void *decode_thread(void *arg)
{
    (void)arg;

    static uint8_t iq_buf[RTL_BUF_BYTES];
    static float   fm_buf[FM_BUF_SAMPLES];
    static float   audio_buf[SRC_OUT_MAX];

    while (g_running) {
        int n_read = 0;
        int r = rtlsdr_read_sync(g_dev, iq_buf, RTL_BUF_BYTES, &n_read);
        if (r < 0 || n_read <= 0) {
            LOGE("rtlsdr_read_sync error %d (read %d)", r, n_read);
            break;
        }

        int n_iq = n_read / 2;
        fm_demod(iq_buf, n_iq, fm_buf);

        int n_audio = src_convert(fm_buf, n_iq, audio_buf, SRC_OUT_MAX);
        if (n_audio <= 0) continue;

        buffer_t mbuf = { .sbuffer = NULL, .fbuffer = audio_buf };
        for (int i = 0; i < NUM_DEMODS; i++)
            demod_modes[i]->demod(&g_dem[i], mbuf, n_audio);
    }
    return NULL;
}

/* ── Public API ─────────────────────────────────────────────────────────── */

int32_t pager_open(int32_t fd, const char *device_path,
                   uint32_t frequency_hz, int32_t gain_tenths_db)
{
    if (g_dev) { rtlsdr_close(g_dev); g_dev = NULL; }

    if (rtlsdr_open2(&g_dev, (int)fd, device_path) != 0) {
        LOGE("rtlsdr_open2 failed");
        return -1;
    }

    rtlsdr_set_sample_rate(g_dev, SAMPLE_RATE);
    rtlsdr_set_center_freq(g_dev, frequency_hz);

    if (gain_tenths_db <= 0) {
        rtlsdr_set_tuner_gain_mode(g_dev, 0);   /* auto */
        rtlsdr_set_agc_mode(g_dev, 1);
    } else {
        rtlsdr_set_tuner_gain_mode(g_dev, 1);
        rtlsdr_set_tuner_gain(g_dev, gain_tenths_db);
        rtlsdr_set_agc_mode(g_dev, 0);
    }
    rtlsdr_reset_buffer(g_dev);

    /* Init decoders */
    for (int i = 0; i < NUM_DEMODS; i++) {
        memset(&g_dem[i], 0, sizeof(g_dem[i]));
        g_dem[i].dem_par = demod_modes[i];
        demod_modes[i]->init(&g_dem[i]);
    }

    g_prev_i = g_prev_q = 0.0f;
    g_src_phase = 0.0;
    g_line_len  = 0;

    LOGI("Opened RTL-SDR: freq=%u Hz, rate=%u, gain=%d",
         rtlsdr_get_center_freq(g_dev),
         rtlsdr_get_sample_rate(g_dev),
         rtlsdr_get_tuner_gain(g_dev));
    return 0;
}

int32_t pager_start(pager_cb_t callback)
{
    if (!g_dev || g_running) return -1;
    g_callback = callback;
    g_running  = 1;
    if (pthread_create(&g_thread, NULL, decode_thread, NULL) != 0) {
        g_running = 0;
        LOGE("pthread_create failed");
        return -1;
    }
    LOGI("Decode thread started");
    return 0;
}

void pager_stop(void)
{
    if (!g_running) return;
    g_running = 0;
    if (g_dev) rtlsdr_reset_buffer(g_dev); /* unblock read_sync */
    pthread_join(g_thread, NULL);
    for (int i = 0; i < NUM_DEMODS; i++)
        demod_modes[i]->deinit(&g_dem[i]);
    if (g_dev) { rtlsdr_close(g_dev); g_dev = NULL; }
    g_callback = NULL;
    LOGI("Decode thread stopped");
}

void pager_free(void *ptr)
{
    free(ptr);
}
