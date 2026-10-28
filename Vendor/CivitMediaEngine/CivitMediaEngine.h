#ifndef CIVIT_MEDIA_ENGINE_H
#define CIVIT_MEDIA_ENGINE_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

/* Local files only. No URLs, shell commands, credentials, or network protocols. */
typedef struct CVMJob CVMJob;
typedef struct {
    int container; /* 1 ISO BMFF, 2 Matroska/WebM, 3 AVI, 0 other */
    int video_codec; /* 1 H264, 2 HEVC, 3 VP9, 4 VP8, 5 MPEG4, 6 MJPEG */
    int width, height, has_audio, hdr;
    double duration, frame_rate;
} CVMInfo;
enum {
    CVM_OK = 0, CVM_CANCELLED = -1, CVM_INPUT = -2,
    CVM_UNSUPPORTED = -3, CVM_OUTPUT = -4, CVM_LIMIT = -5,
    CVM_DECODE = -6, CVM_ENCODE = -7, CVM_DAMAGED = -8,
    CVM_HDR = -9, CVM_TIMING = -10
};
enum { CVM_REMUX = 0, CVM_TRANSCODE = 1 };

CVMJob *cvm_job_create(void);
void cvm_job_cancel(CVMJob *job);
/* Destroy only after probe/run returned; cancellation is thread safe. */
void cvm_job_destroy(CVMJob *job);
/* -1 is indeterminate; otherwise 0...1, completion requires a successful run. */
double cvm_job_progress(const CVMJob *job);
int cvm_probe(CVMJob *job, const char *input_path, CVMInfo *info);
/* Exclusively creates output_path; refuses to overwrite any existing file.
 * A failed/cancelled run removes only that newly created partial output.
 * Remux preserves the selected video/audio bitstreams. Transcode writes SDR
 * H264 via VideoToolbox and AAC audio, preserving audio presence and timing.
 * HDR is remuxable but deliberately not tone mapped by this engine version.
 */
int cvm_convert(CVMJob *job, const char *input_path, const char *output_path,
                int mode, int64_t output_byte_limit);
const char *cvm_engine_version(void);

#ifdef __cplusplus
}
#endif
#endif
