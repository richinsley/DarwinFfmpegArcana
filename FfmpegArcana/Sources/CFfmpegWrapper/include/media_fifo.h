/**
 * media_fifo.h
 * 
 * C API for media FIFOs - Swift-compatible header.
 * The C++ implementation is internal to media_fifo.cpp.
 */

#ifndef MEDIA_FIFO_H
#define MEDIA_FIFO_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/frame.h>

// -----------------------------------------------------------------------------
// Opaque types for C interface
// -----------------------------------------------------------------------------

typedef struct FFFrameFifo FFFrameFifo;
typedef struct FFPacketFifo FFPacketFifo;

// -----------------------------------------------------------------------------
// FIFO mode
// -----------------------------------------------------------------------------

typedef enum {
    FF_FIFO_MODE_LOCKLESS = 0,  // Single producer/consumer, fastest
    FF_FIFO_MODE_BLOCKING = 1   // Multi producer/consumer safe
} FFifoMode;

// -----------------------------------------------------------------------------
// Result codes
// -----------------------------------------------------------------------------

#define FF_FIFO_OK              0
#define FF_FIFO_INVALID_PARAMS  1
#define FF_FIFO_FLOW_DISABLED   13
#define FF_FIFO_FULL            29
#define FF_FIFO_TIMEOUT         -1

// -----------------------------------------------------------------------------
// Frame FIFO - stores AVFrame*
// -----------------------------------------------------------------------------

FFFrameFifo* ff_frame_fifo_create(unsigned int capacity, FFifoMode mode);
void ff_frame_fifo_destroy(FFFrameFifo* fifo);

// Flow control
void ff_frame_fifo_set_flow_enabled(FFFrameFifo* fifo, bool enabled);
bool ff_frame_fifo_get_flow_enabled(FFFrameFifo* fifo);

// Write operations - caller retains ownership, fifo makes a ref
int ff_frame_fifo_wait_write(FFFrameFifo* fifo);
int ff_frame_fifo_wait_write_timed(FFFrameFifo* fifo, int msecs);
int ff_frame_fifo_try_write(FFFrameFifo* fifo);
int ff_frame_fifo_write(FFFrameFifo* fifo, AVFrame* frame);

// Read operations - caller receives a ref, must unref when done
int ff_frame_fifo_wait_read(FFFrameFifo* fifo);
int ff_frame_fifo_wait_read_timed(FFFrameFifo* fifo, int msecs);
int ff_frame_fifo_try_read(FFFrameFifo* fifo);
int ff_frame_fifo_read(FFFrameFifo* fifo, AVFrame** frame);

// Preempt - push to front of queue
int ff_frame_fifo_preempt(FFFrameFifo* fifo, AVFrame* frame);

// Status
int ff_frame_fifo_count(FFFrameFifo* fifo);
bool ff_frame_fifo_has_been_read(FFFrameFifo* fifo);

// -----------------------------------------------------------------------------
// Packet FIFO - stores AVPacket*
// -----------------------------------------------------------------------------

FFPacketFifo* ff_packet_fifo_create(unsigned int capacity, FFifoMode mode);
void ff_packet_fifo_destroy(FFPacketFifo* fifo);

// Flow control
void ff_packet_fifo_set_flow_enabled(FFPacketFifo* fifo, bool enabled);
bool ff_packet_fifo_get_flow_enabled(FFPacketFifo* fifo);

// Write operations - caller retains ownership, fifo makes a ref
int ff_packet_fifo_wait_write(FFPacketFifo* fifo);
int ff_packet_fifo_wait_write_timed(FFPacketFifo* fifo, int msecs);
int ff_packet_fifo_try_write(FFPacketFifo* fifo);
int ff_packet_fifo_write(FFPacketFifo* fifo, AVPacket* packet);

// Read operations - caller receives a ref, must unref when done
int ff_packet_fifo_wait_read(FFPacketFifo* fifo);
int ff_packet_fifo_wait_read_timed(FFPacketFifo* fifo, int msecs);
int ff_packet_fifo_try_read(FFPacketFifo* fifo);
int ff_packet_fifo_read(FFPacketFifo* fifo, AVPacket** packet);

// Preempt - push to front of queue
int ff_packet_fifo_preempt(FFPacketFifo* fifo, AVPacket* packet);

// Status
int ff_packet_fifo_count(FFPacketFifo* fifo);
bool ff_packet_fifo_has_been_read(FFPacketFifo* fifo);

#ifdef __cplusplus
}
#endif

#endif // MEDIA_FIFO_H