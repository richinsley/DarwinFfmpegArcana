/**
 * media_fifo.cpp
 * 
 * Implementation of typed media FIFOs for frames and packets.
 * C++ headers are included here, not in the public header.
 */

#include "include/media_fifo.h"

// C++ standard library - included here, not in public header
#include <memory>
#include <atomic>
#include <mutex>

// Internal C++ headers
#include "fifo/bound_fifo_impl.hpp"
#include "fifo/default_semaphore_impl.hpp"

#include <cstdlib>

namespace ffarcana {

using DefaultSemaphore = sproqet::default_semaphore_impl;

// -----------------------------------------------------------------------------
// FrameFifo C++ Implementation
// -----------------------------------------------------------------------------

class FrameFifo {
public:
    using FifoType = sproqet::sproqet_generic_waitable_fifo<AVFrame*, DefaultSemaphore>;
    
    explicit FrameFifo(unsigned int capacity, sproqet::SP_Circular_Fifo_Mode mode) {
        _fifo = std::make_unique<FifoType>(
            capacity,
            nullptr,    // no head monitor
            true,       // read semaphore
            mode,
            nullptr,    // user data
            0,          // tag
            true        // can unwait
        );
    }

    ~FrameFifo() {
        // Disable flow and drain remaining frames
        _fifo->setFlowEnabled(false);
        
        AVFrame* frame = nullptr;
        while (_fifo->tryWaitForReadData() == 0) {
            _fifo->read(frame);
            if (frame) {
                av_frame_free(&frame);
            }
        }
    }

    void setFlowEnabled(bool enabled) {
        _fifo->setFlowEnabled(enabled);
    }

    bool getFlowEnabled() {
        return _fifo->getFlowEnabled();
    }

    int waitForWriteSpace() {
        return _fifo->waitForWriteSpace();
    }

    int waitForWriteSpaceTimed(int msecs) {
        return _fifo->waitForWriteSpaceTimed(msecs);
    }

    int tryWaitForWriteSpace() {
        return _fifo->tryWaitForWriteData();
    }

    int write(AVFrame* frame) {
        if (!frame) return FF_FIFO_INVALID_PARAMS;
        
        // Clone the frame (makes a new ref to the data)
        AVFrame* clone = av_frame_clone(frame);
        if (!clone) return FF_FIFO_INVALID_PARAMS;
        
        int result = _fifo->write(clone);
        if (result != FF_FIFO_OK) {
            av_frame_free(&clone);
        }
        return result;
    }

    int preempt(AVFrame* frame) {
        if (!frame) return FF_FIFO_INVALID_PARAMS;
        
        AVFrame* clone = av_frame_clone(frame);
        if (!clone) return FF_FIFO_INVALID_PARAMS;
        
        int result = _fifo->preempt(clone);
        if (result != FF_FIFO_OK) {
            av_frame_free(&clone);
        }
        return result;
    }

    int waitForReadData() {
        return _fifo->waitForReadData();
    }

    int waitForReadDataTimed(int msecs) {
        return _fifo->waitForReadDataTimed(msecs);
    }

    int tryWaitForReadData() {
        return _fifo->tryWaitForReadData();
    }

    int read(AVFrame** frame) {
        if (!frame) return FF_FIFO_INVALID_PARAMS;
        
        AVFrame* f = nullptr;
        _fifo->read(f);
        *frame = f;
        
        return FF_FIFO_OK;
    }

    int storedCount() {
        return _fifo->storedCount();
    }

    bool hasBeenRead() {
        return _fifo->hasBeenRead();
    }

private:
    std::unique_ptr<FifoType> _fifo;
};

// -----------------------------------------------------------------------------
// PacketFifo C++ Implementation
// -----------------------------------------------------------------------------

class PacketFifo {
public:
    using FifoType = sproqet::sproqet_generic_waitable_fifo<AVPacket*, DefaultSemaphore>;
    
    explicit PacketFifo(unsigned int capacity, sproqet::SP_Circular_Fifo_Mode mode) {
        _fifo = std::make_unique<FifoType>(
            capacity,
            nullptr,
            true,
            mode,
            nullptr,
            0,
            true
        );
    }

    ~PacketFifo() {
        _fifo->setFlowEnabled(false);
        
        AVPacket* packet = nullptr;
        while (_fifo->tryWaitForReadData() == 0) {
            _fifo->read(packet);
            if (packet) {
                av_packet_free(&packet);
            }
        }
    }

