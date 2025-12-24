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
    auto duration = std::chrono::milliseconds(msecs);
    retv = m->try_acquire_for(duration) ? 0 : 1;
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
