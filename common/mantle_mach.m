#import "mantle_mach.h"
#import <Foundation/Foundation.h>
#import <bootstrap.h>
#import <servers/bootstrap.h>
#import <libproc.h>
#import <pthread.h>
#import <os/log.h>

static os_log_t mantle_log(void) {
    static os_log_t log = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.mantle", "mach");
    });
    return log;
}

#define LOG_ERROR(fmt, ...) os_log_error(mantle_log(), fmt, ##__VA_ARGS__)
#define LOG_INFO(fmt, ...) os_log_info(mantle_log(), fmt, ##__VA_ARGS__)
#define LOG_DEBUG(fmt, ...) os_log_debug(mantle_log(), fmt, ##__VA_ARGS__)

#pragma mark - JSON Helpers

static NSData *json_encode(NSDictionary *dict) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:&error];
    if (error) {
        LOG_ERROR("JSON encode failed: %{public}@", error.localizedDescription);
        return nil;
    }
    return data;
}

static NSDictionary *json_decode(const char *json, uint32_t len) {
    NSData *data = [NSData dataWithBytes:json length:len];
    NSError *error = nil;
    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error) {
        LOG_ERROR("JSON decode failed: %{public}@", error.localizedDescription);
        return nil;
    }
    if (![dict isKindOfClass:[NSDictionary class]]) {
        LOG_ERROR("JSON root is not a dictionary");
        return nil;
    }
    return dict;
}

#pragma mark - Server Implementation

struct mantle_server {
    char service_name[256];
    mach_port_t service_port;
    dispatch_source_t listen_source;
    dispatch_queue_t queue;

    // Connected clients
    mantle_client_info_t clients[MANTLE_MAX_CLIENTS];
    size_t client_count;
    pthread_mutex_t clients_lock;

    // Handlers
    mantle_client_event_t client_handler;

    // Pending calls waiting for response
    NSMutableDictionary<NSNumber *, void (^)(NSDictionary *, NSError *)> *pending_calls;
    pthread_mutex_t pending_lock;

    // Call ID counter
    uint32_t next_call_id;
};

mantle_server_t *mantle_server_create(const char *service_name) {
    if (!service_name) {
        LOG_ERROR("mantle_server_create: service_name is NULL");
        return NULL;
    }

    mantle_server_t *server = calloc(1, sizeof(mantle_server_t));
    if (!server) {
        LOG_ERROR("mantle_server_create: failed to allocate server");
        return NULL;
    }

    strlcpy(server->service_name, service_name, sizeof(server->service_name));
    pthread_mutex_init(&server->clients_lock, NULL);
    pthread_mutex_init(&server->pending_lock, NULL);
    server->pending_calls = [NSMutableDictionary new];
    server->next_call_id = 1;

    // Create the service port
    kern_return_t kr = mach_port_allocate(mach_task_self(),
                                          MACH_PORT_RIGHT_RECEIVE,
                                          &server->service_port);
    if (kr != KERN_SUCCESS) {
        LOG_ERROR("mantle_server_create: mach_port_allocate failed: %d", kr);
        free(server);
        return NULL;
    }

    // Add send right so we can pass the port to bootstrap
    kr = mach_port_insert_right(mach_task_self(),
                                server->service_port,
                                server->service_port,
                                MACH_MSG_TYPE_MAKE_SEND);
    if (kr != KERN_SUCCESS) {
        LOG_ERROR("mantle_server_create: mach_port_insert_right failed: %d", kr);
        mach_port_deallocate(mach_task_self(), server->service_port);
        free(server);
        return NULL;
    }

    // Register with bootstrap using check_in first (preferred for launchd),
    // fall back to register for standalone processes
    kr = bootstrap_check_in(bootstrap_port, (char *)service_name, &server->service_port);
    if (kr != KERN_SUCCESS) {
        // Fall back to deprecated register for non-launchd managed services
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        kr = bootstrap_register(bootstrap_port, (char *)service_name, server->service_port);
        #pragma clang diagnostic pop
        if (kr != KERN_SUCCESS) {
            LOG_ERROR("mantle_server_create: bootstrap_check_in/register failed: %d", kr);
            mach_port_deallocate(mach_task_self(), server->service_port);
            free(server);
            return NULL;
        }
    }

    LOG_INFO("mantle_server_create: registered service '%{public}s' on port %d",
             service_name, server->service_port);

    return server;
}

