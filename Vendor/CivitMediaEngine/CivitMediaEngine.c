#include "CivitMediaEngine.h"
#include <stdatomic.h>
#include <pthread.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <math.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <errno.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/audio_fifo.h>
#include <libavutil/channel_layout.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>

struct CVMJob { atomic_int cancelled; atomic_int ppm; };
typedef struct { CVMJob *job; int fd; int64_t position, length, limit; int limited; } Writer;
typedef struct {
    AVCodecContext *decoder, *encoder;
    AVStream *input, *output;
    struct SwsContext *scaler;
    SwrContext *resampler;
    AVAudioFifo *fifo;
    AVFrame *video;
    int64_t last_pts, audio_pts;
    int64_t input_audio_next;
    int audio_started;
} Track;
typedef struct {
    CVMJob *job; AVFormatContext *input, *output;
    AVIOContext *io; Writer writer;
    Track video, audio;
    int video_index, audio_index;
    int64_t origin_us;
    double duration;
} Pipeline;

static pthread_once_t setup_once = PTHREAD_ONCE_INIT;
static void no_log(void *context, int level, const char *format, va_list args) { }
static void setup(void) {
    /* FFmpeg may log filenames, including sensitive paths. Never forward it. */
    av_log_set_callback(no_log);
    av_max_alloc(128 * 1024 * 1024);
}
static int cancelled(CVMJob *job) { return !job || atomic_load(&job->cancelled); }
static int interrupt(void *opaque) { return cancelled(opaque); }
CVMJob *cvm_job_create(void) {
    pthread_once(&setup_once, setup);
    CVMJob *job = calloc(1, sizeof(*job));
    if (job) { atomic_init(&job->cancelled, 0); atomic_init(&job->ppm, -1); }
    return job;
}
void cvm_job_cancel(CVMJob *job) { if (job) atomic_store(&job->cancelled, 1); }
void cvm_job_destroy(CVMJob *job) { free(job); }
double cvm_job_progress(const CVMJob *job) { return job ? atomic_load(&job->ppm) / 1000000.0 : -1; }
const char *cvm_engine_version(void) { return "civit-local-repair-v1/" AV_STRINGIFY(LIBAVFORMAT_VERSION_MAJOR); }

