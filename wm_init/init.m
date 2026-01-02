
#import <CoreFoundation/CFRunLoop.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreVideo/CoreVideo.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <JavaScriptCore/JavaScriptCore.h>

#include <dispatch/dispatch.h>
#include <signal.h>
#include <sys/sysctl.h>
#include <sys/types.h>

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach-o/dyld_images.h>
#include <limits.h>

#import "mantle_mach.h"

// Private sandbox API declarations
extern const char *APP_SANDBOX_MACH;
extern char *sandbox_extension_issue_mach(const char *extension_class, const char *name, uint32_t flags);

static char *gSandboxToken = NULL;
static mantle_server_t *gServer = NULL;

// JavaScript runtime state
static JSContext *gContext = NULL;
static NSMutableDictionary *gTimers = nil;  // intervalId -> dispatch_source_t
static uint64_t gTimerIdCounter = 0;
static NSString *gStdlibPath = nil;
static NSString *gConfigPath = nil;
static dispatch_source_t gFileWatcher = NULL;

#pragma mark - JavaScript Conversion Helpers

// Recursively convert Foundation objects to native JSValue objects
static JSValue *foundationToJS(id obj, JSContext *context);

#pragma mark - JavaScript Runtime

static void clearAllTimers(void) {
    if (gTimers) {
        for (NSNumber *key in gTimers.allKeys) {
            dispatch_source_t timer = gTimers[key];
            if (timer) {
                dispatch_source_cancel(timer);
            }
        }
        [gTimers removeAllObjects];
    }
}

