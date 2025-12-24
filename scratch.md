td-agora-link/sproqet_fifo/bound_fifo_impl.hpp
```cpp
#ifndef SPROQET_GENERIC_FIFO_H
#define SPROQET_GENERIC_FIFO_H

#include <memory>
#include <atomic>
#include <mutex>

#include "default_semaphore_impl.hpp"
#include "circular_fifo.hpp"
#include "sproqet_defines.hpp"

namespace sproqet {

// Abstract class that is used to allow the fifo to callback whenever there is a new head.
// This can be used to peek the current head and see if it is a command sample.  If the fifo is empty when
// write is called, generic_fifo_new_head will be called from the thread that writes the sample.  If there is more than
// one element in the fifo and read is called, sproqet_generic_fifo_head_monitor will be called from the thread that reads the sample.
// If the resulting call to generic_fifo_new_head results in the removal of a sample from the fifo, it MUST return false to indicate
// the fifo should modify the read space available semaphore (if the fifo was created with a read space semaphore)
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

    // before read or write are called, the respective waitForReadData or waitForWriteSpace must have been
    // called and returned true with the given sampleCount.  bound_fifo_impl does not modify the reference
    // count elements.
    int	read(Element& element) {
        element = _popPacket();
        _hasBeenRead = true;
        return 1; // we only read one (this seems useless)
    }

    int	write(Element& element) {
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

    // infinite waits
    int waitForReadData() {
        if(_readSem)
        {
            return _readSem->Wait();
        }
        return SPR_FLOWDISABLED;
    }

    // try waits
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

        // we need to return if flow was disabled while _writeSem was blocked
        enabledFlow = _flowEnabled.load(std::memory_order_relaxed);
        int retv = (enabledFlow == 1) ? SPR_OK : SPR_FLOWDISABLED;

        return retv;
    }

    // timed waits, msecs < 1 is forever
    // returns 0 if success, -1 if timed out
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

    // enable or disable write flow into the element fifo.  An element fifo that has flow disabled will return
    // SPR_FLOWDISABLED in write(), waitForWriteSpace(), and waitForWriteSpaceTimed.  Disabling flow while
    // another (single) thread is waiting on waitForWriteSpace(), or waitForWriteSpaceTimed(), will be unblocked and
    // and return SPR_FLOWDISABLED.
    void setFlowEnabled(bool enabled) {
        int flow = _flowEnabled.load(std::memory_order_relaxed);
        if((flow == 0 && !enabled) || (flow == 1 && enabled))
        {
            // already there
            return;
        }

        if(enabled)
        {
            // enable flow
            _flowEnabled.store(1, std::memory_order_relaxed);
        }
        else
        {
            // disable flow via an atomic int storage
            _flowEnabled.store(0, std::memory_order_relaxed);

            int pcount = _elements->storedCount();
            int cap = _elements->capacity();
            if(pcount == cap - 1)
            {
                // The fifo is full, so there could be a thread waiting for write space.
                // Wake A SINGLE thread that may be blocked on waitForWriteSpace.  If there is a waiting thread, it will receive SPR_FLOWDISABLED
                // in the wait command.  (A fifo should only ever have one thread waiting on write space at a time)
                _writeSem->Post();

                // purge the _writeSem semaphore to zero
                _writeSem->Reset();
            }

            if(pcount == 0 && _readSem)
            {
                // The fifo is empty, so there could be a thread waiting for read space.
                _readSem->Post();
                _readSem->Reset();
            }
        }
    }

    bool getFlowEnabled() {
        return _flowEnabled.load(std::memory_order_relaxed) > 0;
    }

    // generic_fifo_new_head impl - we'll translate it into a sproqet_generic_fifo_head_monitor call
    void fifo_new_head(void * userdata) {
        if(_headMonitor)
        {
            _headMonitor->generic_fifo_new_head(this, _userData, _tag);
        }
    }

    // This is accurate for blocking mode, but may not be a true representation in lockless mode.
    int storedCount() { return _elements->storedCount(); }

    void setWaterMarkHandler(int high, WaterMarkHandler highHandler, int low, WaterMarkHandler lowHandler, void * data) {
        _elements->setWaterMarkHandler(high, highHandler, low, lowHandler, data);
    }

    bool hasBeenRead() {
        return _hasBeenRead;
    }
private:
    // push and pop to packet pool
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

    // signal that read/write data is available
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

    // read flow semaphore
    std::unique_ptr<SemaphoreType> _readSem;

    // write flow semaphore
    std::unique_ptr<SemaphoreType> _writeSem;

    // max number of packets in FIFO.
    int _maxPackets;

    // flow control
    std::atomic<int> _flowEnabled;

    // head monitor callback
    sproqet_generic_fifo_head_monitor * _headMonitor;

    // If we are allowed to unwait, writing a value of 0 will trigger the unwait.
    // When a fifo is needed that can store NULL or 0, we are implicitly not allowed to unwait.
    bool _canUnwait;

    // userdata passed back to head monitor
    void * _userData;

    // arbitrary id tag for use in head monitor
    uint32_t _tag;

    // flag that is set on the first read operation
    bool _hasBeenRead;
};

} // end namespace sproqet

#endif // SPROQET_GENERIC_FIFO_H

```

