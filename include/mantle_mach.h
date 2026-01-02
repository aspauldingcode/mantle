#ifndef _MANTLE_MACH_H_
#define _MANTLE_MACH_H_

#include <mach/mach.h>
#include <mach/message.h>
#include <dispatch/dispatch.h>
#include <stdint.h>
#include <stdbool.h>
#include <sys/types.h>

#ifdef __OBJC__
#import <Foundation/Foundation.h>
#endif

// Forward declarations
typedef struct mantle_server mantle_server_t;
typedef struct mantle_client mantle_client_t;

// Maximum sizes
#define MANTLE_MSG_MAX_SIZE 65536
#define MANTLE_MAX_CLIENTS 256

// Message structure - JSON payload
// All commands are FFI calls encoded as JSON:
// {
//   "id": <uint32>,           // unique call ID for matching responses
//   "method": "<string>",     // method/function name
//   "target": "<string>",     // optional: object pointer as hex string, class name, or null
//   "args": [...]             // array of arguments
// }
//
// Response format:
// {
//   "id": <uint32>,           // matches request id
//   "result": <any>,          // return value (null for void)
//   "error": "<string>"       // optional: error message if failed
// }

typedef struct {
    mach_msg_header_t header;
    uint32_t json_len;                       // Length of JSON payload
    char json[MANTLE_MSG_MAX_SIZE];          // JSON-encoded FFI call/response
} mantle_msg_t;

// Client registration message
typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t client_port;  // Client's receive port for commands
    pid_t client_pid;
    char process_name[256];
} mantle_register_msg_t;

// Connected client info (server-side)
typedef struct {
    pid_t pid;
    char process_name[256];
    mach_port_t send_port;  // Port to send commands to this client
    bool active;
} mantle_client_info_t;

#ifdef __OBJC__

// Callback types (Objective-C)
typedef void (^mantle_ffi_handler_t)(NSDictionary *call, void (^reply)(NSDictionary *response));
typedef void (^mantle_client_event_t)(mantle_client_info_t *client, bool connected);
typedef void (^mantle_client_foreach_t)(mantle_client_info_t *client);

#pragma mark - Server API (for wm_init)

// Create a Mach service with the given name
mantle_server_t *mantle_server_create(const char *service_name);

// Start listening for client connections
kern_return_t mantle_server_start(mantle_server_t *server, dispatch_queue_t queue);

// Set handler for client connect/disconnect events
void mantle_server_set_client_handler(mantle_server_t *server, mantle_client_event_t handler);

// Send an FFI call to a specific client, with optional response handler
// call dict: { "method": "...", "target": "...", "args": [...] }
// Response comes via the completion block
void mantle_server_call(mantle_server_t *server,
                        pid_t client_pid,
                        NSDictionary *call,
                        void (^completion)(NSDictionary *response, NSError *error));

// Send an FFI call to all connected clients (no response expected)
void mantle_server_broadcast(mantle_server_t *server, NSDictionary *call);

// Get list of connected clients
NSArray<NSNumber *> *mantle_server_get_client_pids(mantle_server_t *server);

// Iterate over all connected clients
void mantle_server_foreach_client(mantle_server_t *server, mantle_client_foreach_t callback);

// Destroy the server
void mantle_server_destroy(mantle_server_t *server);

#pragma mark - Client API (for libcore/wm_core)

// Connect to the Mach service
mantle_client_t *mantle_client_connect(const char *service_name);

// Set handler for incoming FFI calls from server
// Handler receives the call dict and a reply block to send response
void mantle_client_set_handler(mantle_client_t *client, mantle_ffi_handler_t handler);

// Start listening for commands
kern_return_t mantle_client_start(mantle_client_t *client, dispatch_queue_t queue);

// Disconnect and clean up
void mantle_client_disconnect(mantle_client_t *client);

#endif // __OBJC__

#endif // _MANTLE_MACH_H_