static void server_handle_registration(mantle_server_t *server, mantle_register_msg_t *msg) {
    // Validate the port descriptor
    mach_port_t client_port = msg->client_port.name;

    LOG_INFO("server: registration from pid %d, port name=%d, type=%d, disposition=%d",
             msg->client_pid, client_port, msg->client_port.type, msg->client_port.disposition);

    if (client_port == MACH_PORT_NULL || client_port == MACH_PORT_DEAD) {
        LOG_ERROR("server: invalid client port from pid %d", msg->client_pid);
        return;
    }

    pthread_mutex_lock(&server->clients_lock);

    // Check if already registered
    for (size_t i = 0; i < server->client_count; i++) {
        if (server->clients[i].pid == msg->client_pid) {
            // Update existing client - deallocate old port if different
            if (server->clients[i].send_port != client_port &&
                server->clients[i].send_port != MACH_PORT_NULL) {
                mach_port_deallocate(mach_task_self(), server->clients[i].send_port);
            }
            server->clients[i].send_port = client_port;
            server->clients[i].active = true;
            strlcpy(server->clients[i].process_name, msg->process_name,
                    sizeof(server->clients[i].process_name));

            mantle_client_info_t client_copy = server->clients[i];
            pthread_mutex_unlock(&server->clients_lock);

            LOG_INFO("server: updated client %{public}s (pid %d)", msg->process_name, msg->client_pid);

            if (server->client_handler) {
                server->client_handler(&client_copy, true);
            }
            return;
        }
    }

    // Add new client
    if (server->client_count < MANTLE_MAX_CLIENTS) {
        mantle_client_info_t *client = &server->clients[server->client_count++];
        client->pid = msg->client_pid;
        client->send_port = client_port;
        client->active = true;
        strlcpy(client->process_name, msg->process_name, sizeof(client->process_name));

        mantle_client_info_t client_copy = *client;
        pthread_mutex_unlock(&server->clients_lock);

        LOG_INFO("server: registered new client %{public}s (pid %d, port %d)",
                 msg->process_name, msg->client_pid, client_port);

        if (server->client_handler) {
            server->client_handler(&client_copy, true);
        }
    } else {
        pthread_mutex_unlock(&server->clients_lock);
        LOG_ERROR("server: max clients reached, rejecting %{public}s", msg->process_name);
    }
}

static void server_handle_response(mantle_server_t *server, mantle_msg_t *msg) {
    NSDictionary *response = json_decode(msg->json, msg->json_len);
    if (!response) return;

    NSNumber *call_id = response[@"id"];
    if (!call_id) {
        LOG_ERROR("server: response missing 'id' field");
        return;
    }

    pthread_mutex_lock(&server->pending_lock);
    void (^completion)(NSDictionary *, NSError *) = server->pending_calls[call_id];
    if (completion) {
        [server->pending_calls removeObjectForKey:call_id];
    }
    pthread_mutex_unlock(&server->pending_lock);

    if (completion) {
        NSError *error = nil;
        if (response[@"error"]) {
            error = [NSError errorWithDomain:@"MantleFFI" code:1
                     userInfo:@{NSLocalizedDescriptionKey: response[@"error"]}];
        }
        completion(response, error);
    }
}

