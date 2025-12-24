/**
 * ffmpeg_wrapper.c
 */

#include "include/ffmpeg_wrapper.h"
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_videotoolbox.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <errno.h>

// -----------------------------------------------------------------------------
// Constants
// -----------------------------------------------------------------------------

const int FF_ERROR_EAGAIN = AVERROR(EAGAIN);
const int FF_ERROR_EOF = AVERROR_EOF;

const int FF_PIX_FMT_YUV420P = AV_PIX_FMT_YUV420P;
const int FF_PIX_FMT_NV12 = AV_PIX_FMT_NV12;
const int FF_PIX_FMT_BGRA = AV_PIX_FMT_BGRA;
const int FF_PIX_FMT_RGBA = AV_PIX_FMT_RGBA;
const int FF_PIX_FMT_RGB24 = AV_PIX_FMT_RGB24;
const int FF_PIX_FMT_P010LE = AV_PIX_FMT_P010LE;
const int FF_PIX_FMT_VIDEOTOOLBOX = AV_PIX_FMT_VIDEOTOOLBOX;

const int FF_LOG_QUIET   = AV_LOG_QUIET;
const int FF_LOG_PANIC   = AV_LOG_PANIC;
const int FF_LOG_FATAL   = AV_LOG_FATAL;
const int FF_LOG_ERROR   = AV_LOG_ERROR;
const int FF_LOG_WARNING = AV_LOG_WARNING;
const int FF_LOG_INFO    = AV_LOG_INFO;
const int FF_LOG_VERBOSE = AV_LOG_VERBOSE;
const int FF_LOG_DEBUG   = AV_LOG_DEBUG;

// -----------------------------------------------------------------------------
// Internal structures
// -----------------------------------------------------------------------------

struct FFDemuxContext {
    AVFormatContext *fmt_ctx;
    int video_stream_idx;
    int audio_stream_idx;
};

struct FFDecoderContext {
    AVCodecContext *codec_ctx;
    AVBufferRef *hw_device_ctx;
    bool is_hardware;
    int stream_index;
    AVRational time_base;
};

struct FFScalerContext {
    struct SwsContext *sws_ctx;
    int src_width, src_height, src_format;
    int dst_width, dst_height, dst_format;
};

// -----------------------------------------------------------------------------
// Error handling
// -----------------------------------------------------------------------------

int ff_get_error_string(int errnum, char *buf, size_t buf_size) {
    return av_strerror(errnum, buf, buf_size);
}

// -----------------------------------------------------------------------------
// Logging
// -----------------------------------------------------------------------------

static int log_level = AV_LOG_WARNING;

void ff_set_log_level(int level) {
    log_level = level;
    av_log_set_level(level);
}

int ff_get_log_level(void) {
    return log_level;
}

// -----------------------------------------------------------------------------
// Version info
// -----------------------------------------------------------------------------

