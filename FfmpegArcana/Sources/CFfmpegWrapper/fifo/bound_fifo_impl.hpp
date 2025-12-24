#ifndef SPROQET_BOUND_FIFO_IMPL_H
#define SPROQET_BOUND_FIFO_IMPL_H

#include <memory>
#include <atomic>
#include <mutex>

#include "default_semaphore_impl.hpp"
#include "circular_fifo.hpp"
#include "sproqet_defines.hpp"

namespace sproqet {

// Abstract class for head monitoring callbacks
class sproqet_generic_fifo_head_monitor
{
public:
    virtual bool generic_fifo_new_head(void * fifo, void * userdata, uint32_t tag) = 0;
};

template<typename Element, typename SemaphoreType>
class sproqet_generic_waitable_fifo : public isproqet_fifo_head_monitor
{
public:
    explicit sproqet_generic_waitable_fifo(unsigned int maxPackets,
                            sproqet_generic_fifo_head_monitor * headMonitor,
                            bool readSemaphore = true,
                            SP_Circular_Fifo_Mode mode = Circular_Fifo_Mode_Single_Producer_Lockless,
                            void * userData = 0,
                            uint32_t tag = 0,
                            bool canUnwait = true) {
        _tag = tag;
        _userData = userData;

        // immediately make available maxPackets for write space
        _writeSem = std::make_unique<SemaphoreType>(maxPackets);

        // start read sem with 0 resources
        _readSem = readSemaphore ? std::make_unique<SemaphoreType>(0) : NULL;

        _maxPackets = maxPackets;

        // flow is not enabled by default
        _flowEnabled.store(0, std::memory_order_relaxed);

        _canUnwait = canUnwait;

        _elements = std::make_unique<circular_fifo<Element>>(_maxPackets, mode);
        if(headMonitor)
        {
            _elements->setHeadMonitor(this);
        }
        _headMonitor = headMonitor;

        _hasBeenRead = false;
    }

    ~sproqet_generic_waitable_fifo() {
    }

    uint32_t tag() {
        return _tag;
    }

    int read(Element& element) {
        element = _popPacket();
        _hasBeenRead = true;
        return 1;
    }

    int write(Element& element) {
        int enabledFlow = _flowEnabled.load(std::memory_order_relaxed);
        if(!enabledFlow)
        {
            return SPR_FLOWDISABLED;
        }
        return _pushPacket(element);
    }

    int preempt(Element element) {
        int enabledFlow = _flowEnabled.load(std::memory_order_relaxed);
        if(!enabledFlow)
        {
            return SPR_FLOWDISABLED;
        }

        int retv = SPR_OK;
        if(_elements->preempt(element))
        {
            _signalRead();
        }
        else
        {
            retv = SPR_FIFOFULL;
        }

        return retv;
    }

    int waitForReadData() {
        if(_readSem)
        {
            return _readSem->Wait();
        }
        return SPR_FLOWDISABLED;
    }

    int tryWaitForReadData() {
        if(!_readSem)
        {
            return 0;
        }
        return _readSem->TryWait();
    }

    int tryWaitForWriteData() {
        int enabledFlow = _flowEnabled.load(std::memory_order_relaxed);
        if(!enabledFlow)
        {
            return SPR_FLOWDISABLED;
        }

        int retv = _writeSem->TryWait();
        int flow = _flowEnabled.load(std::memory_order_relaxed);
        if(!flow)
        {
            return SPR_FLOWDISABLED;
        }

        return retv;
    }

    int waitForWriteSpace() {
        int enabledFlow = _flowEnabled.load(std::memory_order_relaxed);
        if(!enabledFlow)
        {
            return SPR_FLOWDISABLED;
        }

        _writeSem->Wait();

        enabledFlow = _flowEnabled.load(std::memory_order_relaxed);
        int retv = (enabledFlow == 1) ? SPR_OK : SPR_FLOWDISABLED;

        return retv;
    }

    int waitForReadDataTimed(int msecs) {
        if(!_readSem)
        {
            return 0;
        }

        if(msecs < 1)
        {
            waitForReadData();
            return 0;
        }
        else
        {
            return _readSem->WaitTimed(msecs);
        }
    }

    int waitForWriteSpaceTimed(int msecs) {
        if(msecs < 1)
        {
            return waitForWriteSpace();
        }
        else
        {
            int enabledFlow = _flowEnabled.load(std::memory_order_relaxed);
            if(!enabledFlow)
            {
                return SPR_FLOWDISABLED;
            }

            int retv = _writeSem->WaitTimed(msecs);
            int flow = _flowEnabled.load(std::memory_order_relaxed);
            if(!flow)
            {
                return SPR_FLOWDISABLED;
            }

            return retv;
        }
    }

    void setFlowEnabled(bool enabled) {
        int flow = _flowEnabled.load(std::memory_order_relaxed);
        if((flow == 0 && !enabled) || (flow == 1 && enabled))
        {
            return;
        }

        if(enabled)
        {
            _flowEnabled.store(1, std::memory_order_relaxed);
        }
        else
        {
            _flowEnabled.store(0, std::memory_order_relaxed);

            int pcount = _elements->storedCount();
            int cap = _elements->capacity();
            if(pcount == cap - 1)
            {
                _writeSem->Post();
                _writeSem->Reset();
            }

            if(pcount == 0 && _readSem)
            {
                _readSem->Post();
                _readSem->Reset();
            }
        }
    }

    bool getFlowEnabled() {
        return _flowEnabled.load(std::memory_order_relaxed) > 0;
    }

    void fifo_new_head(void * userdata) {
        if(_headMonitor)
        {
            _headMonitor->generic_fifo_new_head(this, _userData, _tag);
        }
    }

    int storedCount() { return _elements->storedCount(); }

    void setWaterMarkHandler(int high, WaterMarkHandler highHandler, int low, WaterMarkHandler lowHandler, void * data) {
        _elements->setWaterMarkHandler(high, highHandler, low, lowHandler, data);
    }

    bool hasBeenRead() {
        return _hasBeenRead;
    }

private:
    Element _popPacket() {
        Element retv = Element{};
        _elements->pop(retv, NULL);
        _signalWrite();
        return retv;
    }

    int _pushPacket(Element packet) {
        int retv = SPR_OK;
        if(_elements->push(packet))
        {
            _signalRead();
        }
        else
        {
            retv = SPR_FIFOFULL;
        }
        return retv;
    }

    void _signalRead() {
        if(_readSem)
        {
            _readSem->Post();
        }
    }

    void _signalWrite() {
        _writeSem->Post();
    }

    std::mutex _fifoMutex;
    std::unique_ptr<circular_fifo<Element>> _elements;
    std::unique_ptr<SemaphoreType> _readSem;
    std::unique_ptr<SemaphoreType> _writeSem;
    int _maxPackets;
    std::atomic<int> _flowEnabled;
    sproqet_generic_fifo_head_monitor * _headMonitor;
    bool _canUnwait;
    void * _userData;
    uint32_t _tag;
    bool _hasBeenRead;
};

} // end namespace sproqet

#endif // SPROQET_BOUND_FIFO_IMPL_H