static void server_handle_message(mantle_server_t *server) {
    @autoreleasepool {
        // Buffer for receiving messages
        union {
            mantle_register_msg_t reg;
            mantle_msg_t msg;
            uint8_t bytes[sizeof(mantle_msg_t) + 1024];
        } buffer;

        mach_msg_header_t *hdr = (mach_msg_header_t *)&buffer;

        kern_return_t kr = mach_msg(hdr,
                                    MACH_RCV_MSG | MACH_RCV_LARGE,
                                    0,
                                    sizeof(buffer),
                                    server->service_port,
                                    MACH_MSG_TIMEOUT_NONE,
                                    MACH_PORT_NULL);

        if (kr != KERN_SUCCESS) {
            LOG_ERROR("server: mach_msg receive failed: %d", kr);
            return;
        }

        // msgh_id == 1 is registration, msgh_id == 2 is FFI response
        if (hdr->msgh_id == 1) {
            server_handle_registration(server, &buffer.reg);
        } else if (hdr->msgh_id == 2) {
            server_handle_response(server, &buffer.msg);
        } else {
            LOG_DEBUG("server: received unknown message id %d", hdr->msgh_id);
        }
    }
}

kern_return_t mantle_server_start(mantle_server_t *server, dispatch_queue_t queue) {
    if (!server || !queue) {
        return KERN_INVALID_ARGUMENT;
    }

    server->queue = queue;

    // Create dispatch source for the service port
    server->listen_source = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV,
                                                   server->service_port,
                                                   0,
                                                   queue);
    if (!server->listen_source) {
        LOG_ERROR("server: failed to create dispatch source");
        return KERN_FAILURE;
    }

    dispatch_source_set_event_handler(server->listen_source, ^{
        server_handle_message(server);
    });

    dispatch_source_set_cancel_handler(server->listen_source, ^{
        mach_port_mod_refs(mach_task_self(), server->service_port,
                          MACH_PORT_RIGHT_RECEIVE, -1);
    });

    dispatch_resume(server->listen_source);

    LOG_INFO("server: started listening on port %d", server->service_port);
    return KERN_SUCCESS;
}

void mantle_server_set_client_handler(mantle_server_t *server, mantle_client_event_t handler) {
    if (server) {
        server->client_handler = [handler copy];
    }
}

void mantle_server_call(mantle_server_t *server,
                        pid_t client_pid,
                        NSDictionary *call,
                        void (^completion)(NSDictionary *response, NSError *error)) {
    if (!server || !call) {
        if (completion) {
            completion(nil, [NSError errorWithDomain:@"MantleFFI" code:1
                            userInfo:@{NSLocalizedDescriptionKey: @"Invalid arguments"}]);
        }
        return;
    }

    // Find client's send port
    mach_port_t target_port = MACH_PORT_NULL;
    pthread_mutex_lock(&server->clients_lock);
    for (size_t i = 0; i < server->client_count; i++) {
        if (server->clients[i].pid == client_pid && server->clients[i].active) {
            target_port = server->clients[i].send_port;
            break;
        }
    }
    pthread_mutex_unlock(&server->clients_lock);

    if (target_port == MACH_PORT_NULL) {
        LOG_ERROR("server: client pid %d not found", client_pid);
        if (completion) {
            completion(nil, [NSError errorWithDomain:@"MantleFFI" code:2
                            userInfo:@{NSLocalizedDescriptionKey: @"Client not found"}]);
        }
        return;
    }

    // Generate call ID and add to call dict
    uint32_t call_id = __sync_fetch_and_add(&server->next_call_id, 1);
    NSMutableDictionary *call_with_id = [call mutableCopy];
    call_with_id[@"id"] = @(call_id);

    // Store completion handler
    if (completion) {
        pthread_mutex_lock(&server->pending_lock);
        server->pending_calls[@(call_id)] = [completion copy];
        pthread_mutex_unlock(&server->pending_lock);
    }

    // Encode to JSON
    NSData *json_data = json_encode(call_with_id);
    if (!json_data || json_data.length > MANTLE_MSG_MAX_SIZE) {
        LOG_ERROR("server: JSON encode failed or too large");
        if (completion) {
            pthread_mutex_lock(&server->pending_lock);
            [server->pending_calls removeObjectForKey:@(call_id)];
            pthread_mutex_unlock(&server->pending_lock);
            completion(nil, [NSError errorWithDomain:@"MantleFFI" code:3
                            userInfo:@{NSLocalizedDescriptionKey: @"JSON encode failed"}]);
        }
        return;
    }

    // Build message
    mantle_msg_t msg = {0};
    msg.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
    msg.header.msgh_remote_port = target_port;
    msg.header.msgh_local_port = MACH_PORT_NULL;
    msg.header.msgh_id = 3;  // FFI call

    msg.json_len = (uint32_t)json_data.length;
    memcpy(msg.json, json_data.bytes, json_data.length);

    // Calculate actual send size: header + json_len field + json data (rounded up)
    mach_msg_size_t send_size = sizeof(mach_msg_header_t) + sizeof(uint32_t) + msg.json_len;
    // Round up to 4-byte boundary
    send_size = (send_size + 3) & ~3;
    msg.header.msgh_size = send_size;

    kern_return_t kr = mach_msg(&msg.header,
                                MACH_SEND_MSG,
                                send_size,
                                0,
                                MACH_PORT_NULL,
                                MACH_MSG_TIMEOUT_NONE,
                                MACH_PORT_NULL);

    if (kr != KERN_SUCCESS) {
        LOG_ERROR("server: send to pid %d (port %d) failed: %s (%d)",
                  client_pid, target_port, mach_error_string(kr), kr);
        if (completion) {
            pthread_mutex_lock(&server->pending_lock);
            [server->pending_calls removeObjectForKey:@(call_id)];
            pthread_mutex_unlock(&server->pending_lock);
            NSString *errMsg = [NSString stringWithFormat:@"Send failed: %s", mach_error_string(kr)];
            completion(nil, [NSError errorWithDomain:@"MantleFFI" code:kr
                            userInfo:@{NSLocalizedDescriptionKey: errMsg}]);
        }
    } else {
        LOG_DEBUG("server: sent call %u to pid %d (port %d)", call_id, client_pid, target_port);
    }
}