td-agora-link/sproqet_fifo/circular_fifo.hpp
```cpp
#ifndef SPROQET_CIRCULAR_FIFO_H
#define SPROQET_CIRCULAR_FIFO_H

#include <atomic>
#include <mutex>

namespace sproqet {

// Abstract class that is used to allow the fifo to callback whenever there is a new head.
class isproqet_fifo_head_monitor
{
public:
    virtual void fifo_new_head(void * userdata) = 0;
};

typedef void (*WaterMarkHandler)(void * opaque);

enum SP_Circular_Fifo_Mode {
    // A lockless fifo for a single producer and a single consumer.
    // This is the fastest, but will have undefined behavior if there is
    // more than one producer and or consumer thread.
    Circular_Fifo_Mode_Single_Producer_Lockless,

    // A blocking fifo.  This is suitable for multiple consumer and producer
    // threads, and allows for fifo preemption.
    Circular_Fifo_Mode_Blocking
};

template<typename Element>
class circular_fifo
{
public:
    explicit circular_fifo(int fifoSize, SP_Circular_Fifo_Mode mode) {
        _mode = mode;
        _tail.store(0, std::memory_order_relaxed);
        _head.store(0, std::memory_order_relaxed);
        _count.store(0);
        _nahead = _natail = 0;
        _capacity = fifoSize + 1;
        _array = (Element *)malloc(_capacity * sizeof(Element));
        _headMonitor = NULL;
        _waterMarkOpaque = NULL;
        _lowWaterMarkHandler = NULL;
        _highWaterMarkHandler = NULL;
        _highWaterMark = -1;
        _lowWaterMark = -1;
    }

    virtual ~circular_fifo() {
        Element e;
        // disable the head monitor and purge any remaining Elements
        _headMonitor = NULL;
        while(pop(e, NULL)) {}
        free(_array);
    }

    void setHeadMonitor(isproqet_fifo_head_monitor * monitor) { 
        _headMonitor = monitor; 
    }

    SP_Circular_Fifo_Mode getMode() { 
        return _mode; 
    }

    // add element to back of fifo
    bool push(const Element& item) {
        bool newHead = false;
        if(_mode == Circular_Fifo_Mode_Single_Producer_Lockless) {
            const int current_tail = _tail.load(std::memory_order_relaxed);
            const int next_tail = increment(current_tail);
            const int head = _head.load(std::memory_order_acquire);

            if(next_tail != head) {
                ::new ((void *)&_array[current_tail]) Element(::std::move(item));

                _tail.store(next_tail, std::memory_order_release);

                // increase the _count.  If the original value was 0, this is a new head
                int f = _count.fetch_add(1, std::memory_order_acq_rel);
                if(f == 0) {
                    newHead = true;
                }

                if(_highWaterMarkHandler && f == _highWaterMark + 1) {
                    _highWaterMarkHandler(_waterMarkOpaque);
                }

                if(_headMonitor && newHead) {
                    _headMonitor->fifo_new_head(NULL);
                }
                return true;
            }

            // full queue
            return false;
        } else {
            // use generic blocking mutex
            _blockingMutex.lock();
            if(_natail == _nahead) {
                newHead = true;
            }

            const int current_tail = _natail;
            const int next_tail = increment(current_tail);
            if(next_tail != _nahead) {
                ::new ((void *)&_array[current_tail]) Element(::std::move(item));

                _natail = next_tail;
                int f = _count.fetch_add(1, std::memory_order_relaxed);
                _blockingMutex.unlock();

                if(_highWaterMarkHandler && f == _highWaterMark + 1) {
                    _highWaterMarkHandler(_waterMarkOpaque);
                }

                if(_headMonitor && newHead)
                {
                    _headMonitor->fifo_new_head(NULL);
                }
                return true;
            }

            // full queue
            _blockingMutex.unlock();
            return false;
        }
    }

    // add element to front of fifo, preempting existing elements - preempt will always raise the head monitor
    bool preempt(const Element& item) {
        if(_mode == Circular_Fifo_Mode_Single_Producer_Lockless) {
            const int current_head = _head.load(std::memory_order_relaxed);
            const int next_head = decrement(current_head);
            if(next_head != _tail.load(std::memory_order_acquire)) {
                ::new ((void *)&_array[next_head]) Element(::std::move(item));

                _head.store(next_head, std::memory_order_release);
                _count.fetch_add(1, std::memory_order_relaxed);
                if(_headMonitor) {
                    _headMonitor->fifo_new_head(NULL);
                }
                return true;
            }

            // full queue
            return false;
        } else {
            // use generic blocking mutex
            _blockingMutex.lock();
            const int current_head = _nahead;
            const int next_head = decrement(current_head);
            if(next_head != _natail) {
                ::new ((void *)&_array[next_head]) Element(::std::move(item));

                _nahead = next_head;
                _count.fetch_add(1, std::memory_order_relaxed);
                _blockingMutex.unlock();
                if(_headMonitor) {
                    _headMonitor->fifo_new_head(NULL);
                }
                return true;
            }

            // full queue
            _blockingMutex.unlock();
            return false;
        }
    }

    bool pop(Element& item, void * userdata) {
        if(_mode == Circular_Fifo_Mode_Single_Producer_Lockless) {
            const int current_head = _head.load(std::memory_order_relaxed);
            if(current_head == _tail.load(std::memory_order_acquire)) {
                // empty queue
                return false;
            }

            item = _array[current_head];
            _array[current_head].~Element();

            _head.store(increment(current_head), std::memory_order_release);
            int f = _count.fetch_sub(1, std::memory_order_acq_rel);

            if(_lowWaterMarkHandler && f == _lowWaterMark -1) {
                _lowWaterMarkHandler(_waterMarkOpaque);
            }

            if((f != 1) && _headMonitor) {
                // if deref is true, then the fifo is not empty, and it has a new head
                _headMonitor->fifo_new_head(userdata);
            }
            return true;
        } else {
            // use generic blocking mutex
            _blockingMutex.lock();
            const int current_head = _nahead;
            if(current_head == _natail) {
                // empty queue
                _blockingMutex.unlock();
                return false;
            }

            item = _array[current_head];
            _array[current_head].~Element();

            _nahead = increment(current_head);
            // if _count is > 1, then this pop will result in a new head
            int newHead = _count.fetch_sub(1, std::memory_order_relaxed) - 1;
            _blockingMutex.unlock();

            if(_lowWaterMarkHandler && newHead == _lowWaterMark -1) {
                _lowWaterMarkHandler(_waterMarkOpaque);
            }

            if(newHead && _headMonitor) {
                // if deref is true, then the fifo is not empty, and it has a new head
                _headMonitor->fifo_new_head(userdata);
            }
            return true;
        }
    }

    int capacity() {
        return _capacity;
    }

    // this is accurate for blocking mode, but may not be a true representation in lockless mode
    int storedCount() { return _count.load(std::memory_order_relaxed); }

    void setWaterMarkHandler(int high, WaterMarkHandler highHandler, int low, WaterMarkHandler lowHandler, void * data) {
        _lowWaterMarkHandler = lowHandler;
        _highWaterMarkHandler = highHandler;
        _waterMarkOpaque = data;
        _highWaterMark = high;
        _lowWaterMark = low;
    }
private:
  int increment(int idx) const {
      return (idx + 1) % _capacity;
  }

  int decrement(int idx) const {
      return (idx - 1) < 0 ? _capacity - 1: (idx - 1);
  }

  std::atomic<int>              _tail;  // tail(input) index
  std::atomic<int>              _head;  // head(output) index
  std::atomic<int>              _count; // count of items stored

  Element *                     _array;
  int                           _natail; // non-atomic tail
  int                           _nahead; // non-atomic head

  int                           _capacity;
  SP_Circular_Fifo_Mode         _mode;
  std::mutex                    _blockingMutex;
  isproqet_fifo_head_monitor *  _headMonitor;

  WaterMarkHandler              _lowWaterMarkHandler;
  WaterMarkHandler              _highWaterMarkHandler;
  int                           _highWaterMark;
  int                           _lowWaterMark;
  void *                        _waterMarkOpaque;
};

} // end namespace sproqet

#endif // SPROQET_CIRCULAR_FIFO_H

```

