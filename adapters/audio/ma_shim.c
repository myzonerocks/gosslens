// A small mixer over miniaudio for lens audio playback. Sounds decode once
// into cached s16 PCM (no device, no clock: MA_NO_DEVICE_IO); each play adds
// a voice the pull mixes and advances. Deterministic - the same play/pull
// sequence yields the same PCM, so a triggered sound is conformance-stable.
#define MA_NO_DEVICE_IO
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

// miniaudio decodes on the C heap, invisible to the Zig leak gate; a counting
// allocator over the decoder and the cached PCM makes a leaked sound show as
// live bytes the vendor-heap proof reads across a lifecycle. A 16-byte header
// records each block's size for the free and realloc paths.
static _Atomic size_t g_ma_live_bytes = 0;

typedef struct { size_t size; size_t pad; } MaHeader;

static void *goss_ma_malloc(size_t size, void *user) {
    (void)user;
    MaHeader *h = (MaHeader *)malloc(size + sizeof(MaHeader));
    if (!h) return NULL;
    h->size = size;
    atomic_fetch_add(&g_ma_live_bytes, size);
    return h + 1;
}

static void goss_ma_free(void *ptr, void *user) {
    (void)user;
    if (!ptr) return;
    MaHeader *h = (MaHeader *)ptr - 1;
    atomic_fetch_sub(&g_ma_live_bytes, h->size);
    free(h);
}

static void *goss_ma_realloc(void *ptr, size_t size, void *user) {
    if (!ptr) return goss_ma_malloc(size, user);
    if (size == 0) { goss_ma_free(ptr, user); return NULL; }
    MaHeader *h = (MaHeader *)ptr - 1;
    size_t old = h->size;
    MaHeader *n = (MaHeader *)realloc(h, size + sizeof(MaHeader));
    if (!n) return NULL;
    n->size = size;
    atomic_fetch_add(&g_ma_live_bytes, size);
    atomic_fetch_sub(&g_ma_live_bytes, old);
    return n + 1;
}

static const ma_allocation_callbacks goss_ma_allocs = {
    .pUserData = NULL,
    .onMalloc = goss_ma_malloc,
    .onRealloc = goss_ma_realloc,
    .onFree = goss_ma_free,
};

// Live bytes on the miniaudio heap right now, read by the vendor-heap proof.
size_t goss_ma_live_bytes(void) { return atomic_load(&g_ma_live_bytes); }

#define GOSS_MAX_SOUNDS 32
#define GOSS_MAX_VOICES 32

typedef struct { short *pcm; ma_uint64 frames; } Sound;
// fade_in and fade_out are frame counts for a linear ramp up from the start and
// down into the end; zero means a hard start or stop. A looping voice ignores
// fade_out. lgain/rgain are the equal-power left/right pan gains, applied only
// when the mixer is stereo.
typedef struct { int sound; ma_uint64 cursor; int loop; float gain; ma_uint64 fade_in; ma_uint64 fade_out; float lgain; float rgain; int active; } Voice;

typedef struct GossMixer {
    int sample_rate;
    int channels;
    int sound_count;
    Sound sounds[GOSS_MAX_SOUNDS];
    Voice voices[GOSS_MAX_VOICES];
} GossMixer;

GossMixer *goss_mixer_create(int sample_rate, int channels);
void goss_mixer_destroy(GossMixer *m);
void goss_mixer_unload(GossMixer *m, int sound_id);
int goss_mixer_load(GossMixer *m, const char *path, size_t path_len);
int goss_mixer_load_memory(GossMixer *m, const void *data, size_t size);
void goss_mixer_play(GossMixer *m, int sound_id, int loop, float gain);
void goss_mixer_play_fade(GossMixer *m, int sound_id, int loop, float gain, ma_uint64 fade_in, ma_uint64 fade_out);
void goss_mixer_play_pan(GossMixer *m, int sound_id, int loop, float gain, ma_uint64 fade_in, ma_uint64 fade_out, float pan);
int goss_mixer_active_voices(const GossMixer *m);
void goss_mixer_pull(GossMixer *m, short *out, int frames);