const char* ff_get_avcodec_version(void) {
    static char version[32];
    unsigned v = avcodec_version();
    snprintf(version, sizeof(version), "%d.%d.%d",
             (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF);
    return version;
}

const char* ff_get_avformat_version(void) {
    static char version[32];
    unsigned v = avformat_version();
    snprintf(version, sizeof(version), "%d.%d.%d",
             (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF);
    return version;
}

const char* ff_get_avutil_version(void) {
    static char version[32];
    unsigned v = avutil_version();
    snprintf(version, sizeof(version), "%d.%d.%d",
             (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF);
    return version;
}

// -----------------------------------------------------------------------------
// Demuxer
// -----------------------------------------------------------------------------

FFDemuxContext* ff_demux_create(void) {
    FFDemuxContext *ctx = calloc(1, sizeof(FFDemuxContext));
    if (!ctx) return NULL;
    ctx->video_stream_idx = -1;
    ctx->audio_stream_idx = -1;
    return ctx;
}

int ff_demux_open(FFDemuxContext *ctx, const char *url) {
    if (!ctx || !url) return AVERROR(EINVAL);

    int ret = avformat_open_input(&ctx->fmt_ctx, url, NULL, NULL);
    if (ret < 0) return ret;

    ret = avformat_find_stream_info(ctx->fmt_ctx, NULL);
    if (ret < 0) {
        avformat_close_input(&ctx->fmt_ctx);
        return ret;
    }

    ctx->video_stream_idx = av_find_best_stream(ctx->fmt_ctx, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    ctx->audio_stream_idx = av_find_best_stream(ctx->fmt_ctx, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);

    return 0;
}

int ff_demux_get_stream_count(FFDemuxContext *ctx) {
    if (!ctx || !ctx->fmt_ctx) return -1;
    return ctx->fmt_ctx->nb_streams;
}

int ff_demux_get_video_stream_index(FFDemuxContext *ctx) {
    return ctx ? ctx->video_stream_idx : -1;
}

int ff_demux_get_audio_stream_index(FFDemuxContext *ctx) {
    return ctx ? ctx->audio_stream_idx : -1;
}

int ff_demux_get_video_info(FFDemuxContext *ctx,
                            int *width, int *height, int *pixel_format,
                            int *fps_num, int *fps_den) {
    if (!ctx || !ctx->fmt_ctx || ctx->video_stream_idx < 0)
        return AVERROR(EINVAL);

    AVStream *stream = ctx->fmt_ctx->streams[ctx->video_stream_idx];
    AVCodecParameters *codecpar = stream->codecpar;

    if (width) *width = codecpar->width;
    if (height) *height = codecpar->height;
    if (pixel_format) *pixel_format = codecpar->format;

    AVRational fps = stream->avg_frame_rate;
    if (fps.num == 0 || fps.den == 0) fps = stream->r_frame_rate;

    if (fps_num) *fps_num = fps.num;
    if (fps_den) *fps_den = fps.den;

    return 0;
}

double ff_demux_get_duration(FFDemuxContext *ctx) {
    if (!ctx || !ctx->fmt_ctx) return 0.0;
    if (ctx->fmt_ctx->duration != AV_NOPTS_VALUE)
        return (double)ctx->fmt_ctx->duration / AV_TIME_BASE;
    return 0.0;
}

int ff_demux_read_packet(FFDemuxContext *ctx, AVPacket *pkt) {
    if (!ctx || !ctx->fmt_ctx || !pkt) return AVERROR(EINVAL);
    return av_read_frame(ctx->fmt_ctx, pkt);
}

int ff_demux_seek(FFDemuxContext *ctx, double timestamp_seconds) {
    if (!ctx || !ctx->fmt_ctx) return AVERROR(EINVAL);
    int64_t timestamp = (int64_t)(timestamp_seconds * AV_TIME_BASE);
    return av_seek_frame(ctx->fmt_ctx, -1, timestamp, AVSEEK_FLAG_BACKWARD);
}

void ff_demux_destroy(FFDemuxContext *ctx) {
    if (!ctx) return;
    if (ctx->fmt_ctx) avformat_close_input(&ctx->fmt_ctx);
    free(ctx);
}

// -----------------------------------------------------------------------------
// Decoder
// -----------------------------------------------------------------------------

static enum AVPixelFormat get_hw_format(AVCodecContext *ctx,
                                        const enum AVPixelFormat *pix_fmts) {
    (void)ctx;
    for (const enum AVPixelFormat *p = pix_fmts; *p != AV_PIX_FMT_NONE; p++) {
        if (*p == AV_PIX_FMT_VIDEOTOOLBOX) return *p;
    }
    return pix_fmts[0];
}

FFDecoderContext* ff_decoder_create(FFDemuxContext *demux_ctx, int stream_index, bool use_hardware) {
    if (!demux_ctx || !demux_ctx->fmt_ctx) return NULL;
    if (stream_index < 0 || stream_index >= (int)demux_ctx->fmt_ctx->nb_streams) return NULL;

    FFDecoderContext *ctx = calloc(1, sizeof(FFDecoderContext));
    if (!ctx) return NULL;

    AVStream *stream = demux_ctx->fmt_ctx->streams[stream_index];
    AVCodecParameters *codecpar = stream->codecpar;

    const AVCodec *codec = avcodec_find_decoder(codecpar->codec_id);
    if (!codec) { free(ctx); return NULL; }

    ctx->codec_ctx = avcodec_alloc_context3(codec);
    if (!ctx->codec_ctx) { free(ctx); return NULL; }

    if (avcodec_parameters_to_context(ctx->codec_ctx, codecpar) < 0) {
        avcodec_free_context(&ctx->codec_ctx);
        free(ctx);
        return NULL;
    }

    ctx->stream_index = stream_index;
    ctx->time_base = stream->time_base;

    if (use_hardware && codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
        if (av_hwdevice_ctx_create(&ctx->hw_device_ctx, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, NULL, NULL, 0) == 0) {
            ctx->codec_ctx->hw_device_ctx = av_buffer_ref(ctx->hw_device_ctx);
            ctx->codec_ctx->get_format = get_hw_format;
            ctx->is_hardware = true;
        }
    }

    if (avcodec_open2(ctx->codec_ctx, codec, NULL) < 0) {
        if (ctx->hw_device_ctx) av_buffer_unref(&ctx->hw_device_ctx);
        avcodec_free_context(&ctx->codec_ctx);
        free(ctx);
        return NULL;
    }

    return ctx;
}

int ff_decoder_send_packet(FFDecoderContext *ctx, AVPacket *pkt) {
    if (!ctx || !ctx->codec_ctx) return AVERROR(EINVAL);
    return avcodec_send_packet(ctx->codec_ctx, pkt);
}

int ff_decoder_receive_frame(FFDecoderContext *ctx, AVFrame *frame) {
    if (!ctx || !ctx->codec_ctx || !frame) return AVERROR(EINVAL);
    return avcodec_receive_frame(ctx->codec_ctx, frame);
}

void ff_decoder_flush(FFDecoderContext *ctx) {
    if (ctx && ctx->codec_ctx) avcodec_flush_buffers(ctx->codec_ctx);
}

bool ff_decoder_is_hardware(FFDecoderContext *ctx) {
    return ctx ? ctx->is_hardware : false;
}

int ff_decoder_get_pixel_format(FFDecoderContext *ctx) {
    if (!ctx || !ctx->codec_ctx) return AV_PIX_FMT_NONE;
    return ctx->codec_ctx->pix_fmt;
}

void ff_decoder_destroy(FFDecoderContext *ctx) {
    if (!ctx) return;
    if (ctx->codec_ctx) avcodec_free_context(&ctx->codec_ctx);
    if (ctx->hw_device_ctx) av_buffer_unref(&ctx->hw_device_ctx);
    free(ctx);
}

// -----------------------------------------------------------------------------
// Scaler
// -----------------------------------------------------------------------------

FFScalerContext* ff_scaler_create(int src_width, int src_height, int src_format,
                                  int dst_width, int dst_height, int dst_format) {
    FFScalerContext *ctx = calloc(1, sizeof(FFScalerContext));
    if (!ctx) return NULL;

    ctx->src_width = src_width;
    ctx->src_height = src_height;
    ctx->src_format = src_format;
    ctx->dst_width = dst_width;
    ctx->dst_height = dst_height;
    ctx->dst_format = dst_format;

    ctx->sws_ctx = sws_getContext(src_width, src_height, src_format,
                                  dst_width, dst_height, dst_format,
                                  SWS_BILINEAR, NULL, NULL, NULL);
    if (!ctx->sws_ctx) { free(ctx); return NULL; }

    return ctx;
}

int ff_scaler_scale(FFScalerContext *ctx, AVFrame *src_frame, AVFrame *dst_frame) {
    if (!ctx || !ctx->sws_ctx || !src_frame || !dst_frame) return AVERROR(EINVAL);

    int ret = sws_scale(ctx->sws_ctx,
                        (const uint8_t * const *)src_frame->data, src_frame->linesize,
                        0, ctx->src_height,
                        dst_frame->data, dst_frame->linesize);
    return (ret > 0) ? 0 : AVERROR_EXTERNAL;
}

void ff_scaler_destroy(FFScalerContext *ctx) {
    if (!ctx) return;
    if (ctx->sws_ctx) sws_freeContext(ctx->sws_ctx);
    free(ctx);
}

// -----------------------------------------------------------------------------
// Frame utilities
// -----------------------------------------------------------------------------

AVFrame* ff_frame_alloc(void) {
    return av_frame_alloc();
}

int ff_frame_alloc_buffer(AVFrame *frame, int width, int height, int pixel_format) {
    if (!frame) return AVERROR(EINVAL);
    frame->width = width;
    frame->height = height;
    frame->format = pixel_format;
    return av_frame_get_buffer(frame, 0);
}

void ff_frame_free(AVFrame *frame) {
    if (frame) {
        av_frame_unref(frame);
        av_frame_free(&frame);
    }
}

uint8_t* ff_frame_get_data(AVFrame *frame, int plane) {
    if (!frame || plane < 0 || plane >= AV_NUM_DATA_POINTERS) return NULL;
    return frame->data[plane];
}

int ff_frame_get_linesize(AVFrame *frame, int plane) {
    if (!frame || plane < 0 || plane >= AV_NUM_DATA_POINTERS) return 0;
    return frame->linesize[plane];
}

double ff_frame_get_pts_seconds(AVFrame *frame, int time_base_num, int time_base_den) {
    if (!frame || time_base_den == 0) return 0.0;
    if (frame->pts == AV_NOPTS_VALUE) return 0.0;
    return (double)frame->pts * time_base_num / time_base_den;
}

bool ff_frame_is_hardware(AVFrame *frame) {
    return frame && frame->hw_frames_ctx != NULL;
}

int ff_transfer_hw_frame(AVFrame *hw_frame, AVFrame *sw_frame) {
    if (!hw_frame || !sw_frame) return AVERROR(EINVAL);
    return av_hwframe_transfer_data(sw_frame, hw_frame, 0);
}

int ff_get_sw_format(AVFrame *hw_frame) {
    if (!hw_frame || !hw_frame->hw_frames_ctx) return AV_PIX_FMT_NONE;
    AVHWFramesContext *hw_ctx = (AVHWFramesContext *)hw_frame->hw_frames_ctx->data;
    return hw_ctx->sw_format;
}

// -----------------------------------------------------------------------------
// Packet utilities
// -----------------------------------------------------------------------------

AVPacket* ff_packet_alloc(void) {
    return av_packet_alloc();
}

void ff_packet_unref(AVPacket *pkt) {
    if (pkt) av_packet_unref(pkt);
}

void ff_packet_free(AVPacket *pkt) {
    if (pkt) av_packet_free(&pkt);
}

int ff_packet_get_stream_index(AVPacket *pkt) {
    return pkt ? pkt->stream_index : -1;
}

// -----------------------------------------------------------------------------
// Pixel format utilities
// -----------------------------------------------------------------------------

const char* ff_pixel_format_name(int pix_fmt) {
    const char *name = av_get_pix_fmt_name(pix_fmt);
    return name ? name : "unknown";
}

bool ff_pixel_format_is_hardware(int pix_fmt) {
    const AVPixFmtDescriptor *desc = av_pix_fmt_desc_get(pix_fmt);
    return desc && (desc->flags & AV_PIX_FMT_FLAG_HWACCEL);
}
