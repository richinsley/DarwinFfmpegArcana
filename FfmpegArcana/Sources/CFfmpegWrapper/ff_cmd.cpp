/**
 * ff_cmd.cpp
 * 
 * Implementation of pooled command structures and command FIFO.
 */

#include "include/ff_cmd.h"
#include "fifo/bound_fifo_impl.hpp"
#include "fifo/default_semaphore_impl.hpp"

extern "C" {
    #include <libavcodec/avcodec.h>
    #include <libavformat/avformat.h>
    #include <libavutil/frame.h>
}

#include <atomic>
#include <mutex>
#include <cstdlib>
#include <cstring>

// -----------------------------------------------------------------------------
// Command ref counting implementation
// -----------------------------------------------------------------------------

static int32_t cmd_addref(void* self) {
    FFCmd* cmd = static_cast<FFCmd*>(self);
    if (!cmd) return 0;
    return __sync_add_and_fetch(&cmd->_refcount, 1);
}

static int32_t cmd_release(void* self) {
    FFCmd* cmd = static_cast<FFCmd*>(self);
    if (!cmd) return 0;
    
    int32_t count = __sync_sub_and_fetch(&cmd->_refcount, 1);
    if (count == 0) {
        // Clear any data with ref counting
        ff_cmd_clear_data(cmd);
        
        // Return to pool
        if (cmd->_pool) {
            // Pool will handle putting it back on free list
            extern void ff_cmd_pool_return(FFCmdPool* pool, FFCmd* cmd);
            ff_cmd_pool_return(cmd->_pool, cmd);
        }
    }
    return count;
}

static IFFRefCounted cmd_ref_vtable = {
    .AddRef = cmd_addref,
    .Release = cmd_release
};

// -----------------------------------------------------------------------------
// AVFrame ref counting adapter
// -----------------------------------------------------------------------------

static int32_t frame_addref(void* self) {
    AVFrame* frame = static_cast<AVFrame*>(self);
    if (!frame) return 0;
    
    // Create a new reference
    AVFrame* ref = av_frame_clone(frame);
    if (ref) {
        // This is a bit weird - we can't actually track refcount externally
        // The frame itself tracks refs internally
        return 1;
    }
    return 0;
}

static int32_t frame_release(void* self) {
    AVFrame* frame = static_cast<AVFrame*>(self);
    if (!frame) return 0;
    
    av_frame_free(&frame);
    return 0;
}

static IFFRefCounted frame_ref_vtable = {
    .AddRef = frame_addref,
    .Release = frame_release
};

IFFRefCounted* ff_frame_ref_interface(void) {
    return &frame_ref_vtable;
}

// -----------------------------------------------------------------------------
// AVPacket ref counting adapter
// -----------------------------------------------------------------------------

static int32_t packet_addref(void* self) {
    AVPacket* packet = static_cast<AVPacket*>(self);
    if (!packet) return 0;
    
    AVPacket* ref = av_packet_clone(packet);
    if (ref) {
        return 1;
    }
    return 0;
}

static int32_t packet_release(void* self) {
    AVPacket* packet = static_cast<AVPacket*>(self);
    if (!packet) return 0;
    
    av_packet_free(&packet);
    return 0;
}

static IFFRefCounted packet_ref_vtable = {
    .AddRef = packet_addref,
    .Release = packet_release
};

IFFRefCounted* ff_packet_ref_interface(void) {
    return &packet_ref_vtable;
}

// -----------------------------------------------------------------------------
// Command pool implementation
// -----------------------------------------------------------------------------

struct FFCmdPool {
    std::mutex mutex;
    FFCmd* free_list;
    FFCmd* all_cmds;        // Linked list of all allocated cmd blocks
    uint32_t total_count;
    uint32_t free_count;
    uint32_t max_size;
};

// Internal: return a command to the pool
void ff_cmd_pool_return(FFCmdPool* pool, FFCmd* cmd) {
    if (!pool || !cmd) return;
    
    std::lock_guard<std::mutex> lock(pool->mutex);
    
    // Reset the command
    cmd->type = FF_CMD_NONE;
    cmd->data = nullptr;
    cmd->data_ref = nullptr;
    cmd->pts = 0;
    cmd->dts = 0;
    cmd->flags = 0;
    cmd->stream_index = 0;
    cmd->user_data = nullptr;
    
    // Add to free list
    cmd->_next = pool->free_list;
    pool->free_list = cmd;
    pool->free_count++;
}

