#import <Foundation/Foundation.h>
#include <_stdlib.h>
#include <MacTypes.h>
#include <stdio.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#include <dispatch/dispatch.h>
#include <mach-o/dyld.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <libproc.h>
#include <unistd.h>
#include <ffi/ffi.h>

#import "pac.h"
#import "dobby.h"
#import "mantle_mach.h"

// Processes to skip connecting from (to avoid issues with system processes)
static const char *skip_processes[] = {
    "wm_init",
    "mantle",
    NULL
};

bool ShouldSkipProcess(void) {
    char process_name[256] = {0};
    proc_name(getpid(), process_name, sizeof(process_name));

    for (int i = 0; skip_processes[i] != NULL; i++) {
        if (strcmp(process_name, skip_processes[i]) == 0) {
            return true;
        }
    }
    return false;
}

// Global client connection
static mantle_client_t *gClient = NULL;

#pragma mark - FFI Type Helpers

// Get ffi_type from type string
// Supported types: "void", "int", "uint", "long", "ulong", "longlong", "ulonglong",
//                  "float", "double", "bool", "char", "uchar", "short", "ushort",
//                  "pointer", "string", "size_t", "int8", "int16", "int32", "int64",
//                  "uint8", "uint16", "uint32", "uint64"
static ffi_type *ffi_type_from_string(NSString *typeStr) {
    if (!typeStr || [typeStr isEqualToString:@"void"]) return &ffi_type_void;
    if ([typeStr isEqualToString:@"int"]) return &ffi_type_sint;
    if ([typeStr isEqualToString:@"uint"]) return &ffi_type_uint;
    if ([typeStr isEqualToString:@"long"]) return &ffi_type_slong;
    if ([typeStr isEqualToString:@"ulong"]) return &ffi_type_ulong;
    if ([typeStr isEqualToString:@"longlong"]) return &ffi_type_sint64;
    if ([typeStr isEqualToString:@"ulonglong"]) return &ffi_type_uint64;
    if ([typeStr isEqualToString:@"float"]) return &ffi_type_float;
    if ([typeStr isEqualToString:@"double"]) return &ffi_type_double;
    if ([typeStr isEqualToString:@"bool"]) return &ffi_type_uint8;
    if ([typeStr isEqualToString:@"char"]) return &ffi_type_schar;
    if ([typeStr isEqualToString:@"uchar"]) return &ffi_type_uchar;
    if ([typeStr isEqualToString:@"short"]) return &ffi_type_sshort;
    if ([typeStr isEqualToString:@"ushort"]) return &ffi_type_ushort;
    if ([typeStr isEqualToString:@"pointer"]) return &ffi_type_pointer;
    if ([typeStr isEqualToString:@"string"]) return &ffi_type_pointer;
    if ([typeStr isEqualToString:@"size_t"]) return &ffi_type_ulong;
    if ([typeStr isEqualToString:@"int8"]) return &ffi_type_sint8;
    if ([typeStr isEqualToString:@"int16"]) return &ffi_type_sint16;
    if ([typeStr isEqualToString:@"int32"]) return &ffi_type_sint32;
    if ([typeStr isEqualToString:@"int64"]) return &ffi_type_sint64;
    if ([typeStr isEqualToString:@"uint8"]) return &ffi_type_uint8;
    if ([typeStr isEqualToString:@"uint16"]) return &ffi_type_uint16;
    if ([typeStr isEqualToString:@"uint32"]) return &ffi_type_uint32;
    if ([typeStr isEqualToString:@"uint64"]) return &ffi_type_uint64;
    if ([typeStr isEqualToString:@"id"]) return &ffi_type_pointer;
    if ([typeStr isEqualToString:@"object"]) return &ffi_type_pointer;
    if ([typeStr isEqualToString:@"class"]) return &ffi_type_pointer;
    if ([typeStr isEqualToString:@"sel"]) return &ffi_type_pointer;
    return &ffi_type_pointer; // Default to pointer for unknown types
}