void mantle_server_broadcast(mantle_server_t *server, NSDictionary *call) {
    if (!server || !call) return;

    pthread_mutex_lock(&server->clients_lock);
    for (size_t i = 0; i < server->client_count; i++) {
        if (server->clients[i].active) {
            pid_t pid = server->clients[i].pid;
            pthread_mutex_unlock(&server->clients_lock);

            mantle_server_call(server, pid, call, nil);

            pthread_mutex_lock(&server->clients_lock);
        }
    }
    pthread_mutex_unlock(&server->clients_lock);
}

NSArray<NSNumber *> *mantle_server_get_client_pids(mantle_server_t *server) {
    if (!server) return @[];

    NSMutableArray *pids = [NSMutableArray new];
    pthread_mutex_lock(&server->clients_lock);
    for (size_t i = 0; i < server->client_count; i++) {
        if (server->clients[i].active) {
            [pids addObject:@(server->clients[i].pid)];
        }
    }
    pthread_mutex_unlock(&server->clients_lock);

    return pids;
}

void mantle_server_foreach_client(mantle_server_t *server, mantle_client_foreach_t callback) {
    if (!server || !callback) return;

    pthread_mutex_lock(&server->clients_lock);
    for (size_t i = 0; i < server->client_count; i++) {
        if (server->clients[i].active) {
            mantle_client_info_t client_copy = server->clients[i];
            pthread_mutex_unlock(&server->clients_lock);

            callback(&client_copy);

            pthread_mutex_lock(&server->clients_lock);
        }
    }
    pthread_mutex_unlock(&server->clients_lock);
}

void mantle_server_destroy(mantle_server_t *server) {
    if (!server) return;

    if (server->listen_source) {
        dispatch_source_cancel(server->listen_source);
    }

    pthread_mutex_destroy(&server->clients_lock);
    pthread_mutex_destroy(&server->pending_lock);
    free(server);

    LOG_INFO("server: destroyed");
}

#pragma mark - Client Implementation

struct mantle_client {
    char service_name[256];
    mach_port_t server_port;      // Port to send to server
    mach_port_t receive_port;     // Our port for receiving commands
    dispatch_source_t cmd_source;
    dispatch_queue_t queue;
    pid_t pid;
    char process_name[256];
    bool connected;

