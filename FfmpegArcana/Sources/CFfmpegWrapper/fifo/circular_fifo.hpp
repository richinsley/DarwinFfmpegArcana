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

    // add element to front of fifo, preempting existing elements
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

            if(_lowWaterMarkHandler && f == _lowWaterMark - 1) {
                _lowWaterMarkHandler(_waterMarkOpaque);
            }

            if((f != 1) && _headMonitor) {
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
            int newHead = _count.fetch_sub(1, std::memory_order_relaxed) - 1;
            _blockingMutex.unlock();

            if(_lowWaterMarkHandler && newHead == _lowWaterMark - 1) {
                _lowWaterMarkHandler(_waterMarkOpaque);
            }

            if(newHead && _headMonitor) {
                _headMonitor->fifo_new_head(userdata);
            }
            return true;
        }
    }

    int capacity() {
        return _capacity;
    }

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

    std::atomic<int>              _tail;
    std::atomic<int>              _head;
    std::atomic<int>              _count;

    Element *                     _array;
    int                           _natail;
    int                           _nahead;

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