// Shared: decode an already-initialized ma_decoder fully into a cached
// sound, returning its id or -1.
static int goss_mixer_take(GossMixer *m, ma_decoder *dec) {
    ma_uint64 total = 0;
    ma_decoder_get_length_in_pcm_frames(dec, &total);
    if (total == 0) { ma_decoder_uninit(dec); return -1; }
    short *pcm = (short *)goss_ma_malloc((size_t)total * m->channels * sizeof(short), NULL);
    if (!pcm) { ma_decoder_uninit(dec); return -1; }
    ma_uint64 got = 0;
    ma_decoder_read_pcm_frames(dec, pcm, total, &got);
    ma_decoder_uninit(dec);
    // A truncated or undecodable file can read zero frames while reporting a
    // length; registering it would loop a voice over uninitialized PCM. Refuse.
    if (got == 0) { goss_ma_free(pcm, NULL); return -1; }
    int id = m->sound_count++;
    m->sounds[id].pcm = pcm;
    m->sounds[id].frames = got;
    return id;
}

GossMixer *goss_mixer_create(int sample_rate, int channels) {
    GossMixer *m = (GossMixer *)calloc(1, sizeof(GossMixer));
    if (!m) return NULL;
    m->sample_rate = sample_rate;
    m->channels = channels;
    return m;
}

void goss_mixer_destroy(GossMixer *m) {
    if (!m) return;
    for (int i = 0; i < m->sound_count; i++) {
        if (m->sounds[i].pcm) goss_ma_free(m->sounds[i].pcm, NULL);
    }
    free(m);
}

// Decodes a sound file into cached PCM at the mixer's rate and channels,
// returning its id, or -1 on failure or when the sound table is full.
int goss_mixer_load(GossMixer *m, const char *path, size_t path_len) {
    if (!m || m->sound_count >= GOSS_MAX_SOUNDS) return -1;
    char pbuf[1024];
    if (path_len >= sizeof(pbuf)) return -1;
    memcpy(pbuf, path, path_len);
    pbuf[path_len] = '\0';

    ma_decoder_config cfg = ma_decoder_config_init(ma_format_s16, m->channels, m->sample_rate);
    cfg.allocationCallbacks = goss_ma_allocs;
    ma_decoder dec;
    if (ma_decoder_init_file(pbuf, &cfg, &dec) != MA_SUCCESS) return -1;
    return goss_mixer_take(m, &dec);
}

int goss_mixer_load_memory(GossMixer *m, const void *data, size_t size) {
    if (!m || m->sound_count >= GOSS_MAX_SOUNDS) return -1;
    ma_decoder_config cfg = ma_decoder_config_init(ma_format_s16, m->channels, m->sample_rate);
    cfg.allocationCallbacks = goss_ma_allocs;
    ma_decoder dec;
    if (ma_decoder_init_memory(data, size, &cfg, &dec) != MA_SUCCESS) return -1;
    return goss_mixer_take(m, &dec);
}

// Releases one cached sound: every voice playing it stops, its PCM frees,
// and the slot empties (ids stay stable; play refuses an emptied slot). This
// is what lets a per-utterance loader (the dub voice) replace its previous
// sound instead of exhausting the table.
void goss_mixer_unload(GossMixer *m, int sound_id) {
    if (!m || sound_id < 0 || sound_id >= m->sound_count) return;
    if (!m->sounds[sound_id].pcm) return;
    for (int i = 0; i < GOSS_MAX_VOICES; i++) {
        if (m->voices[i].active && m->voices[i].sound == sound_id) m->voices[i].active = 0;
    }
    goss_ma_free(m->sounds[sound_id].pcm, NULL);
    m->sounds[sound_id].pcm = NULL;
    m->sounds[sound_id].frames = 0;
}

// Clamps a scaled float sample into the s16 range as a long, rejecting NaN
// by construction so the float-to-integer cast can never be undefined.
static long clamp_sample(float f) {
    if (!(f > -32768.0f)) return -32768;
    if (f > 32767.0f) return 32767;
    return (long)f;
}