    void setFlowEnabled(bool enabled) {
        _fifo->setFlowEnabled(enabled);
    }

    bool getFlowEnabled() {
        return _fifo->getFlowEnabled();
    }

    int waitForWriteSpace() {
        return _fifo->waitForWriteSpace();
    }

    int waitForWriteSpaceTimed(int msecs) {
        return _fifo->waitForWriteSpaceTimed(msecs);
    }

    int tryWaitForWriteSpace() {
        return _fifo->tryWaitForWriteData();
    }

    int write(AVPacket* packet) {
        if (!packet) return FF_FIFO_INVALID_PARAMS;
        
        AVPacket* clone = av_packet_clone(packet);
        if (!clone) return FF_FIFO_INVALID_PARAMS;
        
        int result = _fifo->write(clone);
        if (result != FF_FIFO_OK) {
            av_packet_free(&clone);
        }
        return result;
    }

    int preempt(AVPacket* packet) {
        if (!packet) return FF_FIFO_INVALID_PARAMS;
        
        AVPacket* clone = av_packet_clone(packet);
        if (!clone) return FF_FIFO_INVALID_PARAMS;
        
        int result = _fifo->preempt(clone);
        if (result != FF_FIFO_OK) {
            av_packet_free(&clone);
        }
        return result;
    }

    int waitForReadData() {
        return _fifo->waitForReadData();
    }

    int waitForReadDataTimed(int msecs) {
        return _fifo->waitForReadDataTimed(msecs);
    }

    int tryWaitForReadData() {
        return _fifo->tryWaitForReadData();
    }

    int read(AVPacket** packet) {
        if (!packet) return FF_FIFO_INVALID_PARAMS;
        
        AVPacket* p = nullptr;
        _fifo->read(p);
        *packet = p;
        
        return FF_FIFO_OK;
    }

    int storedCount() {
        return _fifo->storedCount();
    }

    bool hasBeenRead() {
        return _fifo->hasBeenRead();
    }

private:
    std::unique_ptr<FifoType> _fifo;
};

} // namespace ffarcana

// -----------------------------------------------------------------------------
// C API Implementation
// -----------------------------------------------------------------------------

using namespace ffarcana;

// Frame FIFO C wrappers
struct FFFrameFifo {
    FrameFifo impl;
    FFFrameFifo(unsigned int cap, sproqet::SP_Circular_Fifo_Mode mode) : impl(cap, mode) {}
};

FFFrameFifo* ff_frame_fifo_create(unsigned int capacity, FFifoMode mode) {
    auto spMode = (mode == FF_FIFO_MODE_BLOCKING) 
        ? sproqet::Circular_Fifo_Mode_Blocking 
        : sproqet::Circular_Fifo_Mode_Single_Producer_Lockless;
    return new FFFrameFifo(capacity, spMode);
}

void ff_frame_fifo_destroy(FFFrameFifo* fifo) {
    delete fifo;
}

void ff_frame_fifo_set_flow_enabled(FFFrameFifo* fifo, bool enabled) {
    if (fifo) fifo->impl.setFlowEnabled(enabled);
}

bool ff_frame_fifo_get_flow_enabled(FFFrameFifo* fifo) {
    return fifo ? fifo->impl.getFlowEnabled() : false;
}

int ff_frame_fifo_wait_write(FFFrameFifo* fifo) {
    return fifo ? fifo->impl.waitForWriteSpace() : FF_FIFO_INVALID_PARAMS;
}

int ff_frame_fifo_wait_write_timed(FFFrameFifo* fifo, int msecs) {
    return fifo ? fifo->impl.waitForWriteSpaceTimed(msecs) : FF_FIFO_INVALID_PARAMS;
}

int ff_frame_fifo_try_write(FFFrameFifo* fifo) {
    return fifo ? fifo->impl.tryWaitForWriteSpace() : FF_FIFO_INVALID_PARAMS;
}

int ff_frame_fifo_write(FFFrameFifo* fifo, AVFrame* frame) {
    return fifo ? fifo->impl.write(frame) : FF_FIFO_INVALID_PARAMS;
}

int ff_frame_fifo_wait_read(FFFrameFifo* fifo) {
    return fifo ? fifo->impl.waitForReadData() : FF_FIFO_INVALID_PARAMS;
}

