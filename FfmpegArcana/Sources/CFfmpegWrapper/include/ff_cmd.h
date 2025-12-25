/**
 * ff_cmd.h
 * 
 * Pooled command structures with explicit ref counting for media pipelines.
 * COM-style AddRef/Release - no hidden memory management magic.
 */

#ifndef FF_CMD_H
#define FF_CMD_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// -----------------------------------------------------------------------------
// Ref counting interface - COM style
// -----------------------------------------------------------------------------

typedef struct IFFRefCounted IFFRefCounted;

typedef int32_t (*FFAddRefFunc)(void* self);
typedef int32_t (*FFReleaseFunc)(void* self);

struct IFFRefCounted {
    FFAddRefFunc AddRef;
    FFReleaseFunc Release;
};

// Helper macros for IFFRefCounted* pointers
#define FF_ADDREF(obj) ((obj) ? (obj)->AddRef((void*)(obj)) : 0)
#define FF_RELEASE(obj) ((obj) ? (obj)->Release((void*)(obj)) : 0)

// Helper macros for FFCmd* pointers (go through .ref member)
#define FF_CMD_ADDREF(cmd) ((cmd) ? (cmd)->ref.AddRef((void*)(cmd)) : 0)
#define FF_CMD_RELEASE(cmd) ((cmd) ? (cmd)->ref.Release((void*)(cmd)) : 0)

// -----------------------------------------------------------------------------
// Command types
// -----------------------------------------------------------------------------

typedef enum {
    FF_CMD_NONE = 0,        // Empty/invalid
    FF_CMD_FRAME,           // data is AVFrame*
    FF_CMD_PACKET,          // data is AVPacket*
    FF_CMD_FLUSH,           // Flush buffers, no data
    FF_CMD_EOS,             // End of stream, no data
    FF_CMD_SEEK,            // Seek request, data is FFSeekParams*
    FF_CMD_CONFIG,          // Configuration change, data is user-defined
    FF_CMD_USER = 0x1000    // User-defined types start here
} FFCmdType;

// -----------------------------------------------------------------------------
// Seek parameters (example of a command payload)
// -----------------------------------------------------------------------------

typedef struct {
    double position;        // Seek position in seconds
    uint32_t flags;         // Seek flags
} FFSeekParams;

// -----------------------------------------------------------------------------
// Command structure - pooled
// -----------------------------------------------------------------------------

typedef struct FFCmd FFCmd;
typedef struct FFCmdPool FFCmdPool;

struct FFCmd {
    // Ref counting interface - must be first
    IFFRefCounted ref;
    
    // Command data
    FFCmdType type;
    void* data;                 // Payload pointer
    IFFRefCounted* data_ref;    // Ref counting interface for data (if applicable)
    int64_t pts;                // Presentation timestamp (or AV_NOPTS_VALUE)
    int64_t dts;                // Decode timestamp (or AV_NOPTS_VALUE)
    uint32_t flags;             // Command-specific flags
    uint32_t stream_index;      // Stream index (for packets/frames)
    
    // User context
    void* user_data;
    
    // Internal - do not touch
    FFCmdPool* _pool;           // Owning pool
    FFCmd* _next;               // Free list linkage
    int32_t _refcount;          // Current ref count
};

// -----------------------------------------------------------------------------
// Command pool
// -----------------------------------------------------------------------------

/**
 * Create a command pool.
 * @param initial_size Number of commands to pre-allocate
 * @param max_size Maximum pool size (0 = unlimited)
 * @return Pool handle or NULL on failure
 */
FFCmdPool* ff_cmd_pool_create(uint32_t initial_size, uint32_t max_size);

/**
 * Destroy a command pool.
 * WARNING: All commands must be released before destroying the pool.
 */
void ff_cmd_pool_destroy(FFCmdPool* pool);

/**
 * Acquire a command from the pool.
 * Command is initialized with refcount=1, type=FF_CMD_NONE, all fields zeroed.
 * @return Command or NULL if pool exhausted and at max size
 */
FFCmd* ff_cmd_pool_acquire(FFCmdPool* pool);

/**
 * Get pool statistics.
 */