static void setupJavaScriptContext(void) {
    // Clear existing timers
    clearAllTimers();

    // Create fresh context
    gContext = [[JSContext alloc] init];

    if (!gTimers) {
        gTimers = [NSMutableDictionary new];
    }

    // Log JavaScript errors
    gContext.exceptionHandler = ^(JSContext *ctx, JSValue *exception) {
        fprintf(stderr, "[JavaScript Error] %s\n", [exception toString].UTF8String);
    };

    // Add console.log
    gContext[@"console"] = @{
        @"log": ^(JSValue *arg1, JSValue *arg2, JSValue *arg3, JSValue *arg4, JSValue *arg5, JSValue *arg6, JSValue *arg7, JSValue *arg8, JSValue *arg9, JSValue *arg10) {
            NSArray *args = @[arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9, arg10];
            NSMutableString *output = [NSMutableString string];
            for (JSValue *arg in args) {
                if ([arg isUndefined] || [arg isNull]) continue;
                if (output.length > 0) [output appendString:@" "];
                [output appendString:[arg description]];
            }
            printf("[JavaScript] %s\n", output.UTF8String);
        },
        @"error": ^(JSValue *arg1, JSValue *arg2, JSValue *arg3, JSValue *arg4, JSValue *arg5, JSValue *arg6, JSValue *arg7, JSValue *arg8, JSValue *arg9, JSValue *arg10) {
            NSArray *args = @[arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9, arg10];
            NSMutableString *output = [NSMutableString string];
            for (JSValue *arg in args) {
                if ([arg isUndefined] || [arg isNull]) continue;
                if (output.length > 0) [output appendString:@" "];
                [output appendString:[arg description]];
            }
            fprintf(stderr, "[JavaScript Error] %s\n", output.UTF8String);
        }
    };

    // Store callbacks
    gContext[@"callbacks"] = [JSValue valueWithNewObjectInContext:gContext];

    // setInterval
    gContext[@"setInterval"] = ^int(JSValue *callback, JSValue *interval) {
        if ([callback isUndefined] || [callback isNull]) return -1;

        uint64_t timerId = ++gTimerIdCounter;
        NSNumber *timerKey = @(timerId);
        NSTimeInterval intervalMs = [interval toDouble];

        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, intervalMs * NSEC_PER_MSEC), intervalMs * NSEC_PER_MSEC, 0);

        // Store in native dictionary
        gTimers[timerKey] = timer;

        __weak JSContext *weakContext = gContext;
        JSContext *currentContext = gContext;  // Capture current context
        dispatch_source_set_event_handler(timer, ^{
            @autoreleasepool {
                JSContext *strongContext = weakContext;
                // Only fire if context hasn't been replaced
                if (strongContext && strongContext == gContext && gContext == currentContext) {
                    [callback callWithArguments:@[]];
                }
            }
        });

        dispatch_resume(timer);
        return (int)timerId;
    };

    // clearInterval
    gContext[@"clearInterval"] = ^(JSValue *intervalId) {
        NSNumber *timerKey = @([intervalId toUInt32]);
        dispatch_source_t timer = gTimers[timerKey];
        if (timer) {
            dispatch_source_cancel(timer);
            [gTimers removeObjectForKey:timerKey];
        }
    };

    // setTimeout
    gContext[@"setTimeout"] = ^int(JSValue *callback, JSValue *delay) {
        if ([callback isUndefined] || [callback isNull]) return -1;

        uint64_t timerId = ++gTimerIdCounter;
        NSNumber *timerKey = @(timerId);
        NSTimeInterval delayMs = [delay toDouble];

        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, delayMs * NSEC_PER_MSEC), DISPATCH_TIME_FOREVER, 0);

        gTimers[timerKey] = timer;

        __weak JSContext *weakContext = gContext;
        JSContext *currentContext = gContext;
        dispatch_source_set_event_handler(timer, ^{
            @autoreleasepool {
                JSContext *strongContext = weakContext;
                if (strongContext && strongContext == gContext && gContext == currentContext) {
                    [callback callWithArguments:@[]];
                }
                // Clean up after firing
                [gTimers removeObjectForKey:timerKey];
            }
        });

        dispatch_resume(timer);
        return (int)timerId;
    };

    // clearTimeout (same as clearInterval)
    gContext[@"clearTimeout"] = gContext[@"clearInterval"];

    // mantle_server_call
    gContext[@"mantle_server_call"] = ^(JSValue *clientPid, JSValue *call, JSValue *callback) {
        pid_t pid = [clientPid toInt32];
        NSDictionary *callDict = [call toObject];

        if ([callback isUndefined] || [callback isNull]) {
            mantle_server_call(gServer, pid, callDict, nil);
        } else {
            NSString *callbackId = [[NSUUID UUID] UUIDString];
            gContext[@"callbacks"][callbackId] = callback;

            __weak JSContext *weakContext = gContext;

            mantle_server_call(gServer, pid, callDict, ^(NSDictionary *response, NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    @autoreleasepool {
                        JSContext *strongContext = weakContext;
                        // Only call back if context is still current (not reloaded)
                        if (strongContext && strongContext == gContext) {
                            JSValue *jsCallback = strongContext[@"callbacks"][callbackId];
                            if (jsCallback && ![jsCallback isUndefined]) {
                                if (error) {
                                    JSValue *jsError = [JSValue valueWithObject:error.localizedDescription inContext:strongContext];
                                    [jsCallback callWithArguments:@[jsError]];
                                } else {
                                    JSValue *jsNull = [JSValue valueWithNullInContext:strongContext];
                                    JSValue *jsResponse = foundationToJS(response, strongContext);
                                    [jsCallback callWithArguments:@[jsNull, jsResponse]];
                                }
                                [strongContext[@"callbacks"] deleteProperty:callbackId];
                            }
                        }
                    }
                });
            });
        }
    };

    // mantle_server_broadcast
    gContext[@"mantle_server_broadcast"] = ^(JSValue *call) {
        NSDictionary *callDict = [call toObject];
        mantle_server_broadcast(gServer, callDict);
    };

    // mantle_server_foreach_client
    gContext[@"mantle_server_foreach_client"] = ^(JSValue *callback) {
        mantle_server_foreach_client(gServer, ^(mantle_client_info_t *client) {
            if (callback && ![callback isUndefined]) {
                [callback callWithArguments:@[
                    @(client->pid),
                    [NSString stringWithUTF8String:client->process_name]
                ]];
            }
        });
    };

    // Load stdlib
    if (gStdlibPath) {
        NSString *stdlibScript = [NSString stringWithContentsOfFile:gStdlibPath encoding:NSUTF8StringEncoding error:NULL];
        if (stdlibScript) {
            [gContext evaluateScript:stdlibScript];
        }
    }

    // Load config
    if (gConfigPath) {
        NSString *configScript = [NSString stringWithContentsOfFile:gConfigPath encoding:NSUTF8StringEncoding error:NULL];
        if (configScript) {
            printf("[Reload] Loading: %s\n", gConfigPath.UTF8String);
            [gContext evaluateScript:configScript];
        } else {
            fprintf(stderr, "[Reload] Failed to read: %s\n", gConfigPath.UTF8String);
        }
    }
}