FFCmdPool* ff_cmd_pool_create(uint32_t initial_size, uint32_t max_size) {
    FFCmdPool* pool = new FFCmdPool();
    pool->free_list = nullptr;
    pool->all_cmds = nullptr;
    pool->total_count = 0;
    pool->free_count = 0;
    pool->max_size = max_size;
    
    // Pre-allocate initial commands
    for (uint32_t i = 0; i < initial_size; i++) {
        FFCmd* cmd = static_cast<FFCmd*>(calloc(1, sizeof(FFCmd)));
        if (!cmd) break;
        
        cmd->ref = cmd_ref_vtable;
        cmd->_pool = pool;
        cmd->_refcount = 0;
        
        // Add to all_cmds list (using _next temporarily, we'll fix this)
        // Actually, let's just track via free_list for now
        cmd->_next = pool->free_list;
        pool->free_list = cmd;
        pool->total_count++;
        pool->free_count++;
    }
    
    return pool;
}

void ff_cmd_pool_destroy(FFCmdPool* pool) {
    if (!pool) return;
    
    // Free all commands on the free list
    FFCmd* cmd = pool->free_list;
    while (cmd) {
        FFCmd* next = cmd->_next;
        free(cmd);
        cmd = next;
    }
    
    delete pool;
}

FFCmd* ff_cmd_pool_acquire(FFCmdPool* pool) {
    if (!pool) return nullptr;
    
    std::lock_guard<std::mutex> lock(pool->mutex);
    
    FFCmd* cmd = nullptr;
    
    if (pool->free_list) {
        // Get from free list
        cmd = pool->free_list;
        pool->free_list = cmd->_next;
        pool->free_count--;
    } else if (pool->max_size == 0 || pool->total_count < pool->max_size) {
        // Allocate new
        cmd = static_cast<FFCmd*>(calloc(1, sizeof(FFCmd)));
        if (cmd) {
            cmd->ref = cmd_ref_vtable;
            cmd->_pool = pool;
            pool->total_count++;
        }
    }
    
    if (cmd) {
        cmd->_next = nullptr;
        cmd->_refcount = 1;
        cmd->type = FF_CMD_NONE;
        cmd->data = nullptr;
        cmd->data_ref = nullptr;
        cmd->pts = 0;
        cmd->dts = 0;
        cmd->flags = 0;
        cmd->stream_index = 0;
        cmd->user_data = nullptr;
    }
    
    return cmd;
}

uint32_t ff_cmd_pool_total_count(FFCmdPool* pool) {
    if (!pool) return 0;
    std::lock_guard<std::mutex> lock(pool->mutex);
    return pool->total_count;
}

uint32_t ff_cmd_pool_free_count(FFCmdPool* pool) {
    if (!pool) return 0;
    std::lock_guard<std::mutex> lock(pool->mutex);
    return pool->free_count;
}

uint32_t ff_cmd_pool_in_use_count(FFCmdPool* pool) {
    if (!pool) return 0;
    std::lock_guard<std::mutex> lock(pool->mutex);
    return pool->total_count - pool->free_count;
}

// -----------------------------------------------------------------------------
// Command helpers
// -----------------------------------------------------------------------------

void ff_cmd_init(FFCmd* cmd, FFCmdType type) {
    if (!cmd) return;
    
    // Clear data first
    ff_cmd_clear_data(cmd);
    
    cmd->type = type;
    cmd->pts = 0;
    cmd->dts = 0;
    cmd->flags = 0;
    cmd->stream_index = 0;
    cmd->user_data = nullptr;
}

void ff_cmd_set_data(FFCmd* cmd, void* data, IFFRefCounted* data_ref) {
    if (!cmd) return;
    
    // Clear existing data
    ff_cmd_clear_data(cmd);
    
    cmd->data = data;
    cmd->data_ref = data_ref;
    
    // AddRef if interface provided
    if (data && data_ref && data_ref->AddRef) {
        data_ref->AddRef(data);
    }
}

void ff_cmd_clear_data(FFCmd* cmd) {
    if (!cmd) return;
    
    // Release if interface provided
    if (cmd->data && cmd->data_ref && cmd->data_ref->Release) {
        cmd->data_ref->Release(cmd->data);
    }
    
    cmd->data = nullptr;
    cmd->data_ref = nullptr;
}

// -----------------------------------------------------------------------------
// Command FIFO implementation
// -----------------------------------------------------------------------------

struct FFCmdFifo {
    using FifoType = sproqet::sproqet_generic_waitable_fifo<FFCmd*, sproqet::default_semaphore_impl>;
    std::unique_ptr<FifoType> fifo;
    
