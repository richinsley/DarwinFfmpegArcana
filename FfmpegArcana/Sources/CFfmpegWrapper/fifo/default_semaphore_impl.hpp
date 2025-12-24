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