static int gWatchedFd = -1;

static void setupFileWatcher(void);  // Forward declaration

static void startFileWatcher(void) {
    if (!gConfigPath) return;

    // Watch the file itself, not the directory
    gWatchedFd = open(gConfigPath.UTF8String, O_EVTONLY);
    if (gWatchedFd < 0) {
        fprintf(stderr, "Failed to open file for watching: %s\n", gConfigPath.UTF8String);
        return;
    }

    gFileWatcher = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, gWatchedFd,
        DISPATCH_VNODE_WRITE | DISPATCH_VNODE_EXTEND | DISPATCH_VNODE_ATTRIB | DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME,
        dispatch_get_main_queue());

    if (!gFileWatcher) {
        close(gWatchedFd);
        gWatchedFd = -1;
        fprintf(stderr, "Failed to create file watcher\n");
        return;
    }

    // Debounce reload
    __block dispatch_source_t debounceTimer = NULL;

    dispatch_source_set_event_handler(gFileWatcher, ^{
        unsigned long flags = dispatch_source_get_data(gFileWatcher);

        // If file was deleted or renamed, we need to re-establish the watch
        if (flags & (DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME)) {
            // Cancel existing debounce timer
            if (debounceTimer) {
                dispatch_source_cancel(debounceTimer);
                debounceTimer = NULL;
            }

            // Wait a bit for the file to be recreated (editors often delete+create)
            debounceTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
            dispatch_source_set_timer(debounceTimer, dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), DISPATCH_TIME_FOREVER, 0);
            dispatch_source_set_event_handler(debounceTimer, ^{
                printf("\n[Hot Reload] Config file changed, reloading...\n");

                // Cancel old watcher
                if (gFileWatcher) {
                    dispatch_source_cancel(gFileWatcher);
                    gFileWatcher = NULL;
                }
                if (gWatchedFd >= 0) {
                    close(gWatchedFd);
                    gWatchedFd = -1;
                }

                // Reload and re-establish watch
                setupJavaScriptContext();
                startFileWatcher();

                dispatch_source_cancel(debounceTimer);
                debounceTimer = NULL;
            });
            dispatch_resume(debounceTimer);
            return;
        }

        // Cancel existing debounce timer
        if (debounceTimer) {
            dispatch_source_cancel(debounceTimer);
            debounceTimer = NULL;
        }

        // Debounce: wait 100ms before reloading
        debounceTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(debounceTimer, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), DISPATCH_TIME_FOREVER, 0);
        dispatch_source_set_event_handler(debounceTimer, ^{
            printf("\n[Hot Reload] Config changed, reloading...\n");
            setupJavaScriptContext();
            dispatch_source_cancel(debounceTimer);
            debounceTimer = NULL;
        });
        dispatch_resume(debounceTimer);
    });

    dispatch_source_set_cancel_handler(gFileWatcher, ^{
        if (gWatchedFd >= 0) {
            close(gWatchedFd);
            gWatchedFd = -1;
        }
    });

    dispatch_resume(gFileWatcher);
    printf("Watching for changes: %s\n", gConfigPath.UTF8String);
}