// Convert JSON value to C value based on type
static void *alloc_and_set_arg(id jsonValue, NSString *typeStr, NSMutableArray *allocations) {
    void *storage = NULL;

    if ([typeStr isEqualToString:@"string"]) {
        // String: allocate and copy
        const char *str = "";
        if ([jsonValue isKindOfClass:[NSString class]]) {
            str = [jsonValue UTF8String];
        }
        char **strPtr = malloc(sizeof(char *));
        *strPtr = (char *)str;  // Points to autoreleased NSString's buffer
        storage = strPtr;
        [allocations addObject:[NSValue valueWithPointer:strPtr]];
    } else if ([typeStr isEqualToString:@"pointer"]) {
        void **ptr = malloc(sizeof(void *));
        if ([jsonValue isKindOfClass:[NSString class]] && [jsonValue hasPrefix:@"0x"]) {
            unsigned long long ptrVal = 0;
            [[NSScanner scannerWithString:jsonValue] scanHexLongLong:&ptrVal];
            *ptr = (void *)ptrVal;
        } else if ([jsonValue isKindOfClass:[NSNumber class]]) {
            *ptr = (void *)[jsonValue unsignedLongLongValue];
        } else {
            *ptr = NULL;
        }
        storage = ptr;
        [allocations addObject:[NSValue valueWithPointer:ptr]];
    } else if ([typeStr isEqualToString:@"int"] || [typeStr isEqualToString:@"int32"]) {
        int *val = malloc(sizeof(int));
        *val = [jsonValue intValue];
        storage = val;
        [allocations addObject:[NSValue valueWithPointer:val]];
    } else if ([typeStr isEqualToString:@"uint"] || [typeStr isEqualToString:@"uint32"]) {
        unsigned int *val = malloc(sizeof(unsigned int));
        *val = [jsonValue unsignedIntValue];
        storage = val;
        [allocations addObject:[NSValue valueWithPointer:val]];
    } else if ([typeStr isEqualToString:@"long"]) {
        long *val = malloc(sizeof(long));
        *val = [jsonValue longValue];
        storage = val;
        [allocations addObject:[NSValue valueWithPointer:val]];
    } else if ([typeStr isEqualToString:@"ulong"] || [typeStr isEqualToString:@"size_t"]) {
        unsigned long *val = malloc(sizeof(unsigned long));
        *val = [jsonValue unsignedLongValue];
        storage = val;
        [allocations addObject:[NSValue valueWithPointer:val]];
    } else if ([typeStr isEqualToString:@"longlong"] || [typeStr isEqualToString:@"int64"]) {
        long long *val = malloc(sizeof(long long));
        *val = [jsonValue longLongValue];
        storage = val;
        [allocations addObject:[NSValue valueWithPointer:val]];
    } else if ([typeStr isEqualToString:@"ulonglong"] || [typeStr isEqualToString:@"uint64"]) {
        unsigned long long *val = malloc(sizeof(unsigned long long));
        *val = [jsonValue unsignedLongLongValue];
        storage = val;
        [allocations addObject:[NSValue valueWithPointer:val]];
    } else if ([typeStr isEqualToString:@"float"]) {
        float *val = malloc(sizeof(float));
        *val = [jsonValue floatValue];
        storage = val;
        [allocations addObject:[NSValue valueWithPointer:val]];
    } else if ([typeStr isEqualToString:@"double"]) {
        double *val = malloc(sizeof(double));
        *val = [jsonValue doubleValue];
        storage = val;
        [allocations addObject:[NSValue valueWithPointer:val]];
    } else if ([typeStr isEqualToString:@"bool"] || [typeStr isEqualToString:@"uint8"]) {
        uint8_t *val = malloc(sizeof(uint8_t));
        *val = [jsonValue boolValue] ? 1 : 0;
        storage = val;
        [allocations addObject:[NSValue valueWithPointer:val]];
    } else if ([typeStr isEqualToString:@"int8"] || [typeStr isEqualToString:@"char"]) {
        int8_t *val = malloc(sizeof(int8_t));
        *val = (int8_t)[jsonValue intValue];
        storage = val;
        [allocations addObject:[NSValue valueWithPointer:val]];
    } else if ([typeStr isEqualToString:@"uchar"]) {
        uint8_t *val = malloc(sizeof(uint8_t));
        *val = (uint8_t)[jsonValue unsignedIntValue];
        storage = val;
        [allocations addObject:[NSValue valueWithPointer:val]];
    } else if ([typeStr isEqualToString:@"short"] || [typeStr isEqualToString:@"int16"]) {
        int16_t *val = malloc(sizeof(int16_t));
        *val = (int16_t)[jsonValue intValue];
        storage = val;
        [allocations addObject:[NSValue valueWithPointer:val]];
    } else if ([typeStr isEqualToString:@"ushort"] || [typeStr isEqualToString:@"uint16"]) {
        uint16_t *val = malloc(sizeof(uint16_t));
        *val = (uint16_t)[jsonValue unsignedIntValue];
        storage = val;
        [allocations addObject:[NSValue valueWithPointer:val]];
    } else if ([typeStr isEqualToString:@"id"] || [typeStr isEqualToString:@"object"]) {
        // Object pointer from hex string
        void **ptr = malloc(sizeof(void *));
        if ([jsonValue isKindOfClass:[NSString class]] && [jsonValue hasPrefix:@"0x"]) {
            unsigned long long ptrVal = 0;
            [[NSScanner scannerWithString:jsonValue] scanHexLongLong:&ptrVal];
            *ptr = (void *)ptrVal;
        } else {
            *ptr = (__bridge void *)jsonValue;
        }
        storage = ptr;
        [allocations addObject:[NSValue valueWithPointer:ptr]];
    } else if ([typeStr isEqualToString:@"class"]) {
        void **ptr = malloc(sizeof(void *));
        if ([jsonValue isKindOfClass:[NSString class]]) {
            *ptr = (__bridge void *)NSClassFromString(jsonValue);
        } else {
            *ptr = NULL;
        }
        storage = ptr;
        [allocations addObject:[NSValue valueWithPointer:ptr]];
    } else if ([typeStr isEqualToString:@"sel"]) {
        void **ptr = malloc(sizeof(void *));
        if ([jsonValue isKindOfClass:[NSString class]]) {
            *ptr = NSSelectorFromString(jsonValue);
        } else {
            *ptr = NULL;
        }
        storage = ptr;
        [allocations addObject:[NSValue valueWithPointer:ptr]];
    } else {
        // Default: treat as pointer
        void **ptr = malloc(sizeof(void *));
        *ptr = NULL;
        storage = ptr;
        [allocations addObject:[NSValue valueWithPointer:ptr]];
    }

    return storage;
}