td-agora-link/sproqet_fifo/default_semaphore_impl.cpp
```cpp
#include "default_semaphore_impl.hpp"
#include <stdlib.h>

#if defined(WIN32) || defined(_WIN32)
    #include <windows.h>
    #define SEM_WINDOWS 1
#elif defined (__APPLE__) && defined (__MACH__)
    #include <mach/mach.h>
    #include <mach/semaphore.h>
    #include <mach/task.h>
    #include <device/device_port.h>
    #include <pthread.h>
    #include <mach/clock.h>
    #define SEM_DARWIN 1
#elif defined(__unix__)
    #include <time.h>
    #include <semaphore.h>
    #include <pthread.h>
    #include <errno.h>
    #define SEM_POSIX 1
#else
    #include <semaphore>
    #define SEM_CPP_20 1
#endif

using namespace sproqet;

default_semaphore_impl::default_semaphore_impl(unsigned int initVal)
{
#if defined(SEM_WINDOWS)
    // we need to specify a max semaphore value in win32.  UINT16_MAX should be enough
    _semaphore_opaque = (void*)CreateSemaphore(NULL, initVal, 65535U, NULL);
#elif defined(SEM_DARWIN)
    semaphore_t * m = (semaphore_t *)malloc(sizeof(semaphore_t));
    mach_port_t self = mach_task_self();
    semaphore_create(self, m, SYNC_POLICY_FIFO, initVal);
    _semaphore_opaque = m;
#elif defined(SEM_POSIX)
    sem_t * m = (sem_t *)malloc(sizeof(sem_t));
    sem_init(m, 0, initVal);
    _semaphore_opaque = m;
#elif defined(SEM_CPP_20)
    std::binary_semaphore * m = new std::binary_semaphore(initVal);
    _semaphore_opaque = (void*)m;
#endif
}

default_semaphore_impl::~default_semaphore_impl()
{
#if defined(SEM_WINDOWS)
    CloseHandle((HANDLE)_semaphore_opaque);
#elif defined(SEM_DARWIN)
    mach_port_t self = mach_task_self();
    semaphore_destroy(self, *(semaphore_t*)_semaphore_opaque);
    free(_semaphore_opaque);
#elif defined(SEM_POSIX)
    sem_destroy((sem_t *)_semaphore_opaque);
    free(_semaphore_opaque);
#elif defined(SEM_CPP_20)
    std::binary_semaphore * m = (std::binary_semaphore*)_semaphore_opaque;
    delete m;
#endif
}

int default_semaphore_impl::Post()
{
    int retv = 0;

#if defined(SEM_WINDOWS)
    // the expected return value on windows is the inverse of posix
    LONG vv;
    BOOL rr = ReleaseSemaphore((HANDLE)_semaphore_opaque, 1, &vv);
    retv = (int)(rr ? 0 : 1);
#elif defined(SEM_DARWIN)
    retv = (int)semaphore_signal(*(semaphore_t*)_semaphore_opaque);
#elif defined(SEM_POSIX)
    retv = (int)sem_post((sem_t *)_semaphore_opaque);
#elif defined(SEM_CPP_20)
    std::binary_semaphore * m = (std::binary_semaphore*)_semaphore_opaque;
    m->release();
#endif

    return retv;
}

int default_semaphore_impl::Wait()
{
    int retv = 0;

#if defined(SEM_WINDOWS)
    retv = (int)WaitForSingleObject((HANDLE)_semaphore_opaque, INFINITE);
#elif defined(SEM_DARWIN)
    retv = (int)semaphore_wait(*(semaphore_t*)_semaphore_opaque);
#elif defined(SEM_POSIX)
    retv = (int)sem_wait((sem_t *)_semaphore_opaque);
#elif defined(SEM_CPP_20)
    std::binary_semaphore * m = (std::binary_semaphore*)_semaphore_opaque;
    m->acquire();
#endif

    return retv;
}

int default_semaphore_impl::WaitTimed(int msecs)
{
    int retv = 0;

#if defined(SEM_WINDOWS)
    retv = WaitForSingleObject((HANDLE)_semaphore_opaque, msecs);
#elif defined(SEM_DARWIN)
    mach_timespec_t ts;
    ts.tv_sec = msecs / 1000;
    ts.tv_nsec = (msecs % 1000) * 1000000;
    retv = (int)semaphore_timedwait(*(semaphore_t*)_semaphore_opaque, ts);
#elif defined(SEM_POSIX)
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += msecs / 1000;
    ts.tv_nsec += (msecs % 1000) * 1000000;
    retv = (int)sem_timedwait((sem_t *)_semaphore_opaque, &ts);
    if(retv)
    {
        retv = errno;
    }
#elif defined(SEM_CPP_20)
    std::binary_semaphore * m = (std::binary_semaphore*)_semaphore_opaque;
    // TODO
#endif
    return retv;
}

int default_semaphore_impl::TryWait()
{
    int retv = 0;

#if defined(SEM_WINDOWS)
    retv = (int)WaitForSingleObject((HANDLE)_semaphore_opaque, 0);
#elif defined(SEM_DARWIN)
    mach_timespec_t ts;
    ts.tv_sec = 0;
    ts.tv_nsec = 0;
    retv = (int)semaphore_timedwait(*(semaphore_t*)_semaphore_opaque, ts);
#elif defined(SEM_POSIX)
    retv = (int)sem_trywait((sem_t *)_semaphore_opaque);
#elif defined(SEM_CPP_20)
    std::binary_semaphore * m = (std::binary_semaphore*)_semaphore_opaque;
    retv = m->try_acquire() ? 0 : 1;
#endif

    return retv;
}

void default_semaphore_impl::Reset()
{
    while(!TryWait()) {}
}

```