static JSValue *foundationToJS(id obj, JSContext *context) {
    if (!obj || [obj isKindOfClass:[NSNull class]]) {
        return [JSValue valueWithNullInContext:context];
    }

    if ([obj isKindOfClass:[NSString class]]) {
        return [JSValue valueWithObject:obj inContext:context];
    }

    if ([obj isKindOfClass:[NSNumber class]]) {
        // Check if it's a boolean
        if (strcmp([obj objCType], @encode(BOOL)) == 0 ||
            strcmp([obj objCType], @encode(char)) == 0) {
            return [JSValue valueWithBool:[obj boolValue] inContext:context];
        }
        return [JSValue valueWithDouble:[obj doubleValue] inContext:context];
    }

    if ([obj isKindOfClass:[NSArray class]]) {
        JSValue *jsArray = [JSValue valueWithNewArrayInContext:context];
        NSArray *array = (NSArray *)obj;
        for (NSUInteger i = 0; i < array.count; i++) {
            jsArray[i] = foundationToJS(array[i], context);
        }
        return jsArray;
    }

    if ([obj isKindOfClass:[NSDictionary class]]) {
        JSValue *jsObject = [JSValue valueWithNewObjectInContext:context];
        NSDictionary *dict = (NSDictionary *)obj;
        for (NSString *key in dict) {
            jsObject[key] = foundationToJS(dict[key], context);
        }
        return jsObject;
    }

    // For other objects, convert to string representation
    return [JSValue valueWithObject:[obj description] inContext:context];
}

const char * MANTLE_SERVICE_NAME = "com.corebedtime.mantle.connect";

const char* SessionGetEnvironment(const char *name);
int64_t SessionSetEnvironment(const char *name, const char *value);



pid_t ProcOf(const char *name) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t sz = 0; sysctl(mib, 4, NULL, &sz, NULL, 0);
    struct kinfo_proc *kp = malloc(sz);
    sysctl(mib, 4, kp, &sz, NULL, 0);

    for (size_t i = 0; i < sz / sizeof(*kp); i++)
        if (!strcmp(kp[i].kp_proc.p_comm, name))
            return kp[i].kp_proc.p_pid;

    return 0;
}

pid_t SpawnHelper(const char *path, char *const argv[], int as_root) {
    pid_t pid = fork();
    if (pid == -1) {
        perror("fork failed");
        return -1;
    }

    if (pid == 0) {
        if (!as_root) {
            uid_t consoleUID;
            gid_t consoleGID;
            CFStringRef cfUser = SCDynamicStoreCopyConsoleUser(NULL, &consoleUID, &consoleGID);

            if (cfUser != NULL) {
                if (setgid(consoleGID) != 0 || setuid(consoleUID) != 0) {
                    perror("Failed to drop privileges");
                    exit(1);
                }
                CFRelease(cfUser);
            }
        }

        execv(path, argv);
        perror("execv failed");
        exit(1);
    }

    return pid;
}

void KickstartUserspace(void) {
    const char *procs[] = { "Finder",
                            //"Dock",
                            NULL };
    for (int i = 0; procs[i]; i++) {
        pid_t pid = ProcOf(procs[i]);
        if (pid > 0) {
            printf("Killing %s (pid %d)\n", procs[i], pid);
            kill(pid, SIGTERM);
        }
    }
}

static int RunAsConsoleUser(uid_t uid, gid_t gid, int (*action)(void *), void *ctx) {
    pid_t pid = fork();

    if (pid == -1) {
        perror("fork failed");
        return 1;
    }

    if (pid == 0) {
        // Child Process

        // Note: Original code had a sleep here. Keeping it, though explicit synchronization
        // is usually preferred over sleeps to avoid race conditions.
        usleep(USEC_PER_SEC / 8);

        if (setgid(gid) != 0 || setuid(uid) != 0) {
            perror("Failed to drop privileges");
            _exit(1);
        }

        int result = action(ctx);
        _exit(result);
    } else {
        // Parent Process
        int status;
        if (waitpid(pid, &status, 0) == -1) {
            perror("waitpid failed");
            return 1;
        }

        if (WIFEXITED(status)) {
            int exit_code = WEXITSTATUS(status);
            if (exit_code != 0) {
                fprintf(stderr, "Child process failed with exit code %d\n", exit_code);
                return 1;
            }
            return 0;
        }

        if (WIFSIGNALED(status)) {
            fprintf(stderr, "Child process killed by signal %d\n", WTERMSIG(status));
            return 1;
        }
    }
    return 1;
}

// Context struct for setting environment variables
typedef struct {
    const char *key;
    const char *value;
} EnvVarContext;

// Callback function to set environment variable
static int SetEnvAction(void *context) {
    EnvVarContext *ctx = (EnvVarContext *)context;
    // Check if it already exists if necessary, or just overwrite
    if (SessionSetEnvironment(ctx->key, ctx->value) != 0) {
        return 1;
    }
    printf("Set environment: %s\n", ctx->key);
    return 0;
}