int ff_frame_fifo_wait_read_timed(FFFrameFifo* fifo, int msecs) {
    return fifo ? fifo->impl.waitForReadDataTimed(msecs) : FF_FIFO_INVALID_PARAMS;
}

int ff_frame_fifo_try_read(FFFrameFifo* fifo) {
    return fifo ? fifo->impl.tryWaitForReadData() : FF_FIFO_INVALID_PARAMS;
}

int ff_frame_fifo_read(FFFrameFifo* fifo, AVFrame** frame) {
    return fifo ? fifo->impl.read(frame) : FF_FIFO_INVALID_PARAMS;
}

int ff_frame_fifo_preempt(FFFrameFifo* fifo, AVFrame* frame) {
    return fifo ? fifo->impl.preempt(frame) : FF_FIFO_INVALID_PARAMS;
}

int ff_frame_fifo_count(FFFrameFifo* fifo) {
    return fifo ? fifo->impl.storedCount() : 0;
}

bool ff_frame_fifo_has_been_read(FFFrameFifo* fifo) {
    return fifo ? fifo->impl.hasBeenRead() : false;
}

// Packet FIFO C wrappers
struct FFPacketFifo {
    PacketFifo impl;
    FFPacketFifo(unsigned int cap, sproqet::SP_Circular_Fifo_Mode mode) : impl(cap, mode) {}
};

FFPacketFifo* ff_packet_fifo_create(unsigned int capacity, FFifoMode mode) {
    auto spMode = (mode == FF_FIFO_MODE_BLOCKING) 
        ? sproqet::Circular_Fifo_Mode_Blocking 
        : sproqet::Circular_Fifo_Mode_Single_Producer_Lockless;
    return new FFPacketFifo(capacity, spMode);
}

void ff_packet_fifo_destroy(FFPacketFifo* fifo) {
    delete fifo;
}

void ff_packet_fifo_set_flow_enabled(FFPacketFifo* fifo, bool enabled) {
    if (fifo) fifo->impl.setFlowEnabled(enabled);
}

bool ff_packet_fifo_get_flow_enabled(FFPacketFifo* fifo) {
    return fifo ? fifo->impl.getFlowEnabled() : false;
}

int ff_packet_fifo_wait_write(FFPacketFifo* fifo) {
    return fifo ? fifo->impl.waitForWriteSpace() : FF_FIFO_INVALID_PARAMS;
}

int ff_packet_fifo_wait_write_timed(FFPacketFifo* fifo, int msecs) {
    return fifo ? fifo->impl.waitForWriteSpaceTimed(msecs) : FF_FIFO_INVALID_PARAMS;
}

int ff_packet_fifo_try_write(FFPacketFifo* fifo) {
    return fifo ? fifo->impl.tryWaitForWriteSpace() : FF_FIFO_INVALID_PARAMS;
}

int ff_packet_fifo_write(FFPacketFifo* fifo, AVPacket* packet) {
    return fifo ? fifo->impl.write(packet) : FF_FIFO_INVALID_PARAMS;
}

int ff_packet_fifo_wait_read(FFPacketFifo* fifo) {
    return fifo ? fifo->impl.waitForReadData() : FF_FIFO_INVALID_PARAMS;
}

int ff_packet_fifo_wait_read_timed(FFPacketFifo* fifo, int msecs) {
    return fifo ? fifo->impl.waitForReadDataTimed(msecs) : FF_FIFO_INVALID_PARAMS;
}

int ff_packet_fifo_try_read(FFPacketFifo* fifo) {
    return fifo ? fifo->impl.tryWaitForReadData() : FF_FIFO_INVALID_PARAMS;
}

int ff_packet_fifo_read(FFPacketFifo* fifo, AVPacket** packet) {
    return fifo ? fifo->impl.read(packet) : FF_FIFO_INVALID_PARAMS;
}

int ff_packet_fifo_preempt(FFPacketFifo* fifo, AVPacket* packet) {
    return fifo ? fifo->impl.preempt(packet) : FF_FIFO_INVALID_PARAMS;
}

int ff_packet_fifo_count(FFPacketFifo* fifo) {
    return fifo ? fifo->impl.storedCount() : 0;
}

bool ff_packet_fifo_has_been_read(FFPacketFifo* fifo) {
    return fifo ? fifo->impl.hasBeenRead() : false;
}