// Convert C return value to JSON
static id result_to_json(void *result, NSString *returnType) {
    if (!returnType || [returnType isEqualToString:@"void"]) {
        return [NSNull null];
    }

    if ([returnType isEqualToString:@"string"]) {
        char *str = *(char **)result;
        return str ? [NSString stringWithUTF8String:str] : [NSNull null];
    } else if ([returnType isEqualToString:@"pointer"]) {
        void *ptr = *(void **)result;
        return [NSString stringWithFormat:@"0x%llx", (unsigned long long)ptr];
    } else if ([returnType isEqualToString:@"int"] || [returnType isEqualToString:@"int32"]) {
        return @(*(int *)result);
    } else if ([returnType isEqualToString:@"uint"] || [returnType isEqualToString:@"uint32"]) {
        return @(*(unsigned int *)result);
    } else if ([returnType isEqualToString:@"long"]) {
        return @(*(long *)result);
    } else if ([returnType isEqualToString:@"ulong"] || [returnType isEqualToString:@"size_t"]) {
        return @(*(unsigned long *)result);
    } else if ([returnType isEqualToString:@"longlong"] || [returnType isEqualToString:@"int64"]) {
        return @(*(long long *)result);
    } else if ([returnType isEqualToString:@"ulonglong"] || [returnType isEqualToString:@"uint64"]) {
        return @(*(unsigned long long *)result);
    } else if ([returnType isEqualToString:@"float"]) {
        return @(*(float *)result);
    } else if ([returnType isEqualToString:@"double"]) {
        return @(*(double *)result);
    } else if ([returnType isEqualToString:@"bool"]) {
        return @(*(uint8_t *)result ? YES : NO);
    } else if ([returnType isEqualToString:@"char"] || [returnType isEqualToString:@"int8"]) {
        return @(*(int8_t *)result);
    } else if ([returnType isEqualToString:@"uchar"] || [returnType isEqualToString:@"uint8"]) {
        return @(*(uint8_t *)result);
    } else if ([returnType isEqualToString:@"short"] || [returnType isEqualToString:@"int16"]) {
        return @(*(int16_t *)result);
    } else if ([returnType isEqualToString:@"ushort"] || [returnType isEqualToString:@"uint16"]) {
        return @(*(uint16_t *)result);
    } else if ([returnType isEqualToString:@"id"] || [returnType isEqualToString:@"object"]) {
        id obj = (__bridge id)(*(void **)result);
        if (!obj) return [NSNull null];
        // Return JSON-compatible or object reference
        if ([obj isKindOfClass:[NSString class]] ||
            [obj isKindOfClass:[NSNumber class]] ||
            [obj isKindOfClass:[NSArray class]] ||
            [obj isKindOfClass:[NSDictionary class]]) {
            return obj;
        }
        return @{
            @"_type": NSStringFromClass([obj class]),
            @"_ptr": [NSString stringWithFormat:@"%p", obj],
            @"_description": [obj description] ?: @""
        };
    } else if ([returnType isEqualToString:@"class"]) {
        Class cls = (__bridge Class)(*(void **)result);
        return cls ? NSStringFromClass(cls) : [NSNull null];
    } else if ([returnType isEqualToString:@"sel"]) {
        SEL sel = *(SEL *)result;
        return sel ? NSStringFromSelector(sel) : [NSNull null];
    }

    // Default: return as pointer
    void *ptr = *(void **)result;
    return [NSString stringWithFormat:@"0x%llx", (unsigned long long)ptr];
}