// Callback function for DYLD injection
static int SetupDyldAction(void *context) {
    (void)context; // Unused
    if (SessionGetEnvironment("DYLD_INSERT_LIBRARIES") == NULL) {
        printf("Setting DYLD_INSERT_LIBRARIES...\n");
        if (SessionSetEnvironment("DYLD_INSERT_LIBRARIES", "/opt/mantle/libcore.dylib") != 0) {
            return 1;
        }
    } else {
        printf("DYLD_INSERT_LIBRARIES already set.\n");
    }
    return 0;
}

// --- Core Logic ---

static int IssueSandboxExtension(void) {
    char *token = sandbox_extension_issue_mach(APP_SANDBOX_MACH, MANTLE_SERVICE_NAME, 0);

    if (!token) {
        fprintf(stderr, "Failed to issue sandbox extension for %s\n", MANTLE_SERVICE_NAME);
        return -1;
    }

    if (gSandboxToken) free(gSandboxToken); // Safety check if called multiple times
    gSandboxToken = token;

    printf("Issued sandbox extension: %s\n", token);
    return 0;
}

static int GetConsoleUser(uid_t *uid, gid_t *gid) {
    CFStringRef cfUser = SCDynamicStoreCopyConsoleUser(NULL, uid, gid);
    if (!cfUser) {
        return 0; // No user
    }

    // Convert to C-string just for logging
    char username[256] = {0};
    if (CFStringGetCString(cfUser, username, sizeof(username), kCFStringEncodingUTF8)) {
        printf("Detected console user: %s (UID: %d)\n", username, *uid);
    }

    CFRelease(cfUser);
    return 1; // Success
}