    // FFI handler
    mantle_ffi_handler_t ffi_handler;
};

mantle_client_t *mantle_client_connect(const char *service_name) {
    if (!service_name) {
        LOG_ERROR("mantle_client_connect: service_name is NULL");
        return NULL;
    }

    mantle_client_t *client = calloc(1, sizeof(mantle_client_t));
    if (!client) {
        LOG_ERROR("mantle_client_connect: failed to allocate client");
        return NULL;
    }

    strlcpy(client->service_name, service_name, sizeof(client->service_name));
    client->pid = getpid();
    proc_name(client->pid, client->process_name, sizeof(client->process_name));

    // Look up the server's service port
    kern_return_t kr = bootstrap_look_up(bootstrap_port,
                                         (char *)service_name,
                                         &client->server_port);
    if (kr != KERN_SUCCESS) {
        LOG_ERROR("mantle_client_connect: bootstrap_look_up failed for '%{public}s': %d",
                  service_name, kr);
        free(client);
        return NULL;
    }

    // Create our receive port for incoming commands
    kr = mach_port_allocate(mach_task_self(),
                            MACH_PORT_RIGHT_RECEIVE,
                            &client->receive_port);
    if (kr != KERN_SUCCESS) {
        LOG_ERROR("mantle_client_connect: mach_port_allocate failed: %d", kr);
        mach_port_deallocate(mach_task_self(), client->server_port);
        free(client);
        return NULL;
    }

    // Add send right to pass to server
    kr = mach_port_insert_right(mach_task_self(),
                                client->receive_port,
                                client->receive_port,
                                MACH_MSG_TYPE_MAKE_SEND);
    if (kr != KERN_SUCCESS) {
        LOG_ERROR("mantle_client_connect: mach_port_insert_right failed: %d", kr);
        mach_port_deallocate(mach_task_self(), client->server_port);
        mach_port_deallocate(mach_task_self(), client->receive_port);
        free(client);
        return NULL;
    }

    // NOTE: Don't send registration yet - wait until mantle_client_start() is called
    // so the client is ready to receive messages

    client->connected = false;  // Not fully connected until start() completes registration
    LOG_INFO("mantle_client_connect: prepared connection to '%{public}s' as %{public}s (pid %d)",
             service_name, client->process_name, client->pid);

    return client;
}

void mantle_client_set_handler(mantle_client_t *client, mantle_ffi_handler_t handler) {
    if (client) {
        client->ffi_handler = [handler copy];
    }
}

static void client_send_response(mantle_client_t *client, NSDictionary *response) {
    NSData *json_data = json_encode(response);
    if (!json_data || json_data.length > MANTLE_MSG_MAX_SIZE) {
        LOG_ERROR("client: response JSON encode failed or too large");
        return;
    }

    mantle_msg_t msg = {0};
    msg.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
    msg.header.msgh_remote_port = client->server_port;
    msg.header.msgh_local_port = MACH_PORT_NULL;
    msg.header.msgh_id = 2;  // FFI response

    msg.json_len = (uint32_t)json_data.length;
    memcpy(msg.json, json_data.bytes, json_data.length);

    // Calculate send size with alignment
    mach_msg_size_t send_size = sizeof(mach_msg_header_t) + sizeof(uint32_t) + msg.json_len;
    send_size = (send_size + 3) & ~3;
    msg.header.msgh_size = send_size;

    kern_return_t kr = mach_msg(&msg.header,
                                MACH_SEND_MSG,
                                send_size,
                                0,
                                MACH_PORT_NULL,
                                MACH_MSG_TIMEOUT_NONE,
                                MACH_PORT_NULL);

    if (kr != KERN_SUCCESS) {
        LOG_ERROR("client: response send failed: %d", kr);
    }
}