void goss_mixer_play_pan(GossMixer *m, int sound_id, int loop, float gain, ma_uint64 fade_in, ma_uint64 fade_out, float pan) {
    if (!m || sound_id < 0 || sound_id >= m->sound_count) return;
    if (!m->sounds[sound_id].pcm) return;
    // A non-finite gain would make the per-sample cast undefined; a silent
    // voice is the safe reading of a broken value.
    if (!isfinite(gain)) gain = 0.0f;
    if (!isfinite(pan)) pan = 0.0f;
    if (pan < -1.0f) pan = -1.0f;
    if (pan > 1.0f) pan = 1.0f;
    // Equal-power pan: left full at -1, right full at +1, both at 0.707 centred,
    // so a swept source holds constant loudness across the stereo field. The
    // constant is a quarter turn in radians.
    float angle = (pan + 1.0f) * 0.7853981633974483f;
    for (int i = 0; i < GOSS_MAX_VOICES; i++) {
        if (!m->voices[i].active) {
            m->voices[i].sound = sound_id;
            m->voices[i].cursor = 0;
            m->voices[i].loop = loop;
            m->voices[i].gain = gain;
            m->voices[i].fade_in = fade_in;
            m->voices[i].fade_out = fade_out;
            m->voices[i].lgain = cosf(angle);
            m->voices[i].rgain = sinf(angle);
            m->voices[i].active = 1;
            return;
        }
    }
}

void goss_mixer_play_fade(GossMixer *m, int sound_id, int loop, float gain, ma_uint64 fade_in, ma_uint64 fade_out) {
    goss_mixer_play_pan(m, sound_id, loop, gain, fade_in, fade_out, 0.0f);
}

void goss_mixer_play(GossMixer *m, int sound_id, int loop, float gain) {
    goss_mixer_play_pan(m, sound_id, loop, gain, 0, 0, 0.0f);
}

int goss_mixer_active_voices(const GossMixer *m) {
    if (!m) return 0;
    int n = 0;
    for (int i = 0; i < GOSS_MAX_VOICES; i++) n += m->voices[i].active;
    return n;
}

// Mixes every active voice into out (frames * channels, s16), advancing each
// by frames. A non-looping voice deactivates when it reaches its end.
void goss_mixer_pull(GossMixer *m, short *out, int frames) {
    int ch = m ? m->channels : 1;
    memset(out, 0, (size_t)frames * ch * sizeof(short));
    if (!m) return;
    for (int v = 0; v < GOSS_MAX_VOICES; v++) {
        Voice *vo = &m->voices[v];
        if (!vo->active) continue;
        Sound *s = &m->sounds[vo->sound];
        for (int f = 0; f < frames; f++) {
            if (vo->cursor >= s->frames) {
                if (vo->loop) vo->cursor = 0;
                else { vo->active = 0; break; }
            }
            // Linear fade envelope: ramp up over the first fade_in frames and,
            // for a one-shot, down over the last fade_out frames.
            float env = 1.0f;
            if (vo->fade_in > 0 && vo->cursor < vo->fade_in)
                env = (float)vo->cursor / (float)vo->fade_in;
            if (!vo->loop && vo->fade_out > 0 && vo->cursor + vo->fade_out >= s->frames) {
                float fo = (float)(s->frames - vo->cursor) / (float)vo->fade_out;
                if (fo < env) env = fo;
            }
            for (int c = 0; c < ch; c++) {
                // Pan only splits a stereo bus; a mono pull plays every voice centred.
                float chan = (ch == 2) ? (c == 0 ? vo->lgain : vo->rgain) : 1.0f;
                long mixed = out[f * ch + c] + clamp_sample((float)s->pcm[vo->cursor * ch + c] * vo->gain * env * chan);
                if (mixed > 32767) mixed = 32767;
                if (mixed < -32768) mixed = -32768;
                out[f * ch + c] = (short)mixed;
            }
            vo->cursor++;
            // A one-shot voice retires the instant it plays its last sample,
            // so it is inactive immediately, not on the next pull.
            if (!vo->loop && vo->cursor >= s->frames) { vo->active = 0; break; }
        }
    }
}