static int valid_file(const char *path) {
    struct stat value;
    return path && path[0] == '/' && !strstr(path, "://") &&
        lstat(path, &value) == 0 && S_ISREG(value.st_mode) &&
        value.st_size > 0 && value.st_size <= INT64_C(1073741824);
}
static int open_input(Pipeline *p, const char *path) {
    if (cancelled(p->job)) return CVM_CANCELLED;
    if (!valid_file(path)) return CVM_INPUT;
    p->input = avformat_alloc_context();
    if (!p->input) return CVM_LIMIT;
    p->input->interrupt_callback = (AVIOInterruptCB){ interrupt, p->job };
    p->input->max_streams = 16;
    p->input->probesize = 4 * 1024 * 1024;
    p->input->max_analyze_duration = 5 * AV_TIME_BASE;
    AVDictionary *options = NULL;
    av_dict_set(&options, "protocol_whitelist", "file", 0);
    int status = avformat_open_input(&p->input, path, NULL, &options);
    av_dict_free(&options);
    if (status < 0 || avformat_find_stream_info(p->input, NULL) < 0)
        return cancelled(p->job) ? CVM_CANCELLED : CVM_INPUT;
    p->video_index = av_find_best_stream(p->input, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    p->audio_index = av_find_best_stream(p->input, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (p->video_index < 0) return CVM_UNSUPPORTED;
    AVCodecParameters *v = p->input->streams[p->video_index]->codecpar;
    if (v->width <= 0 || v->height <= 0 || v->width > 4096 || v->height > 4096 ||
        (int64_t)v->width * v->height > 8847360) return CVM_UNSUPPORTED;
    p->duration = p->input->duration > 0 ? (double)p->input->duration / AV_TIME_BASE : 0;
    if (!isfinite(p->duration) || p->duration > 1800) return CVM_UNSUPPORTED;
    p->origin_us = p->input->start_time == AV_NOPTS_VALUE ? 0 : p->input->start_time;
    return CVM_OK;
}
static int codec_kind(enum AVCodecID id) {
    switch (id) {
        case AV_CODEC_ID_H264: return 1; case AV_CODEC_ID_HEVC: return 2;
        case AV_CODEC_ID_VP9: return 3; case AV_CODEC_ID_VP8: return 4;
        case AV_CODEC_ID_MPEG4: return 5; case AV_CODEC_ID_MJPEG: return 6;
        default: return 0;
    }
}
static int is_hdr(const AVCodecParameters *v) {
    return v->color_trc == AVCOL_TRC_SMPTE2084 || v->color_trc == AVCOL_TRC_ARIB_STD_B67;
}
int cvm_probe(CVMJob *job, const char *path, CVMInfo *info) {
    if (!job || !info) return CVM_INPUT;
    memset(info, 0, sizeof(*info));
    Pipeline p = { .job = job, .video_index = -1, .audio_index = -1 };
    int result = open_input(&p, path);
    if (result == CVM_OK) {
        AVStream *v = p.input->streams[p.video_index];
        const char *format = p.input->iformat->name;
        info->container = strstr(format, "mov") ? 1 : (strstr(format, "matroska") ? 2 : (!strcmp(format, "avi") ? 3 : 0));
        info->video_codec = codec_kind(v->codecpar->codec_id);
        info->width = v->codecpar->width; info->height = v->codecpar->height;
        info->has_audio = p.audio_index >= 0; info->hdr = is_hdr(v->codecpar);
        info->duration = p.duration;
        info->frame_rate = av_q2d(av_guess_frame_rate(p.input, v, NULL));
    }
    avformat_close_input(&p.input);
    return result;
}

static int write_bytes(void *opaque, const uint8_t *bytes, int count) {
    Writer *w = opaque;
    if (cancelled(w->job)) return AVERROR_EXIT;
    if (count < 0 || w->position < 0 || count > w->limit - w->position) { w->limited = 1; return AVERROR(ENOSPC); }
    int remaining = count;
    while (remaining > 0) {
        ssize_t value = write(w->fd, bytes + count - remaining, remaining);
        if (value < 0 && errno == EINTR) continue;
        if (value <= 0) return AVERROR(errno ? errno : EIO);
        remaining -= (int)value; w->position += value;
    }
    if (w->position > w->length) w->length = w->position;
    return count;
}
static int64_t seek_output(void *opaque, int64_t offset, int whence) {
    Writer *w = opaque;
    if (cancelled(w->job)) return AVERROR_EXIT;
    if (whence == AVSEEK_SIZE) return w->length;
    whence &= ~AVSEEK_FORCE;
    int64_t target = whence == SEEK_SET ? offset : (whence == SEEK_CUR ? w->position + offset : (whence == SEEK_END ? w->length + offset : -1));
    if (target < 0 || target > w->limit) return AVERROR(EINVAL);
    int64_t result = lseek(w->fd, target, SEEK_SET);
    if (result >= 0) w->position = result;
    return result < 0 ? AVERROR(errno) : result;
}
static int open_output(Pipeline *p, const char *path, int64_t limit) {
    if (!path || path[0] != '/' || strstr(path, "://") || limit < 1024 || limit > INT64_C(1073741824)) return CVM_OUTPUT;
    p->writer = (Writer){ .job = p->job, .fd = -1, .limit = limit };
    p->writer.fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (p->writer.fd < 0) return CVM_OUTPUT;
    if (avformat_alloc_output_context2(&p->output, NULL, "mp4", path) < 0) return CVM_OUTPUT;
    uint8_t *buffer = av_malloc(32768);
    if (!buffer) return CVM_LIMIT;
    p->io = avio_alloc_context(buffer, 32768, 1, &p->writer, NULL, write_bytes, seek_output);
    if (!p->io) { av_free(buffer); return CVM_LIMIT; }
    p->output->pb = p->io; p->output->flags |= AVFMT_FLAG_CUSTOM_IO;
    p->output->avoid_negative_ts = AVFMT_AVOID_NEG_TS_MAKE_NON_NEGATIVE;
    p->output->max_interleave_delta = 2 * AV_TIME_BASE;
    return CVM_OK;
}
static void note_progress(Pipeline *p, AVPacket *packet, AVStream *stream) {
    if (p->duration <= 0 || packet->pts == AV_NOPTS_VALUE) return;
    double seconds = packet->pts * av_q2d(stream->time_base) - (double)p->origin_us / AV_TIME_BASE;
    if (isfinite(seconds) && seconds >= 0) {
        int ppm = (int)(fmin(0.99, seconds / p->duration) * 1000000);
        if (ppm > atomic_load(&p->job->ppm)) atomic_store(&p->job->ppm, ppm);
    }
}
static int copy_track(Pipeline *p, int index, Track *track) {
    track->input = p->input->streams[index];
    track->output = avformat_new_stream(p->output, NULL);
    if (!track->output || avcodec_parameters_copy(track->output->codecpar, track->input->codecpar) < 0) return CVM_OUTPUT;
    track->output->codecpar->codec_tag = 0;
    track->output->time_base = track->input->time_base;
    track->output->disposition = track->input->disposition;
    av_dict_copy(&track->output->metadata, track->input->metadata, 0);
    return CVM_OK;
}
static int remux(Pipeline *p) {
    int result = copy_track(p, p->video_index, &p->video);
    if (result == 0 && p->audio_index >= 0) result = copy_track(p, p->audio_index, &p->audio);
    if (result < 0) return result;
    if (avformat_write_header(p->output, NULL) < 0) return CVM_UNSUPPORTED;
    AVPacket *packet = av_packet_alloc(); if (!packet) return CVM_LIMIT;
    int read_status;
    while (!cancelled(p->job) && (read_status = av_read_frame(p->input, packet)) >= 0) {
        Track *track = packet->stream_index == p->video_index ? &p->video : (packet->stream_index == p->audio_index ? &p->audio : NULL);
        if (track) {
            if (packet->flags & AV_PKT_FLAG_CORRUPT) { result = CVM_DAMAGED; av_packet_unref(packet); break; }
            note_progress(p, packet, track->input);
            int64_t origin = av_rescale_q(p->origin_us, AV_TIME_BASE_Q, track->input->time_base);
            if (packet->pts != AV_NOPTS_VALUE) packet->pts -= origin;
            if (packet->dts != AV_NOPTS_VALUE) packet->dts -= origin;
            av_packet_rescale_ts(packet, track->input->time_base, track->output->time_base);
            packet->stream_index = track->output->index; packet->pos = -1;
            if (av_interleaved_write_frame(p->output, packet) < 0) result = CVM_OUTPUT;
        }
        av_packet_unref(packet); if (result < 0) break;
    }
    av_packet_free(&packet);
    if (cancelled(p->job)) return CVM_CANCELLED;
    if (result < 0) return result;
    if (read_status != AVERROR_EOF) return CVM_DAMAGED;
    return av_write_trailer(p->output) < 0 ? CVM_OUTPUT : CVM_OK;
}

static int open_decoder(Pipeline *p, int index, Track *track) {
    track->input = p->input->streams[index]; track->last_pts = AV_NOPTS_VALUE;
    const AVCodec *codec = avcodec_find_decoder(track->input->codecpar->codec_id);
    if (!codec) return CVM_UNSUPPORTED;
    track->decoder = avcodec_alloc_context3(codec);
    if (!track->decoder || avcodec_parameters_to_context(track->decoder, track->input->codecpar) < 0) return CVM_DECODE;
    track->decoder->thread_count = 2; track->decoder->pkt_timebase = track->input->time_base;
    track->decoder->max_pixels = 8847360;
    if (avcodec_open2(track->decoder, codec, NULL) < 0) return CVM_DECODE;
    return CVM_OK;
}
static int open_video_encoder(Pipeline *p) {
    Track *t = &p->video; AVCodecContext *d = t->decoder;
    if (is_hdr(t->input->codecpar)) return CVM_HDR;
    const AVCodec *codec = avcodec_find_encoder_by_name("h264_videotoolbox");
    if (!codec) return CVM_UNSUPPORTED;
    t->encoder = avcodec_alloc_context3(codec); if (!t->encoder) return CVM_LIMIT;
    AVCodecContext *e = t->encoder;
    e->width = d->width & ~1; e->height = d->height & ~1;
    if (e->width < 2 || e->height < 2) return CVM_UNSUPPORTED;
    e->pix_fmt = AV_PIX_FMT_YUV420P; e->time_base = (AVRational){1, 90000};
    e->framerate = av_guess_frame_rate(p->input, t->input, NULL);
    if (e->framerate.num <= 0 || e->framerate.den <= 0 || av_q2d(e->framerate) > 120) e->framerate = (AVRational){30, 1};
    e->sample_aspect_ratio = d->sample_aspect_ratio;
    e->color_range = d->color_range; e->color_primaries = d->color_primaries;
    e->color_trc = d->color_trc; e->colorspace = d->colorspace;
    e->bit_rate = (int64_t)fmax(800000, fmin(24000000, e->width * (double)e->height * av_q2d(e->framerate) * 0.10));
    e->gop_size = (int)(av_q2d(e->framerate) * 2); e->max_b_frames = 0;
    if (p->output->oformat->flags & AVFMT_GLOBALHEADER) e->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    AVDictionary *options = NULL; av_dict_set(&options, "allow_sw", "1", 0);
    int status = avcodec_open2(e, codec, &options); av_dict_free(&options);
    if (status < 0) return CVM_ENCODE;
    t->output = avformat_new_stream(p->output, NULL);
    if (!t->output || avcodec_parameters_from_context(t->output->codecpar, e) < 0) return CVM_OUTPUT;
    t->output->time_base = e->time_base;
    av_dict_copy(&t->output->metadata, t->input->metadata, 0);
    /* Display rotation is codec parameter side data in current FFmpeg. */
    for (int i = 0; i < t->input->codecpar->nb_coded_side_data; i++) {
        const AVPacketSideData *sd = &t->input->codecpar->coded_side_data[i];
        if (sd->type == AV_PKT_DATA_DISPLAYMATRIX) {
            AVPacketSideData *copy = av_packet_side_data_new(&t->output->codecpar->coded_side_data,
                &t->output->codecpar->nb_coded_side_data, sd->type, sd->size, 0);
            if (!copy) return CVM_LIMIT; memcpy(copy->data, sd->data, sd->size);
        }
    }
    t->video = av_frame_alloc(); if (!t->video) return CVM_LIMIT;
    t->video->format = e->pix_fmt; t->video->width = e->width; t->video->height = e->height;
    return av_frame_get_buffer(t->video, 32) < 0 ? CVM_LIMIT : CVM_OK;
}
static int open_audio_encoder(Pipeline *p) {
    Track *t = &p->audio; AVCodecContext *d = t->decoder;
    if (d->sample_rate <= 0 || d->ch_layout.nb_channels <= 0 || d->ch_layout.nb_channels > 8) return CVM_UNSUPPORTED;
    const AVCodec *codec = avcodec_find_encoder(AV_CODEC_ID_AAC);
    if (!codec) return CVM_UNSUPPORTED;
    t->encoder = avcodec_alloc_context3(codec); if (!t->encoder) return CVM_LIMIT;
    AVCodecContext *e = t->encoder;
    e->sample_rate = d->sample_rate == 44100 ? 44100 : 48000;
    av_channel_layout_default(&e->ch_layout, d->ch_layout.nb_channels == 1 ? 1 : 2);
    e->sample_fmt = AV_SAMPLE_FMT_FLTP; e->bit_rate = e->ch_layout.nb_channels == 1 ? 96000 : 160000;
    e->time_base = (AVRational){1, e->sample_rate};
    if (p->output->oformat->flags & AVFMT_GLOBALHEADER) e->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    if (avcodec_open2(e, codec, NULL) < 0 || e->frame_size <= 0) return CVM_ENCODE;
    t->output = avformat_new_stream(p->output, NULL);
    if (!t->output || avcodec_parameters_from_context(t->output->codecpar, e) < 0) return CVM_OUTPUT;
    t->output->time_base = e->time_base;
    if (swr_alloc_set_opts2(&t->resampler, &e->ch_layout, e->sample_fmt, e->sample_rate,
        &d->ch_layout, d->sample_fmt, d->sample_rate, 0, NULL) < 0 || swr_init(t->resampler) < 0) return CVM_DECODE;
    t->fifo = av_audio_fifo_alloc(e->sample_fmt, e->ch_layout.nb_channels, e->frame_size * 2);
    return t->fifo ? CVM_OK : CVM_LIMIT;
}
static int drain_encoder(Pipeline *p, Track *t) {
    AVPacket *packet = av_packet_alloc(); if (!packet) return CVM_LIMIT;
    int status, result = CVM_OK;
    while ((status = avcodec_receive_packet(t->encoder, packet)) >= 0) {
        if (cancelled(p->job)) { result = CVM_CANCELLED; break; }
        av_packet_rescale_ts(packet, t->encoder->time_base, t->output->time_base);
        packet->stream_index = t->output->index; packet->pos = -1;
        if (av_interleaved_write_frame(p->output, packet) < 0) { result = CVM_OUTPUT; break; }
        av_packet_unref(packet);
    }
    av_packet_free(&packet);
    if (result != CVM_OK) return result;
    return status == AVERROR(EAGAIN) || status == AVERROR_EOF ? CVM_OK : CVM_ENCODE;
}
static int encode(Pipeline *p, Track *t, AVFrame *frame) {
    int status = avcodec_send_frame(t->encoder, frame);
    if (status == AVERROR(EAGAIN)) {
        int result = drain_encoder(p, t); if (result < 0) return result;
        status = avcodec_send_frame(t->encoder, frame);
    }
    if (status < 0 && status != AVERROR_EOF) return CVM_ENCODE;
    return drain_encoder(p, t);
}
static int video_frame(Pipeline *p, AVFrame *input) {
    Track *t = &p->video; AVCodecContext *e = t->encoder;
    if (input->width <= 0 || input->height <= 0 || input->width > 4096 || input->height > 4096 ||
        (int64_t)input->width * input->height > 8847360) return CVM_UNSUPPORTED;
    if (input->color_trc == AVCOL_TRC_SMPTE2084 || input->color_trc == AVCOL_TRC_ARIB_STD_B67) return CVM_HDR;
    t->scaler = sws_getCachedContext(t->scaler, input->width, input->height, input->format,
        e->width, e->height, e->pix_fmt, SWS_BILINEAR, NULL, NULL, NULL);
    if (!t->scaler || av_frame_make_writable(t->video) < 0) return CVM_LIMIT;
    if (sws_scale(t->scaler, (const uint8_t *const *)input->data, input->linesize, 0,
        input->height, t->video->data, t->video->linesize) != e->height) return CVM_DECODE;
    int64_t pts = input->best_effort_timestamp;
    pts = pts == AV_NOPTS_VALUE ? (t->last_pts == AV_NOPTS_VALUE ? 0 : t->last_pts + av_rescale_q(1, av_inv_q(e->framerate), e->time_base)) :
        av_rescale_q(pts, t->input->time_base, e->time_base) - av_rescale_q(p->origin_us, AV_TIME_BASE_Q, e->time_base);
    if (t->last_pts != AV_NOPTS_VALUE && pts <= t->last_pts) return CVM_TIMING;
    t->last_pts = pts; t->video->pts = pts; t->video->pict_type = AV_PICTURE_TYPE_NONE;
    t->video->color_range = e->color_range; t->video->colorspace = e->colorspace;
    t->video->color_primaries = e->color_primaries; t->video->color_trc = e->color_trc;
    return encode(p, t, t->video);
}
static int drain_audio_fifo(Pipeline *p, int final) {
    Track *t = &p->audio; AVCodecContext *e = t->encoder;
    while (av_audio_fifo_size(t->fifo) >= e->frame_size || (final && av_audio_fifo_size(t->fifo) > 0)) {
        if (cancelled(p->job)) return CVM_CANCELLED;
        int count = FFMIN(e->frame_size, av_audio_fifo_size(t->fifo));
        AVFrame *frame = av_frame_alloc(); if (!frame) return CVM_LIMIT;
        frame->nb_samples = count; frame->format = e->sample_fmt; frame->sample_rate = e->sample_rate;
        av_channel_layout_copy(&frame->ch_layout, &e->ch_layout);
        int result = CVM_OK;
        if (av_frame_get_buffer(frame, 0) < 0 || av_audio_fifo_read(t->fifo, (void **)frame->data, count) != count) result = CVM_LIMIT;
        if (result == CVM_OK) { frame->pts = t->audio_pts; t->audio_pts += count; result = encode(p, t, frame); }
        av_frame_free(&frame); if (result < 0) return result;
    }
    return CVM_OK;
}
static int resample_audio(Pipeline *p, AVFrame *input) {
    Track *t = &p->audio; AVCodecContext *e = t->encoder, *d = t->decoder;
    if (input && (input->sample_rate != d->sample_rate || input->format != d->sample_fmt ||
        av_channel_layout_compare(&input->ch_layout, &d->ch_layout))) return CVM_UNSUPPORTED;
    if (input) {
        int64_t pts = input->best_effort_timestamp;
        int64_t sample_pts = pts == AV_NOPTS_VALUE ? AV_NOPTS_VALUE : av_rescale_q(pts, t->input->time_base, (AVRational){1, d->sample_rate});
        if (!t->audio_started) {
            t->audio_started = 1;
            t->input_audio_next = sample_pts == AV_NOPTS_VALUE ? 0 : sample_pts;
            t->audio_pts = pts == AV_NOPTS_VALUE ? 0 : av_rescale_q(pts, t->input->time_base, e->time_base) - av_rescale_q(p->origin_us, AV_TIME_BASE_Q, e->time_base);
        } else if (sample_pts != AV_NOPTS_VALUE) {
            /* Container timestamp rounding is tolerated, timeline gaps are not
             * collapsed. Refuse rather than silently shifting the audio track. */
            int64_t tolerance = FFMAX(2, av_rescale_q_rnd(1, t->input->time_base,
                (AVRational){1, d->sample_rate}, AV_ROUND_UP));
            if (llabs(sample_pts - t->input_audio_next) > tolerance) return CVM_TIMING;
        }
        t->input_audio_next += input->nb_samples;
    }
    int64_t delay = swr_get_delay(t->resampler, d->sample_rate);
    int count = (int)av_rescale_rnd(delay + (input ? input->nb_samples : 0), e->sample_rate, d->sample_rate, AV_ROUND_UP);
    if (count <= 0) return CVM_OK;
    if (count > 65536) return CVM_LIMIT;
    uint8_t **samples = NULL; int linesize;
    if (av_samples_alloc_array_and_samples(&samples, &linesize, e->ch_layout.nb_channels, count, e->sample_fmt, 0) < 0) return CVM_LIMIT;
    int converted = swr_convert(t->resampler, samples, count, input ? (const uint8_t **)input->extended_data : NULL, input ? input->nb_samples : 0);
    int result = CVM_OK;
    if (converted < 0) result = CVM_DECODE;
    else if (av_audio_fifo_realloc(t->fifo, av_audio_fifo_size(t->fifo) + converted) < 0 ||
        av_audio_fifo_write(t->fifo, (void **)samples, converted) != converted) result = CVM_LIMIT;
    av_freep(&samples[0]); av_freep(&samples);
    return result < 0 ? result : drain_audio_fifo(p, 0);
}
static int drain_decoder(Pipeline *p, Track *t, int video) {
    AVFrame *frame = av_frame_alloc(); if (!frame) return CVM_LIMIT;
    int status, result = CVM_OK;
    while ((status = avcodec_receive_frame(t->decoder, frame)) >= 0) {
        if (cancelled(p->job)) { result = CVM_CANCELLED; break; }
        if (frame->flags & AV_FRAME_FLAG_CORRUPT) { result = CVM_DAMAGED; break; }
        result = video ? video_frame(p, frame) : resample_audio(p, frame);
        av_frame_unref(frame); if (result < 0) break;
    }
    av_frame_free(&frame);
    if (result < 0) return result;
    return status == AVERROR(EAGAIN) || status == AVERROR_EOF ? CVM_OK : CVM_DECODE;
}
static int decode(Pipeline *p, Track *t, AVPacket *packet, int video) {
    int status = avcodec_send_packet(t->decoder, packet);
    if (status == AVERROR(EAGAIN)) {
        int result = drain_decoder(p, t, video); if (result < 0) return result;
        status = avcodec_send_packet(t->decoder, packet);
    }
    if (status < 0 && status != AVERROR_EOF) return CVM_DECODE;
    return drain_decoder(p, t, video);
}
static int transcode(Pipeline *p) {
    int result = open_decoder(p, p->video_index, &p->video);
    if (result == 0) result = open_video_encoder(p);
    if (result == 0 && p->audio_index >= 0) result = open_decoder(p, p->audio_index, &p->audio);
    if (result == 0 && p->audio_index >= 0) result = open_audio_encoder(p);
    if (result < 0) return result;
    if (avformat_write_header(p->output, NULL) < 0) return CVM_OUTPUT;
    AVPacket *packet = av_packet_alloc(); if (!packet) return CVM_LIMIT;
    int read_status;
    while (!cancelled(p->job) && (read_status = av_read_frame(p->input, packet)) >= 0) {
        if (packet->flags & AV_PKT_FLAG_CORRUPT) result = CVM_DAMAGED;
        else if (packet->stream_index == p->video_index) { note_progress(p, packet, p->video.input); result = decode(p, &p->video, packet, 1); }
        else if (packet->stream_index == p->audio_index) result = decode(p, &p->audio, packet, 0);
        av_packet_unref(packet); if (result < 0) break;
    }
    av_packet_free(&packet);
    if (cancelled(p->job)) return CVM_CANCELLED;
    if (result < 0) return result;
    if (read_status != AVERROR_EOF) return CVM_DAMAGED;
    result = decode(p, &p->video, NULL, 1);
    if (result == 0 && p->audio_index >= 0) result = decode(p, &p->audio, NULL, 0);
    if (result == 0 && p->audio_index >= 0) result = resample_audio(p, NULL);
    if (result == 0 && p->audio_index >= 0) result = drain_audio_fifo(p, 1);
    if (result == 0) result = encode(p, &p->video, NULL);
    if (result == 0 && p->audio_index >= 0) result = encode(p, &p->audio, NULL);
    if (result < 0) return result;
    return av_write_trailer(p->output) < 0 ? CVM_OUTPUT : CVM_OK;
}
static void free_track(Track *t) {
    avcodec_free_context(&t->decoder); avcodec_free_context(&t->encoder);
    sws_freeContext(t->scaler); swr_free(&t->resampler);
    av_audio_fifo_free(t->fifo); av_frame_free(&t->video);
}
int cvm_convert(CVMJob *job, const char *input, const char *output, int mode, int64_t limit) {
    if (!job || (mode != CVM_REMUX && mode != CVM_TRANSCODE)) return CVM_INPUT;
    Pipeline p = { .job = job, .writer.fd = -1, .video_index = -1, .audio_index = -1 };
    atomic_store(&job->ppm, -1);
    int result = open_input(&p, input);
    if (result == 0) result = open_output(&p, output, limit);
    int owned = p.writer.fd >= 0;
    if (result == 0) result = mode == CVM_REMUX ? remux(&p) : transcode(&p);
    if (p.io) { avio_flush(p.io); if (p.io->error < 0 && result == 0) result = CVM_OUTPUT; }
    if (p.writer.limited) result = CVM_LIMIT;
    if (cancelled(job)) result = CVM_CANCELLED;
    if (p.writer.fd >= 0) { if (result == 0 && fsync(p.writer.fd) != 0) result = CVM_OUTPUT; close(p.writer.fd); }
    free_track(&p.video); free_track(&p.audio);
    if (p.output) { p.output->pb = NULL; avformat_free_context(p.output); }
    if (p.io) { av_freep(&p.io->buffer); avio_context_free(&p.io); }
    avformat_close_input(&p.input);
    if (owned && result != 0) unlink(output);
    if (result == 0) atomic_store(&job->ppm, 1000000);
    return result;
}
