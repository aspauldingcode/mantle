# Mantle

<p align="center">
  <img src="readme_icon.png" alt="Mantle Logo" width="100" height="100">
</p>
macOS IPC/FFI thing that runs JS to mess with windows and allow scripting in other processes.

## What it does

- **wm_init**: Root daemon that runs JavaScript and talks to other processes
- **libcore.dylib**: Gets injected everywhere, runs FFI calls sent from wm_init
- **Mach IPC**: How the daemon and injected libs talk to each other

## Quick start

```bash
./fetch_dobby.sh
./build.sh
./build/mantle your_script.js
```

## WindowManager API

```javascript
WindowManager.getClients(cb)
WindowManager.getFrame(pid, win, cb)
WindowManager.setFrame(pid, win, frame, animate, cb)
WindowManager.getScreens(pid, cb)
WindowManager.forEachWindow((pid, name, win) => {})
```

### Low-Level FFI

Mantle exposes a powerful FFI system that lets you call any C function or Objective-C method in target processes.

#### mantle_server_call(pid, request, callback)

Send an FFI request to a process. Returns `{result: value}` or `{error: "message"}`.

**Objective-C Method Calls:**

```javascript
mantle_server_call(pid, {
  method: "selectorName:",        // e.g., "frame", "setAlphaValue:", "makeKeyAndOrderFront:"
  target: "ClassName" or "0x1234", // Class name (NSApplication, NSWindow, NSScreen) or object pointer
  args: [arg1, arg2, ...],         // Arguments matching the selector
  returns: "id"                    // Return type (see below)
}, callback)
```

**C Function Calls:**

```javascript
mantle_server_call(pid, {
  method: "function_name",         // Symbol name from any loaded dylib
  target: null,
  args: [{type: "int", value: 42}], // Arguments with explicit types
  returns: "int"                   // Return type
}, callback)
```

**Supported Return Types:**

| Type | Description |
|------|-------------|
| `void` | No return value |
| `int`, `int32` | 32-bit signed integer |
| `uint`, `uint32` | 32-bit unsigned integer |
| `long`, `int64` | 64-bit signed integer |
| `ulong`, `uint64` | 64-bit unsigned integer |
| `float` | Single precision float |
| `double` | Double precision float |
| `bool` | Boolean (YES/NO) |
| `id`, `object` | Objective-C object (returns `{"_type":"ClassName","_ptr":"0x...","_description":"..."}`) |
| `string` | C string (returns JS string) |
| `pointer` | Raw pointer (returns hex string) |
| `class` | Objective-C class (returns class name string) |
| `sel` | Selector (returns selector string) |
| `{CGRect=dd}` | CGRect struct (returns `{x, y, width, height}`) |
| `{CGPoint=dd}` | CGPoint struct (returns `{x, y}`) |
| `{CGSize=dd}` | CGSize struct (returns `{width, height}`) |

**Examples:**

```javascript
// Get window frame
mantle_server_call(pid, {
  method: "frame",
  target: windowPtr,
  args: [],
  returns: "{CGRect=dd}"
}, (err, res) => console.log(res.result));

// Set window alpha
mantle_server_call(pid, {
  method: "setAlphaValue:",
  target: windowPtr,
  args: [0.5],
  returns: "void"
});

// Get main screen
mantle_server_call(pid, {
  method: "mainScreen",
  target: "NSScreen",
  args: [],
  returns: "id"
});

// Call C function (libc)
mantle_server_call(pid, {
  method: "getpid",
  target: null,
  args: [],
  returns: "int"
});
```

**Automatic Type Coercion:**
- Arguments are automatically converted based on the target method's signature
- Struct types (`CGRect`, `CGPoint`, `CGSize`, `NSRect`, etc.) accept plain objects with corresponding fields
- Boolean arguments accept JS booleans or numbers


## Build requirements

- macOS 11+
- Xcode CLI tools
- CMake 3.10+

## Support the project?
[![Ko-fi](https://img.shields.io/badge/Ko--fi-F16061?style=for-the-badge&logo=ko-fi&logoColor=white)](https://ko-fi.com/corebedtime)