static void client_handle_message(mantle_client_t *client) {
    @autoreleasepool {
        mantle_msg_t msg = {0};

        kern_return_t kr = mach_msg(&msg.header,
                                    MACH_RCV_MSG,
                                    0,
                                    sizeof(msg),
                                    client->receive_port,
                                    MACH_MSG_TIMEOUT_NONE,
                                    MACH_PORT_NULL);

        if (kr != KERN_SUCCESS) {
            LOG_ERROR("client: mach_msg receive failed: %d", kr);
            return;
        }

        if (msg.header.msgh_id != 3) {
            LOG_DEBUG("client: received unknown message id %d", msg.header.msgh_id);
            return;
        }

        NSDictionary *call = json_decode(msg.json, msg.json_len);
        if (!call) {
            LOG_ERROR("client: failed to decode FFI call");
            return;
        }

        LOG_DEBUG("client: received FFI call: %{public}@", call[@"method"]);

        if (client->ffi_handler) {
            NSNumber *call_id = call[@"id"];

            client->ffi_handler(call, ^(NSDictionary *response) {
                @autoreleasepool {
                    // Build response with matching ID
                    NSMutableDictionary *full_response = [NSMutableDictionary new];
                    if (call_id) {
                        full_response[@"id"] = call_id;
                    }
                    if (response) {
                        [full_response addEntriesFromDictionary:response];
                    }
                    client_send_response(client, full_response);
                }
            });
        }
    }
}

kern_return_t mantle_client_start(mantle_client_t *client, dispatch_queue_t queue) {
    if (!client || !queue) {
        return KERN_INVALID_ARGUMENT;
    }

    client->queue = queue;

    // Create dispatch source for receiving commands
    client->cmd_source = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV,
                                                client->receive_port,
                                                0,
                                                queue);
    if (!client->cmd_source) {
        LOG_ERROR("client: failed to create dispatch source");
        return KERN_FAILURE;
    }

    dispatch_source_set_event_handler(client->cmd_source, ^{
        client_handle_message(client);
    });

    dispatch_source_set_cancel_handler(client->cmd_source, ^{
        mach_port_mod_refs(mach_task_self(), client->receive_port,
                          MACH_PORT_RIGHT_RECEIVE, -1);
    });

    dispatch_resume(client->cmd_source);

    LOG_INFO("client: started listening on port %d", client->receive_port);

    // Now send registration to server - we're ready to receive messages
    mantle_register_msg_t reg_msg = {0};
    reg_msg.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
    reg_msg.header.msgh_size = sizeof(reg_msg);
    reg_msg.header.msgh_remote_port = client->server_port;
    reg_msg.header.msgh_local_port = MACH_PORT_NULL;
    reg_msg.header.msgh_id = 1;  // Registration message

    reg_msg.body.msgh_descriptor_count = 1;
    reg_msg.client_port.name = client->receive_port;
    reg_msg.client_port.disposition = MACH_MSG_TYPE_MAKE_SEND;
    reg_msg.client_port.type = MACH_MSG_PORT_DESCRIPTOR;

    reg_msg.client_pid = client->pid;
    strlcpy(reg_msg.process_name, client->process_name, sizeof(reg_msg.process_name));

    kern_return_t kr = mach_msg(&reg_msg.header,
                                MACH_SEND_MSG,
                                sizeof(reg_msg),
                                0,
                                MACH_PORT_NULL,
                                MACH_MSG_TIMEOUT_NONE,
                                MACH_PORT_NULL);

    if (kr != KERN_SUCCESS) {
        LOG_ERROR("client: registration send failed: %s (%d)", mach_error_string(kr), kr);
        dispatch_source_cancel(client->cmd_source);
        return kr;
    }

    client->connected = true;
    LOG_INFO("client: registered with server as %{public}s (pid %d)",
             client->process_name, client->pid);

    return KERN_SUCCESS;
}

void mantle_client_disconnect(mantle_client_t *client) {
    if (!client) return;

    if (client->cmd_source) {
        dispatch_source_cancel(client->cmd_source);
    }

    if (client->server_port != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), client->server_port);
    }

    client->connected = false;
    free(client);

    LOG_INFO("client: disconnected");
}
