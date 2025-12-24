/**
 * ffmpeg_wrapper.h
 *
 * C wrapper around FFmpeg for Swift interoperability.
 */

#ifndef FFMPEG_WRAPPER_H
#define FFMPEG_WRAPPER_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

// FFmpeg headers - users must configure include paths
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/pixdesc.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>

#ifdef __cplusplus
extern "C" {
#endif

// -----------------------------------------------------------------------------
// Error handling (platform-independent)
// -----------------------------------------------------------------------------

int ff_get_error_string(int errnum, char *buf, size_t buf_size);

extern const int FF_ERROR_EAGAIN;
extern const int FF_ERROR_EOF;

// -----------------------------------------------------------------------------
// Demuxer
// -----------------------------------------------------------------------------

typedef struct FFDemuxContext FFDemuxContext;

FFDemuxContext* ff_demux_create(void);
int ff_demux_open(FFDemuxContext *ctx, const char *url);
int ff_demux_get_stream_count(FFDemuxContext *ctx);
int ff_demux_get_video_stream_index(FFDemuxContext *ctx);
int ff_demux_get_audio_stream_index(FFDemuxContext *ctx);
int ff_demux_get_video_info(FFDemuxContext *ctx,
                            int *width, int *height, int *pixel_format,
                            int *fps_num, int *fps_den);
double ff_demux_get_duration(FFDemuxContext *ctx);
int ff_demux_read_packet(FFDemuxContext *ctx, AVPacket *pkt);
int ff_demux_seek(FFDemuxContext *ctx, double timestamp_seconds);
void ff_demux_destroy(FFDemuxContext *ctx);

// -----------------------------------------------------------------------------
// Decoder
// -----------------------------------------------------------------------------

typedef struct FFDecoderContext FFDecoderContext;

FFDecoderContext* ff_decoder_create(FFDemuxContext *demux_ctx, int stream_index, bool use_hardware);
int ff_decoder_send_packet(FFDecoderContext *ctx, AVPacket *pkt);
int ff_decoder_receive_frame(FFDecoderContext *ctx, AVFrame *frame);
void ff_decoder_flush(FFDecoderContext *ctx);
bool ff_decoder_is_hardware(FFDecoderContext *ctx);
int ff_decoder_get_pixel_format(FFDecoderContext *ctx);
void ff_decoder_destroy(FFDecoderContext *ctx);

// -----------------------------------------------------------------------------
// Scaler
// -----------------------------------------------------------------------------

typedef struct FFScalerContext FFScalerContext;

FFScalerContext* ff_scaler_create(int src_width, int src_height, int src_format,
                                  int dst_width, int dst_height, int dst_format);
int ff_scaler_scale(FFScalerContext *ctx, AVFrame *src_frame, AVFrame *dst_frame);
void ff_scaler_destroy(FFScalerContext *ctx);

// -----------------------------------------------------------------------------
// Frame utilities
// -----------------------------------------------------------------------------

AVFrame* ff_frame_alloc(void);
int ff_frame_alloc_buffer(AVFrame *frame, int width, int height, int pixel_format);
void ff_frame_free(AVFrame *frame);
uint8_t* ff_frame_get_data(AVFrame *frame, int plane);
int ff_frame_get_linesize(AVFrame *frame, int plane);
double ff_frame_get_pts_seconds(AVFrame *frame, int time_base_num, int time_base_den);
bool ff_frame_is_hardware(AVFrame *frame);
int ff_transfer_hw_frame(AVFrame *hw_frame, AVFrame *sw_frame);
int ff_get_sw_format(AVFrame *hw_frame);

// -----------------------------------------------------------------------------
// Packet utilities
// -----------------------------------------------------------------------------

AVPacket* ff_packet_alloc(void);
void ff_packet_unref(AVPacket *pkt);
void ff_packet_free(AVPacket *pkt);
int ff_packet_get_stream_index(AVPacket *pkt);

// -----------------------------------------------------------------------------
// Pixel format utilities
// -----------------------------------------------------------------------------

const char* ff_pixel_format_name(int pix_fmt);
bool ff_pixel_format_is_hardware(int pix_fmt);

extern const int FF_PIX_FMT_YUV420P;
extern const int FF_PIX_FMT_NV12;
extern const int FF_PIX_FMT_BGRA;
extern const int FF_PIX_FMT_RGBA;
extern const int FF_PIX_FMT_RGB24;
extern const int FF_PIX_FMT_P010LE;
extern const int FF_PIX_FMT_VIDEOTOOLBOX;

// -----------------------------------------------------------------------------
// Logging
// -----------------------------------------------------------------------------

void ff_set_log_level(int level);
int ff_get_log_level(void);

extern const int FF_LOG_QUIET;
extern const int FF_LOG_PANIC;
extern const int FF_LOG_FATAL;
extern const int FF_LOG_ERROR;
extern const int FF_LOG_WARNING;
extern const int FF_LOG_INFO;
extern const int FF_LOG_VERBOSE;
extern const int FF_LOG_DEBUG;

// -----------------------------------------------------------------------------
// Version info
// -----------------------------------------------------------------------------

const char* ff_get_avcodec_version(void);
const char* ff_get_avformat_version(void);
const char* ff_get_avutil_version(void);

#ifdef __cplusplus
}
#endif

#endif // FFMPEG_WRAPPER_H