// Free allocations
static void free_allocations(NSMutableArray *allocations) {
    for (NSValue *val in allocations) {
        free([val pointerValue]);
    }
}

#pragma mark - C Function FFI Call

// Execute C function via libffi
// Call format:
// {
//   "method": "function_name",
//   "target": null,
//   "args": [{"type": "int", "value": 42}, {"type": "string", "value": "hello"}],
//   "returns": "int"
// }
static NSDictionary *execute_c_function(NSString *funcName, NSArray *args, NSString *returnType) {
    void *funcPtr = dlsym(RTLD_DEFAULT, funcName.UTF8String);
    if (!funcPtr) {
        // failed to find with dlsym, maybe dobby can help
        void *funcPtrPac = DobbySymbolResolver(NULL, [@"_" stringByAppendingString:funcName].UTF8String);
        if (!funcPtrPac) {
            return @{@"error": [NSString stringWithFormat:@"Symbol not found: %@", funcName]};
        }
        funcPtr = make_sym_callable(funcPtrPac);
    }

    NSUInteger argCount = args.count;

    // Prepare FFI types
    ffi_type *retType = ffi_type_from_string(returnType);
    ffi_type **argTypes = NULL;
    void **argValues = NULL;
    NSMutableArray *allocations = [NSMutableArray new];

    if (argCount > 0) {
        argTypes = calloc(argCount, sizeof(ffi_type *));
        argValues = calloc(argCount, sizeof(void *));

        for (NSUInteger i = 0; i < argCount; i++) {
            id argSpec = args[i];
            NSString *type = @"int";  // default
            id value = argSpec;

            if ([argSpec isKindOfClass:[NSDictionary class]]) {
                type = argSpec[@"type"] ?: @"int";
                value = argSpec[@"value"];
            }

            argTypes[i] = ffi_type_from_string(type);
            argValues[i] = alloc_and_set_arg(value, type, allocations);
        }
    }

    // Prepare CIF
    ffi_cif cif;
    ffi_status status = ffi_prep_cif(&cif, FFI_DEFAULT_ABI, (unsigned int)argCount, retType, argTypes);

    if (status != FFI_OK) {
        free_allocations(allocations);
        if (argTypes) free(argTypes);
        if (argValues) free(argValues);
        return @{@"error": [NSString stringWithFormat:@"ffi_prep_cif failed: %d", status]};
    }

    // Allocate return value storage
    void *retValue = malloc(retType->size > sizeof(ffi_arg) ? retType->size : sizeof(ffi_arg));
    memset(retValue, 0, retType->size > sizeof(ffi_arg) ? retType->size : sizeof(ffi_arg));

    // Call the function
    ffi_call(&cif, funcPtr, retValue, argValues);

    // Convert result
    id result = result_to_json(retValue, returnType);

    // Cleanup
    free(retValue);
    free_allocations(allocations);
    if (argTypes) free(argTypes);
    if (argValues) free(argValues);

    return @{@"result": result};
}

#pragma mark - Objective-C FFI Helpers