uint32_t ff_cmd_pool_total_count(FFCmdPool* pool);
uint32_t ff_cmd_pool_free_count(FFCmdPool* pool);
uint32_t ff_cmd_pool_in_use_count(FFCmdPool* pool);

// -----------------------------------------------------------------------------
// Command helpers
// -----------------------------------------------------------------------------

/**
 * Initialize a command for a specific type.
 * Clears all fields and sets the type. Does not affect refcount.
 */
void ff_cmd_init(FFCmd* cmd, FFCmdType type);

/**
 * Set command data with optional ref counting interface.
 * If data_ref is provided, AddRef is called on the data.
 */
void ff_cmd_set_data(FFCmd* cmd, void* data, IFFRefCounted* data_ref);

/**
 * Clear command data.
 * If data has a ref counting interface, Release is called.
 */
void ff_cmd_clear_data(FFCmd* cmd);

/**
 * Check if command is a sentinel (EOS or FLUSH).
 */
static inline bool ff_cmd_is_sentinel(FFCmd* cmd) {
    return cmd && (cmd->type == FF_CMD_EOS || cmd->type == FF_CMD_FLUSH);
}

/**
 * Check if command carries media data.
 */
static inline bool ff_cmd_is_media(FFCmd* cmd) {
    return cmd && (cmd->type == FF_CMD_FRAME || cmd->type == FF_CMD_PACKET);
}

// -----------------------------------------------------------------------------
// AVFrame/AVPacket ref counting adapters
// -----------------------------------------------------------------------------

/**
 * Get a ref counting interface for AVFrame.
 * The returned interface wraps av_frame_ref/av_frame_free.
 */
IFFRefCounted* ff_frame_ref_interface(void);

/**
 * Get a ref counting interface for AVPacket.
 * The returned interface wraps av_packet_ref/av_packet_free.
 */
IFFRefCounted* ff_packet_ref_interface(void);

// -----------------------------------------------------------------------------
// Command FIFO
// -----------------------------------------------------------------------------

typedef struct FFCmdFifo FFCmdFifo;

typedef enum {
    FF_CMD_FIFO_LOCKLESS = 0,   // Single producer/consumer
    FF_CMD_FIFO_BLOCKING = 1    // Multi producer/consumer
} FFCmdFifoMode;

#define FF_CMD_FIFO_OK              0
#define FF_CMD_FIFO_INVALID_PARAMS  1
#define FF_CMD_FIFO_FLOW_DISABLED   13
#define FF_CMD_FIFO_FULL            29
#define FF_CMD_FIFO_TIMEOUT         -1

/**
 * Create a command FIFO.
 */
FFCmdFifo* ff_cmd_fifo_create(uint32_t capacity, FFCmdFifoMode mode);
void ff_cmd_fifo_destroy(FFCmdFifo* fifo);

// Flow control
void ff_cmd_fifo_set_flow_enabled(FFCmdFifo* fifo, bool enabled);
bool ff_cmd_fifo_get_flow_enabled(FFCmdFifo* fifo);

// Write operations - does NOT addref, caller transfers ownership
int ff_cmd_fifo_wait_write(FFCmdFifo* fifo);
int ff_cmd_fifo_wait_write_timed(FFCmdFifo* fifo, int msecs);
int ff_cmd_fifo_try_write(FFCmdFifo* fifo);
int ff_cmd_fifo_write(FFCmdFifo* fifo, FFCmd* cmd);

// Read operations - does NOT addref, transfers ownership to caller
int ff_cmd_fifo_wait_read(FFCmdFifo* fifo);
int ff_cmd_fifo_wait_read_timed(FFCmdFifo* fifo, int msecs);
int ff_cmd_fifo_try_read(FFCmdFifo* fifo);
int ff_cmd_fifo_read(FFCmdFifo* fifo, FFCmd** cmd);

// Preempt - push to front
int ff_cmd_fifo_preempt(FFCmdFifo* fifo, FFCmd* cmd);

// Status
int ff_cmd_fifo_count(FFCmdFifo* fifo);
bool ff_cmd_fifo_has_been_read(FFCmdFifo* fifo);

#ifdef __cplusplus
}
#endif

#endif // FF_CMD_H