td-agora-link/sproqet_fifo/default_semaphore_impl.hpp
```cpp
#ifndef DEFAULT_SEMAPHORE_IMPL_H
#define DEFAULT_SEMAPHORE_IMPL_H

namespace sproqet
{
    class default_semaphore_impl
    {
    public:
        default_semaphore_impl(unsigned int initVal = 0);
        ~default_semaphore_impl();

        // increase the Semaphore count by one
        // return 0 if successfull
        int Post();

        // wait for semaphore to be non-zero
        // decrease the Semaphore count by one
        // return 0 if successfull
        int Wait();

        // wait for n msecs, return 0 if success, non-zero for timeout/error
        int WaitTimed(int msecs);

        // Try to wait on a semaphore.  If semaphore count is non-zero, semaphore count is decreased,
        // and returns 0.  If semaphore count is zero, returns 1
        int TryWait();

        // reset a sempahore's count to 0
        void Reset();
    private:
        void * _semaphore_opaque;
    };

} // namespace sproqet

#endif // DEFAULT_SEMAPHORE_IMPL_H

```

td-agora-link/sproqet_fifo/sproqet_defines.hpp
```cpp
#ifndef SPROQET_DEFINES_H_
#define SPROQET_DEFINES_H_


#define SPR_OK                      0   // Success
#define SPR_INVALID_PARAMETERS      1   // Invalid required parameters
#define SPR_FLOWDISABLED            13  // a fifo has flow disabled
#define SPR_NETWORKERROR            23  // generic network error
#define SPR_FIFOFULL                29  // attempted to write to a full fifo

#endif /* ! _DEFINES_H_ */

```

