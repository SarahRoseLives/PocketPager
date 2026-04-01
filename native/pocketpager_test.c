/*
 * pocketpager_test.c
 *
 * PocketPager - standalone POCSAG1200 receiver test
 *
 * Pipeline:
 *   RTL-SDR (IQ @ 250 kHz)
 *     → FM quadrature discriminator (float audio @ 250 kHz)
 *     → libsamplerate SRC (float audio @ 22050 Hz)
 *     → multimon-ng decoders (all run in parallel on same audio):
 *         POCSAG512, POCSAG1200, POCSAG2400, FLEX, FLEX_NEXT
 *     → decoded messages on stdout
 *
 * Usage: ./pocketpager_test [frequency_hz]
 *   Default frequency: 439987500 (439.9875 MHz)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <math.h>
#include <stdarg.h>
#include <stdbool.h>
#include <time.h>

#include <rtl-sdr.h>
#include <samplerate.h>

#include "../multimon-ng/multimon.h"

/* ── RTL-SDR settings ──────────────────────────────────────────────────── */

#define DEFAULT_FREQUENCY  439987500u   /* 439.9875 MHz */
#define SAMPLE_RATE        250000u      /* 250 kHz IQ   */
#define AUDIO_RATE         22050u       /* multimon POCSAG1200 expects this */
#define RTL_GAIN_AUTO      0            /* 0 = auto gain, else tenths of dB */
#define RTL_GAIN_MANUAL    300          /* 30.0 dB - good starting point    */
#define RTL_BUF_COUNT      8
#define RTL_BUF_BYTES      (16384 * 2)  /* 16384 IQ pairs per buffer        */

/* Max audio samples per RTL callback: one IQ pair → one audio sample */
#define FM_BUF_SAMPLES     (RTL_BUF_BYTES / 2)

/* Max resampled audio per RTL callback (generous upper bound) */
#define SRC_OUT_SAMPLES    8192

/* ── Globals required by multimon-ng ────────────────────────────────────── */

int json_mode = 0;  /* extern expected by pocsag.c */

/* Minimal _verbprintf: only emit level-0 messages (the decoded output). */
void _verbprintf(int verb_level, const char *fmt, ...)
{
    if (verb_level > 0)
        return;
    va_list args;
    va_start(args, fmt);
    vfprintf(stdout, fmt, args);
    fflush(stdout);
    va_end(args);
}

/* addJsonTimestamp stub - called by pocsag.c in JSON mode (unused here). */
void addJsonTimestamp(cJSON *json_output)
{
    (void)json_output;
}

/* ── Decoder & resampler state ──────────────────────────────────────────── */

/* All pager decoders share the same 22050 Hz audio - run them in parallel. */
static const struct demod_param *demod_modes[] = {
    &demod_poc5,        /* POCSAG512  */
    &demod_poc12,       /* POCSAG1200 */
    &demod_poc24,       /* POCSAG2400 */
    &demod_flex,        /* FLEX       */
    &demod_flex_next,   /* FLEX_NEXT  */
};
#define NUM_DEMODS  (int)(sizeof(demod_modes) / sizeof(demod_modes[0]))

static struct demod_state  dem_st[NUM_DEMODS];
static SRC_STATE          *src_state = NULL;

/* ── FM discriminator state ─────────────────────────────────────────────── */

static float prev_i = 0.0f;
static float prev_q = 0.0f;

/*
 * fm_demod - convert interleaved uint8 IQ → FM discriminator audio
 *
 * RTL-SDR delivers unsigned 8-bit I/Q samples centered at 127.5.
 * The quadrature discriminator computes the instantaneous phase delta:
 *
 *   y[n] = atan2(I[n]*Q[n-1] - Q[n]*I[n-1],
 *                I[n]*I[n-1] + Q[n]*Q[n-1])
 *
 * For POCSAG the demod only tests sign(y[n]), so amplitude doesn't matter.
 */
static void fm_demod(const uint8_t *iq, int n_iq_pairs, float *audio)
{
    for (int i = 0; i < n_iq_pairs; i++) {
        float cur_i = (iq[i * 2]     - 127.5f) * (1.0f / 127.5f);
        float cur_q = (iq[i * 2 + 1] - 127.5f) * (1.0f / 127.5f);

        float cross = cur_i * prev_q - cur_q * prev_i;
        float dot   = cur_i * prev_i + cur_q * prev_q;

        audio[i] = atan2f(cross, dot);

        prev_i = cur_i;
        prev_q = cur_q;
    }
}

/* ── RTL-SDR async callback ─────────────────────────────────────────────── */