int main(int argc, char **argv) {
    uid_t consoleUID;
    gid_t consoleGID;

    // Identify the user immediately
    if (!GetConsoleUser(&consoleUID, &consoleGID)) {
        fprintf(stderr, "No console user detected. Exiting.\n");
        return 1;
    }

    RunAsConsoleUser(consoleUID, consoleGID, SetupDyldAction, NULL);

    // Issue Extension and update environment
    if (IssueSandboxExtension() == 0) {
        // Re-run the environment setter to push the new token
        // We reuse the logic inside SetupEnvironmentForUser to push the token
        EnvVarContext var;

        var = (EnvVarContext){ "MANTLE_SANDBOX_TOKEN", gSandboxToken };
        RunAsConsoleUser(consoleUID, consoleGID, SetEnvAction, &var);

        var = (EnvVarContext){ "MANTLE_SERVICE_NAME", MANTLE_SERVICE_NAME };
        RunAsConsoleUser(consoleUID, consoleGID, SetEnvAction, &var);
    }

    printf("Loaded up! Kickstarting userspace...\n");
    KickstartUserspace();
    printf("Kickstarted userspace, starting services!\n");

    // Create and start the Mach service
    gServer = mantle_server_create(MANTLE_SERVICE_NAME);
    if (!gServer) {
        fprintf(stderr, "Failed to create Mach service '%s'\n", MANTLE_SERVICE_NAME);
        fprintf(stderr, "This may be due to the service already being registered.\n");
        fprintf(stderr, "Try unloading the launch agent and restarting.\n");
        return 1;
    }

    // // Set up client connection handler
    // mantle_server_set_client_handler(gServer, ^(mantle_client_info_t *client, bool connected) {
    //     // Copy client info for use in nested blocks
    //     NSString *processName = [NSString stringWithUTF8String:client->process_name];
    //     pid_t clientPid = client->pid;

    //     if (connected) {
    //         printf("Client connected: %s (pid %d, port %d)\n",
    //                client->process_name, client->pid, client->send_port);

    //         // Test 1: Objective-C method call
    //         NSDictionary *objcCall = @{
    //             @"method": @"processInfo",
    //             @"target": @"NSProcessInfo",
    //             @"args": @[]
    //         };
    //         mantle_server_call(gServer, clientPid, objcCall, ^(NSDictionary *response, NSError *error) {
    //             if (error) {
    //                 NSLog(@"[ObjC] FFI call to %@ failed: %@", processName, error.localizedDescription);
    //             } else {
    //                 NSLog(@"[ObjC] Response from %@: %@", processName, response);
    //             }
    //         });

    //         // Test 2: C function call - getpid()
    //         NSDictionary *cCall = @{
    //             @"method": @"getpid",
    //             @"target": [NSNull null],
    //             @"args": @[],
    //             @"returns": @"int"
    //         };
    //         mantle_server_call(gServer, clientPid, cCall, ^(NSDictionary *response, NSError *error) {
    //             if (error) {
    //                 NSLog(@"[C] getpid call to %@ failed: %@", processName, error.localizedDescription);
    //             } else {
    //                 NSLog(@"[C] getpid from %@: %@", processName, response[@"result"]);
    //             }
    //         });

    //         // Test 3: C function call with args - strcmp
    //         NSDictionary *strcmpCall = @{
    //             @"method": @"strcmp",
    //             @"target": [NSNull null],
    //             @"args": @[
    //                 @{@"type": @"string", @"value": @"hello"},
    //                 @{@"type": @"string", @"value": @"hello"}
    //             ],
    //             @"returns": @"int"
    //         };
    //         mantle_server_call(gServer, clientPid, strcmpCall, ^(NSDictionary *response, NSError *error) {
    //             if (error) {
    //                 NSLog(@"[C] strcmp call to %@ failed: %@", processName, error.localizedDescription);
    //             } else {
    //                 NSLog(@"[C] strcmp(\"hello\", \"hello\") from %@: %@", processName, response[@"result"]);
    //             }
    //         });
    //     } else {
    //         printf("Client disconnected: %s (pid %d)\n", client->process_name, client->pid);
    //     }
    // });

    // Start server on a dedicated queue
    dispatch_queue_t server_queue = dispatch_queue_create("com.mantle.server", DISPATCH_QUEUE_SERIAL);
    kern_return_t kr = mantle_server_start(gServer, server_queue);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "Failed to start Mach server: %d\n", kr);
        return 1;
    }

    printf("Mach service '%s' started successfully\n", MANTLE_SERVICE_NAME);

    gStdlibPath = [@"/opt/mantle/" stringByAppendingPathComponent:@"wm_std_lib/windowmanager.js"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:gStdlibPath]) {
        printf("Found stdlib: %s\n", gStdlibPath.UTF8String);
    } else {
        printf("Note: windowmanager.js not found, skipping stdlib\n");
        gStdlibPath = nil;
    }

    // Set config path if provided
    NSString *fallbackPath = @"/opt/mantle/fallback.js";
    
    if (argc > 1) {
        gConfigPath = [NSString stringWithUTF8String:argv[1]];

        // Convert to absolute path if relative
        if (![gConfigPath isAbsolutePath]) {
            gConfigPath = [[[NSFileManager defaultManager] currentDirectoryPath]
                           stringByAppendingPathComponent:gConfigPath];
        }

        // Check if the specified config file exists
        if (![[NSFileManager defaultManager] fileExistsAtPath:gConfigPath]) {
            printf("Config file not found: %s\n", gConfigPath.UTF8String);
            // Fall back to fallback.js if it exists
            if ([[NSFileManager defaultManager] fileExistsAtPath:fallbackPath]) {
                gConfigPath = fallbackPath;
                printf("Using fallback: %s\n", gConfigPath.UTF8String);
            } else {
                gConfigPath = nil;
                printf("Warning: fallback.js also not found\n");
            }
        } else {
            printf("Config file: %s\n", gConfigPath.UTF8String);
        }
    } else {
        // Use fallback.js if no config specified
        if ([[NSFileManager defaultManager] fileExistsAtPath:fallbackPath]) {
            gConfigPath = fallbackPath;
            printf("No config specified, using fallback: %s\n", gConfigPath.UTF8String);
        }
    }

    // Setup JavaScript context and load scripts
    setupJavaScriptContext();

    // Start watching config file for changes
    if (gConfigPath) {
        startFileWatcher();
    }

    CFRunLoopRun();

    // Cleanup
    mantle_server_destroy(gServer);
    return 0;
}