static id json_to_objc(id value) {
    if (!value || [value isKindOfClass:[NSNull class]]) {
        return nil;
    }
    return value;
}

static id objc_to_json(id value) {
    if (!value) {
        return [NSNull null];
    }

    @try {
        if ([value isKindOfClass:[NSNull class]]) {
            return value;
        }

        if ([value isKindOfClass:[NSString class]] ||
            [value isKindOfClass:[NSNumber class]]) {
            return value;
        }

        // Recursively convert array elements
        if ([value isKindOfClass:[NSArray class]]) {
            NSArray *array = (NSArray *)value;
            NSMutableArray *result = [NSMutableArray arrayWithCapacity:array.count];
            for (NSUInteger i = 0; i < array.count; i++) {
                id element = array[i];
                id converted = objc_to_json(element);
                [result addObject:converted ?: [NSNull null]];
            }
            return result;
        }

        // Recursively convert dictionary values
        if ([value isKindOfClass:[NSDictionary class]]) {
            NSDictionary *dict = (NSDictionary *)value;
            NSMutableDictionary *result = [NSMutableDictionary dictionaryWithCapacity:dict.count];
            for (id key in dict) {
                id converted = objc_to_json(dict[key]);
                result[key] = converted ?: [NSNull null];
            }
            return result;
        }

        // Convert other NSObjects to pointer representation
        // Only access description, which could trigger lazy loading - use ptr as primary identifier
        Class cls = object_getClass(value);
        NSString *className = cls ? NSStringFromClass(cls) : @"Unknown";
        NSString *ptrString = [NSString stringWithFormat:@"%p", value];

        // Try to get description safely
        NSString *desc = @"";
        @try {
            desc = [value description] ?: @"";
        } @catch (NSException *e) {
            desc = @"<description unavailable>";
        }

        return @{
            @"_type": className,
            @"_ptr": ptrString,
            @"_description": desc
        };
    } @catch (NSException *exception) {
        NSLog(@"[Mantle] objc_to_json exception: %@", exception);
        return [NSNull null];
    }
}

#pragma mark - Main FFI Executor

// Execute an FFI call and return the result
// Supported call formats:
//
// Objective-C method:
// { "method": "selectorName:", "target": "0x12345678" or "ClassName", "args": [...] }
//
// C function:
// { "method": "function_name", "target": null, "args": [{"type": "int", "value": 42}], "returns": "int" }

@implementation NSInvocation (MainThread)
- (void)invokeOnMainThread {
    [self performSelectorOnMainThread:@selector(invoke) withObject:NULL waitUntilDone:YES];
}

