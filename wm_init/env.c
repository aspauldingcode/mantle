/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2022 Procursus Team <team@procurs.us>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice, this
 *    list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
 * OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */
#include <MacTypes.h>
#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <xpc/xpc.h>
#include "xpc_private.h"

#define OS_ALLOC_ONCE_KEY_LIBXPC 1

struct xpc_global_data {
	uint64_t a;
	uint64_t xpc_flags;
	mach_port_t task_bootstrap_port; /* 0x10 */
#ifndef _64
	uint32_t padding;
#endif
	xpc_object_t xpc_bootstrap_pipe; /* 0x18 */
};

struct _os_alloc_once_s {
	long once;
	void *ptr;
};

extern struct _os_alloc_once_s _os_alloc_once_table[];

void launchctl_setup_xpc_dict(xpc_object_t dict) {
	if (__builtin_available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, bridgeOS 6.0, *)) {
		xpc_dictionary_set_uint64(dict, "type", 7);
	} else {
		xpc_dictionary_set_uint64(dict, "type", 1);
	}
	xpc_dictionary_set_uint64(dict, "handle", 0);
	return;
}

int launchctl_send_xpc_to_launchd(uint64_t routine, xpc_object_t msg, xpc_object_t *reply) {
	xpc_object_t bootstrap_pipe =
	    ((struct xpc_global_data *)_os_alloc_once_table[OS_ALLOC_ONCE_KEY_LIBXPC].ptr)->xpc_bootstrap_pipe;

	// Routines that act on a specific service are in the subsystem 2
	// but that require a domain are in the subsystem 3 these are also
	// divided into the routine numbers 0x2XX and 0x3XX, so a quick and
	// dirty bit shift will let us get the correct subsystem.
	xpc_dictionary_set_uint64(msg, "subsystem", routine >> 8);
	xpc_dictionary_set_uint64(msg, "routine", routine);
	int ret = 0;

	if (__builtin_available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, bridgeOS 6.0, *)) {
		ret = _xpc_pipe_interface_routine(bootstrap_pipe, 0, msg, reply, 0);
	} else {
		ret = xpc_pipe_routine(bootstrap_pipe, msg, reply);
	}
	if (ret == 0 && (ret = xpc_dictionary_get_int64(*reply, "error")) == 0)
		return 0;

	return ret;
}

const char* SessionGetEnvironment(const char *name) {
    if (name == NULL) return NULL;

    xpc_object_t dict, reply;
    const char *val = NULL;

    dict = xpc_dictionary_create(NULL, NULL, 0);
    launchctl_setup_xpc_dict(dict);
    xpc_dictionary_set_string(dict, "envvar", name);

    if (launchctl_send_xpc_to_launchd(XPC_ROUTINE_GETENV, dict, &reply) == 0) {
        val = xpc_dictionary_get_string(reply, "value");
    }

    xpc_release(dict);
    return val;
}

int64_t SessionSetEnvironment(const char *name, const char *value) {
    if (name == NULL || value == NULL) return false;

    xpc_object_t dict, env, reply;

    dict = xpc_dictionary_create(NULL, NULL, 0);
    launchctl_setup_xpc_dict(dict);

    env = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(env, name, value);
    xpc_dictionary_set_value(dict, "envvars", env);
    xpc_release(env);

    int ret = launchctl_send_xpc_to_launchd(XPC_ROUTINE_SETENV, dict, &reply);

    xpc_release(dict);

    return ret;
}