    FFCmdFifo(uint32_t capacity, sproqet::SP_Circular_Fifo_Mode mode) {
        fifo = std::make_unique<FifoType>(
            capacity,
            nullptr,    // no head monitor
            true,       // read semaphore
            mode,
            nullptr,    // user data
            0,          // tag
            true        // can unwait
        );
    }
    
    ~FFCmdFifo() {
        // Drain and release any remaining commands
        fifo->setFlowEnabled(false);
        
        FFCmd* cmd = nullptr;
        while (fifo->tryWaitForReadData() == 0) {
            fifo->read(cmd);
            if (cmd) {
                FF_CMD_RELEASE(cmd);
            }
        }
    }
};

FFCmdFifo* ff_cmd_fifo_create(uint32_t capacity, FFCmdFifoMode mode) {
    auto spMode = (mode == FF_CMD_FIFO_BLOCKING)
        ? sproqet::Circular_Fifo_Mode_Blocking
        : sproqet::Circular_Fifo_Mode_Single_Producer_Lockless;
    return new FFCmdFifo(capacity, spMode);
}

void ff_cmd_fifo_destroy(FFCmdFifo* fifo) {
    delete fifo;
}

void ff_cmd_fifo_set_flow_enabled(FFCmdFifo* fifo, bool enabled) {
    if (fifo && fifo->fifo) {
        fifo->fifo->setFlowEnabled(enabled);
    }
}

bool ff_cmd_fifo_get_flow_enabled(FFCmdFifo* fifo) {
    return fifo && fifo->fifo ? fifo->fifo->getFlowEnabled() : false;
}

int ff_cmd_fifo_wait_write(FFCmdFifo* fifo) {
    if (!fifo || !fifo->fifo) return FF_CMD_FIFO_INVALID_PARAMS;
    return fifo->fifo->waitForWriteSpace();
}

int ff_cmd_fifo_wait_write_timed(FFCmdFifo* fifo, int msecs) {
    if (!fifo || !fifo->fifo) return FF_CMD_FIFO_INVALID_PARAMS;
    return fifo->fifo->waitForWriteSpaceTimed(msecs);
}

int ff_cmd_fifo_try_write(FFCmdFifo* fifo) {
    if (!fifo || !fifo->fifo) return FF_CMD_FIFO_INVALID_PARAMS;
    return fifo->fifo->tryWaitForWriteData();
}

int ff_cmd_fifo_write(FFCmdFifo* fifo, FFCmd* cmd) {
    if (!fifo || !fifo->fifo) return FF_CMD_FIFO_INVALID_PARAMS;
    // Transfer ownership - no addref, FIFO now owns the ref
    return fifo->fifo->write(cmd);
}

int ff_cmd_fifo_wait_read(FFCmdFifo* fifo) {
    if (!fifo || !fifo->fifo) return FF_CMD_FIFO_INVALID_PARAMS;
    return fifo->fifo->waitForReadData();
}

int ff_cmd_fifo_wait_read_timed(FFCmdFifo* fifo, int msecs) {
    if (!fifo || !fifo->fifo) return FF_CMD_FIFO_INVALID_PARAMS;
    return fifo->fifo->waitForReadDataTimed(msecs);
}

int ff_cmd_fifo_try_read(FFCmdFifo* fifo) {
    if (!fifo || !fifo->fifo) return FF_CMD_FIFO_INVALID_PARAMS;
    return fifo->fifo->tryWaitForReadData();
}

int ff_cmd_fifo_read(FFCmdFifo* fifo, FFCmd** cmd) {
    if (!fifo || !fifo->fifo || !cmd) return FF_CMD_FIFO_INVALID_PARAMS;
    
    FFCmd* c = nullptr;
    fifo->fifo->read(c);
    *cmd = c;
    // Transfer ownership - no addref, caller now owns the ref
    return FF_CMD_FIFO_OK;
}

int ff_cmd_fifo_preempt(FFCmdFifo* fifo, FFCmd* cmd) {
    if (!fifo || !fifo->fifo) return FF_CMD_FIFO_INVALID_PARAMS;
    return fifo->fifo->preempt(cmd);
}

int ff_cmd_fifo_count(FFCmdFifo* fifo) {
    return fifo && fifo->fifo ? fifo->fifo->storedCount() : 0;
}

bool ff_cmd_fifo_has_been_read(FFCmdFifo* fifo) {
    return fifo && fifo->fifo ? fifo->fifo->hasBeenRead() : false;
}