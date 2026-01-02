#ifndef _MANTLE_IPC_H_
#define _MANTLE_IPC_H_

#include <mach/mach.h>
#include <mach/message.h>
#include <stdint.h>
#include <sys/types.h>

// Bootstrap service name for wm_init's Mach port
#define MANTLE_SERVICE_NAME "com.mantle.wm_init"

// Message IDs
typedef enum {
    MANTLE_MSG_PING = 1,
    MANTLE_MSG_PONG = 2,
    MANTLE_MSG_REGISTER_CLIENT = 10,
    MANTLE_MSG_CLIENT_REGISTERED = 11,
    MANTLE_MSG_WINDOW_EVENT = 20,
    MANTLE_MSG_GET_WINDOWS = 30,
    MANTLE_MSG_WINDOWS_LIST = 31,

    // FFI messages (server -> client)
    MANTLE_MSG_FFI_CALL = 100,
    MANTLE_MSG_FFI_RESULT = 101,
} mantle_msg_id_t;

// FFI call types
typedef enum {
    FFI_OBJC_MSG_SEND = 1,       // [target selector:args...]
    FFI_OBJC_GET_CLASS = 2,      // objc_getClass("ClassName")
    FFI_OBJC_ALLOC_INIT = 3,     // [[Class alloc] init]
    FFI_OBJC_GET_PROPERTY = 4,   // [obj valueForKey:@"prop"]
    FFI_OBJC_SET_PROPERTY = 5,   // [obj setValue:val forKey:@"prop"]
    FFI_C_DLSYM_CALL = 10,       // Call C function by symbol
    FFI_C_DIRECT_CALL = 11,      // Call C function with raw libffi
    FFI_EVAL_EXPRESSION = 20,    // Evaluate an expression string
} mantle_ffi_type_t;

// FFI value types for argument/return encoding
typedef enum {
    FFI_VAL_VOID = 0,
    FFI_VAL_INT8 = 1,
    FFI_VAL_INT16 = 2,
    FFI_VAL_INT32 = 3,
    FFI_VAL_INT64 = 4,
    FFI_VAL_UINT8 = 5,
    FFI_VAL_UINT16 = 6,
    FFI_VAL_UINT32 = 7,
    FFI_VAL_UINT64 = 8,
    FFI_VAL_FLOAT = 9,
    FFI_VAL_DOUBLE = 10,
    FFI_VAL_BOOL = 11,
    FFI_VAL_STRING = 12,         // null-terminated string in data
    FFI_VAL_OBJECT = 13,         // Objective-C object (pointer as uint64)
    FFI_VAL_SELECTOR = 14,       // Selector name as string
    FFI_VAL_CLASS = 15,          // Class name as string
    FFI_VAL_POINTER = 16,        // Raw pointer as uint64
    FFI_VAL_DATA = 17,           // Raw bytes
    FFI_VAL_ERROR = 255,         // Error occurred
} mantle_ffi_val_type_t;

// Single FFI value (for arguments and return values)
typedef struct {
    uint8_t type;                // mantle_ffi_val_type_t
    uint8_t _pad[3];
    uint32_t size;               // size of the value in bytes
    union {
        int8_t i8;
        int16_t i16;
        int32_t i32;
        int64_t i64;
        uint8_t u8;
        uint16_t u16;
        uint32_t u32;
        uint64_t u64;
        float f32;
        double f64;
        uint8_t b;
        uint64_t ptr;            // pointer/object/class as address
    } value;
    uint32_t data_offset;        // offset in data buffer for strings/data
    uint32_t data_len;           // length of string/data
} mantle_ffi_value_t;

#define MANTLE_FFI_MAX_ARGS 16
#define MANTLE_FFI_DATA_SIZE 4096

// Base message structure for simple messages
typedef struct {
    mach_msg_header_t header;
    mach_msg_id_t msg_id;
    int32_t payload;
} mantle_msg_simple_t;

// Message with reply port for bidirectional communication
typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t reply_port;
    mach_msg_id_t msg_id;
    int32_t payload;
} mantle_msg_with_reply_t;

// Message with inline data (for larger payloads)
typedef struct {
    mach_msg_header_t header;
    mach_msg_id_t msg_id;
    uint32_t data_len;
    char data[1024];
} mantle_msg_data_t;

// Client registration message (includes PID and reply port)
typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t client_port;
    mach_msg_id_t msg_id;
    pid_t client_pid;
    char process_name[256];
} mantle_msg_register_t;

// FFI call message (server -> client)
typedef struct {
    mach_msg_header_t header;
    mach_msg_id_t msg_id;           // MANTLE_MSG_FFI_CALL
    uint32_t call_id;               // unique ID for matching response
    uint8_t ffi_type;               // mantle_ffi_type_t
    uint8_t arg_count;
    uint8_t _pad[2];
    mantle_ffi_value_t target;      // object/class for method calls
    mantle_ffi_value_t args[MANTLE_FFI_MAX_ARGS];
    char data[MANTLE_FFI_DATA_SIZE]; // string/data buffer
} mantle_msg_ffi_call_t;

// FFI result message (client -> server)
typedef struct {
    mach_msg_header_t header;
    mach_msg_id_t msg_id;           // MANTLE_MSG_FFI_RESULT
    uint32_t call_id;               // matches the call
    uint8_t success;                // 1 = success, 0 = error
    uint8_t _pad[3];
    mantle_ffi_value_t result;      // return value or error
    char data[MANTLE_FFI_DATA_SIZE]; // string/data buffer for result
} mantle_msg_ffi_result_t;

// Maximum message size
#define MANTLE_MSG_MAX_SIZE sizeof(mantle_msg_ffi_call_t)

// Helper macros
#define MANTLE_MSG_SIMPLE_SIZE (sizeof(mantle_msg_simple_t))
#define MANTLE_MSG_WITH_REPLY_SIZE (sizeof(mantle_msg_with_reply_t))

#endif // _MANTLE_IPC_H_