static void rtlsdr_cb(unsigned char *buf, uint32_t len, void *ctx)
{
    (void)ctx;

    int n_iq = (int)(len / 2);

    /* FM demodulate IQ → float audio at SAMPLE_RATE */
    static float fm_audio[FM_BUF_SAMPLES];
    fm_demod(buf, n_iq, fm_audio);

    /* Resample SAMPLE_RATE → AUDIO_RATE */
    static float src_out[SRC_OUT_SAMPLES];
    SRC_DATA src_data = {
        .data_in        = fm_audio,
        .data_out       = src_out,
        .input_frames   = n_iq,
        .output_frames  = SRC_OUT_SAMPLES,
        .src_ratio      = (double)AUDIO_RATE / SAMPLE_RATE,
        .end_of_input   = 0,
    };

    int err = src_process(src_state, &src_data);
    if (err) {
        fprintf(stderr, "SRC error: %s\n", src_strerror(err));
        return;
    }

    /* Feed resampled audio to all decoders in parallel */
    if (src_data.output_frames_gen > 0) {
        buffer_t mbuf = { .sbuffer = NULL, .fbuffer = src_out };
        for (int i = 0; i < NUM_DEMODS; i++)
            demod_modes[i]->demod(&dem_st[i], mbuf,
                                  (int)src_data.output_frames_gen);
    }
}

/* ── Signal handling ────────────────────────────────────────────────────── */

static rtlsdr_dev_t *dev = NULL;

static void sighandler(int sig)
{
    (void)sig;
    fprintf(stderr, "\nStopping...\n");
    if (dev)
        rtlsdr_cancel_async(dev);
}

/* ── Entry point ────────────────────────────────────────────────────────── */

int main(int argc, char *argv[])
{
    uint32_t frequency = DEFAULT_FREQUENCY;

    if (argc > 1)
        frequency = (uint32_t)atof(argv[1]);

    printf("PocketPager pager decoder test\n");
    printf("Frequency : %.4f MHz\n", frequency / 1e6);
    printf("IQ rate   : %u Hz\n", SAMPLE_RATE);
    printf("Audio rate: %u Hz\n", AUDIO_RATE);
    printf("Decoders  : POCSAG512, POCSAG1200, POCSAG2400, FLEX, FLEX_NEXT\n");
    printf("----------------------------------------\n");

    /* ── Init all decoders ───────────────────────────────────────────── */
    for (int i = 0; i < NUM_DEMODS; i++) {
        memset(&dem_st[i], 0, sizeof(dem_st[i]));
        dem_st[i].dem_par = demod_modes[i];
        demod_modes[i]->init(&dem_st[i]);
    }

    /* ── Init libsamplerate ──────────────────────────────────────────── */
    int src_err;
    src_state = src_new(SRC_SINC_FASTEST, 1 /* mono */, &src_err);
    if (!src_state) {
        fprintf(stderr, "SRC init failed: %s\n", src_strerror(src_err));
        return 1;
    }

    /* ── Open RTL-SDR device ─────────────────────────────────────────── */
    if (rtlsdr_open(&dev, 0) < 0) {
        fprintf(stderr, "Failed to open RTL-SDR device 0\n");
        return 1;
    }

    /* Manual gain gives better sensitivity than AGC for paging signals */
    rtlsdr_set_tuner_gain_mode(dev, 1);
    rtlsdr_set_tuner_gain(dev, RTL_GAIN_MANUAL);

    rtlsdr_set_center_freq(dev, frequency);
    rtlsdr_set_sample_rate(dev, SAMPLE_RATE);
    rtlsdr_reset_buffer(dev);

    printf("Tuned to  : %.4f MHz (actual)\n",
           rtlsdr_get_center_freq(dev) / 1e6);
    printf("Gain      : %.1f dB\n", rtlsdr_get_tuner_gain(dev) / 10.0);
    printf("\nListening for pager traffic... (Ctrl+C to stop)\n\n");

    signal(SIGINT,  sighandler);
    signal(SIGTERM, sighandler);

    /* Blocking call - returns when rtlsdr_cancel_async() is called */
    rtlsdr_read_async(dev, rtlsdr_cb, NULL, RTL_BUF_COUNT, RTL_BUF_BYTES);

    /* ── Cleanup ─────────────────────────────────────────────────────── */
    for (int i = 0; i < NUM_DEMODS; i++)
        demod_modes[i]->deinit(&dem_st[i]);
    src_delete(src_state);
    rtlsdr_close(dev);

    printf("Done.\n");
    return 0;
}