@end
static NSDictionary *execute_ffi_call(NSDictionary *call) {
    NSString *method = call[@"method"];
    id target_spec = call[@"target"];
    NSArray *args = call[@"args"] ?: @[];
    NSString *returnType = call[@"returns"];

    if (!method) {
        return @{@"error": @"Missing 'method' field"};
    }

    @try {
        // Determine target
        id target = nil;

        if (target_spec && ![target_spec isKindOfClass:[NSNull class]]) {
            NSString *target_str = target_spec;

            if ([target_str hasPrefix:@"0x"]) {
                unsigned long long ptr = 0;
                [[NSScanner scannerWithString:target_str] scanHexLongLong:&ptr];
                target = (__bridge id)(void *)ptr;
            } else {
                target = NSClassFromString(target_str);
                if (!target) {
                    return @{@"error": [NSString stringWithFormat:@"Class not found: %@", target_str]};
                }
            }
        }

        if (!target) {
            // C function call via libffi
            return execute_c_function(method, args, returnType ?: @"void");
        }

        // Objective-C method call
        SEL selector = NSSelectorFromString(method);
        if (![target respondsToSelector:selector]) {
            return @{@"error": [NSString stringWithFormat:@"Target does not respond to selector: %@", method]};
        }

        NSMethodSignature *sig = [target methodSignatureForSelector:selector];
        if (!sig) {
            return @{@"error": @"Could not get method signature"};
        }

        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:sig];
        [invocation setTarget:target];
        [invocation setSelector:selector];

        // Set arguments (indices 0 and 1 are self and _cmd)
        for (NSUInteger i = 0; i < args.count && i + 2 < sig.numberOfArguments; i++) {
            id arg = json_to_objc(args[i]);
            const char *argType = [sig getArgumentTypeAtIndex:i + 2];

            switch (argType[0]) {
                case '@': case '#':
                    [invocation setArgument:&arg atIndex:i + 2];
                    break;
                case 'i': { int val = [arg intValue]; [invocation setArgument:&val atIndex:i + 2]; break; }
                case 'I': { unsigned int val = [arg unsignedIntValue]; [invocation setArgument:&val atIndex:i + 2]; break; }
                case 'l': { long val = [arg longValue]; [invocation setArgument:&val atIndex:i + 2]; break; }
                case 'L': { unsigned long val = [arg unsignedLongValue]; [invocation setArgument:&val atIndex:i + 2]; break; }
                case 'q': { long long val = [arg longLongValue]; [invocation setArgument:&val atIndex:i + 2]; break; }
                case 'Q': { unsigned long long val = [arg unsignedLongLongValue]; [invocation setArgument:&val atIndex:i + 2]; break; }
                case 'f': { float val = [arg floatValue]; [invocation setArgument:&val atIndex:i + 2]; break; }
                case 'd': { double val = [arg doubleValue]; [invocation setArgument:&val atIndex:i + 2]; break; }
                case 'B': { BOOL val = [arg boolValue]; [invocation setArgument:&val atIndex:i + 2]; break; }
                case '*': { const char *val = [arg UTF8String]; [invocation setArgument:&val atIndex:i + 2]; break; }
                case '{': {
                    // Struct type - check for common types
                    NSString *typeStr = [NSString stringWithUTF8String:argType];
                    if ([typeStr hasPrefix:@"{CGPoint="] || [typeStr hasPrefix:@"{NSPoint="]) {
                        // NSPoint/CGPoint: {"x": 100, "y": 200}
                        CGPoint pt = CGPointMake([arg[@"x"] doubleValue], [arg[@"y"] doubleValue]);
                        [invocation setArgument:&pt atIndex:i + 2];
                    } else if ([typeStr hasPrefix:@"{CGSize="] || [typeStr hasPrefix:@"{NSSize="]) {
                        // NSSize/CGSize: {"width": 100, "height": 200}
                        CGSize sz = CGSizeMake([arg[@"width"] doubleValue], [arg[@"height"] doubleValue]);
                        [invocation setArgument:&sz atIndex:i + 2];
                    } else if ([typeStr hasPrefix:@"{CGRect="] || [typeStr hasPrefix:@"{NSRect="]) {
                        // NSRect/CGRect: {"x": 0, "y": 0, "width": 100, "height": 200}
                        CGRect rect = CGRectMake([arg[@"x"] doubleValue], [arg[@"y"] doubleValue],
                                                  [arg[@"width"] doubleValue], [arg[@"height"] doubleValue]);
                        [invocation setArgument:&rect atIndex:i + 2];
                    } else {
                        // Unknown struct - try to pass as-is
                        [invocation setArgument:&arg atIndex:i + 2];
                    }
                    break;
                }
                default:
                    [invocation setArgument:&arg atIndex:i + 2];
                    break;
            }
        }
        // Execute invocation and get return value on main thread
        // (required for UI operations and to keep autoreleased objects alive)
        const char *retType = sig.methodReturnType;
        __block id result = nil;

        void (^invokeAndGetResult)(void) = ^{
            @autoreleasepool {
                [invocation invoke];

                switch (retType[0]) {
                    case 'v': result = [NSNull null]; break;
                    case '@': case '#': {
                        void *rawPtr = NULL;
                        [invocation getReturnValue:&rawPtr];
                        if (rawPtr) {
                            id obj = (__bridge id)rawPtr;
                            result = objc_to_json(obj);
                        } else {
                            result = [NSNull null];
                        }
                        break;
                    }
                    case 'i': { int val = 0; [invocation getReturnValue:&val]; result = @(val); break; }
                    case 'I': { unsigned int val = 0; [invocation getReturnValue:&val]; result = @(val); break; }
                    case 'l': { long val = 0; [invocation getReturnValue:&val]; result = @(val); break; }
                    case 'L': { unsigned long val = 0; [invocation getReturnValue:&val]; result = @(val); break; }
                    case 'q': { long long val = 0; [invocation getReturnValue:&val]; result = @(val); break; }
                    case 'Q': { unsigned long long val = 0; [invocation getReturnValue:&val]; result = @(val); break; }
                    case 'f': { float val = 0; [invocation getReturnValue:&val]; result = @(val); break; }
                    case 'd': { double val = 0; [invocation getReturnValue:&val]; result = @(val); break; }
                    case 'B': { BOOL val = NO; [invocation getReturnValue:&val]; result = @(val); break; }
                    case '*': {
                        char *val = NULL;
                        [invocation getReturnValue:&val];
                        result = val ? [NSString stringWithUTF8String:val] : [NSNull null];
                        break;
                    }
                    case '{': {
                        // Struct return type
                        NSString *typeStr = [NSString stringWithUTF8String:retType];
                        if ([typeStr hasPrefix:@"{CGPoint="] || [typeStr hasPrefix:@"{NSPoint="]) {
                            CGPoint pt;
                            [invocation getReturnValue:&pt];
                            result = @{@"x": @(pt.x), @"y": @(pt.y)};
                        } else if ([typeStr hasPrefix:@"{CGSize="] || [typeStr hasPrefix:@"{NSSize="]) {
                            CGSize sz;
                            [invocation getReturnValue:&sz];
                            result = @{@"width": @(sz.width), @"height": @(sz.height)};
                        } else if ([typeStr hasPrefix:@"{CGRect="] || [typeStr hasPrefix:@"{NSRect="]) {
                            CGRect rect;
                            [invocation getReturnValue:&rect];
                            result = @{@"x": @(rect.origin.x), @"y": @(rect.origin.y),
                                       @"width": @(rect.size.width), @"height": @(rect.size.height)};
                        } else {
                            result = @{@"_rawType": typeStr};
                        }
                        break;
                    }
                    default:
                        result = @{@"_rawType": [NSString stringWithUTF8String:retType]};
                        break;
                }
            }
        };

        if ([NSThread isMainThread]) {
            invokeAndGetResult();
        } else {
            dispatch_sync(dispatch_get_main_queue(), invokeAndGetResult);
        }

        return @{@"result": result ?: [NSNull null]};

    } @catch (NSException *e) {
        return @{@"error": [NSString stringWithFormat:@"Exception: %@ - %@", e.name, e.reason]};
    }
}

#pragma mark - Connection

static void connect_to_service(void) {
    const char *service_name = getenv("MANTLE_SERVICE_NAME");
    if (!service_name) {
        NSLog(@"[Mantle] MANTLE_SERVICE_NAME not set, cannot connect");
        return;
    }

    NSLog(@"[Mantle] Connecting to service: %s", service_name);

    gClient = mantle_client_connect(service_name);
    if (!gClient) {
        NSLog(@"[Mantle] Failed to connect to service");
        return;
    }

    // Set up FFI handler
    mantle_client_set_handler(gClient, ^(NSDictionary *call, void (^reply)(NSDictionary *)) {
        @autoreleasepool {
            id response = execute_ffi_call(call);
            if (reply) {
                reply(response);
            }
        }
    });

    // Start listening for commands on a background queue
    dispatch_queue_t cmd_queue = dispatch_queue_create("com.mantle.client.cmd", DISPATCH_QUEUE_SERIAL);
    kern_return_t kr = mantle_client_start(gClient, cmd_queue);
    if (kr != KERN_SUCCESS) {
        NSLog(@"[Mantle] Failed to start client: %d", kr);
        mantle_client_disconnect(gClient);
        gClient = NULL;
        return;
    }

    NSLog(@"[Mantle] Connected and listening for FFI calls");
}

int64_t sandbox_extension_consume(const char* token);
void ConsumeToken(void) {
    const char * token = getenv("MANTLE_SANDBOX_TOKEN");
    sandbox_extension_consume(token);
}

__attribute__((constructor))
static void core_setup(void) {
    if (ShouldSkipProcess()) return;

    //dlopen("/private/var/ammonia/core/tweaks/libSharedGraphics.dylib.bak", RTLD_NOW);
    //dlopen("/private/var/ammonia/core/tweaks/libCatalinaUI.dylib", RTLD_NOW);

    ConsumeToken();

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        usleep(100000);
        connect_to_service();
    });

    unsetenv("DYLD_INSERT_LIBRARIES");
}

__attribute__((destructor))
static void core_teardown(void) {
    if (gClient) {
        mantle_client_disconnect(gClient);
        gClient = NULL;
    }
}
