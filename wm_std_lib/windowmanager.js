// Mantle Window Manager API
// High-level API for managing windows across all connected applications

const WindowManager = {
  // Cache of known windows: { [pid]: { app: ptr, windows: [...] } }
  _cache: {},

  // Get all clients
  getClients(callback) {
    const clients = [];
    mantle_server_foreach_client((pid, processName) => {
      clients.push({ pid, processName });
    });
    if (callback) callback(clients);
    return clients;
  },

  // Get the NSApplication for a client
  getApplication(pid, callback) {
    mantle_server_call(
      pid,
      {
        method: "sharedApplication",
        target: "NSApplication",
        args: [],
        returns: "id",
      },
      (err, res) => {
        if (err) {
          callback(err, null);
        } else {
          callback(null, res.result);
        }
      },
    );
  },

  // Get all windows for an application (raw, includes invisible)
  getAllWindows(pid, appPtr, callback) {
    mantle_server_call(
      pid,
      {
        method: "windows",
        target: appPtr,
        args: [],
        returns: "id",
      },
      (err, res) => {
        if (err) {
          callback(err, null);
        } else {
          callback(null, res.result || []);
        }
      },
    );
  },

  // Get only visible, normal windows suitable for tiling
  getWindows(pid, appPtr, callback) {
    this.getAllWindows(pid, appPtr, (err, windows) => {
      if (err) {
        callback(err, null);
        return;
      }

      if (!windows || windows.length === 0) {
        callback(null, []);
        return;
      }

      // Filter windows asynchronously
      const validWindows = [];
      let pending = windows.length;

      windows.forEach((win) => {
        if (!win || !win._ptr) {
          pending--;
          if (pending === 0) callback(null, validWindows);
          return;
        }

        this.isWindowValid(pid, win._ptr, (valid) => {
          if (valid) {
            validWindows.push(win);
          }
          pending--;
          if (pending === 0) callback(null, validWindows);
        });
      });
    });
  },

  // Check if a window is valid for tiling (visible, on-screen, normal window)
  isWindowValid(pid, windowPtr, callback) {
    let checks = 4;
    let valid = true;

    const done = () => {
      checks--;
      if (checks === 0) callback(valid);
    };

    // Check if visible
    mantle_server_call(
      pid,
      {
        method: "isVisible",
        target: windowPtr,
        args: [],
        returns: "bool",
      },
      (err, res) => {
        if (err || !res.result) valid = false;
        done();
      },
    );

    // Check if not minimized
    mantle_server_call(
      pid,
      {
        method: "isMiniaturized",
        target: windowPtr,
        args: [],
        returns: "bool",
      },
      (err, res) => {
        if (err || res.result) valid = false;
        done();
      },
    );

    // Check frame size (reject zero-size or tiny windows)
    mantle_server_call(
      pid,
      {
        method: "frame",
        target: windowPtr,
        args: [],
        returns: "{CGRect=dd}",
      },
      (err, res) => {
        if (err || !res.result) {
          valid = false;
        } else {
          const frame = res.result;
          // Reject windows smaller than 50x50 or at weird positions
          if (frame.width < 50 || frame.height < 50) {
            valid = false;
          }
          // Reject windows way off screen (likely hidden)
          if (
            frame.x < -10000 ||
            frame.y < -10000 ||
            frame.x > 50000 ||
            frame.y > 50000
          ) {
            valid = false;
          }
        }
        done();
      },
    );

    // Check if it can become key window (filters out panels, popovers, etc.)
    mantle_server_call(
      pid,
      {
        method: "canBecomeKeyWindow",
        target: windowPtr,
        args: [],
        returns: "bool",
      },
      (err, res) => {
        if (err || !res.result) valid = false;
        done();
      },
    );
  },

  // Get the main window for an application
  getMainWindow(pid, appPtr, callback) {
    mantle_server_call(
      pid,
      {
        method: "mainWindow",
        target: appPtr,
        args: [],
        returns: "id",
      },
      (err, res) => {
        if (err) {
          callback(err, null);
        } else {
          callback(null, res.result);
        }
      },
    );
  },

  // Get the key window for an application
  getKeyWindow(pid, appPtr, callback) {
    mantle_server_call(
      pid,
      {
        method: "keyWindow",
        target: appPtr,
        args: [],
        returns: "id",
      },
      (err, res) => {
        if (err) {
          callback(err, null);
        } else {
          callback(null, res.result);
        }
      },
    );
  },

  // Get window frame
  getFrame(pid, windowPtr, callback) {
    mantle_server_call(
      pid,
      {
        method: "frame",
        target: windowPtr,
        args: [],
        returns: "{CGRect=dd}",
      },
      (err, res) => {
        if (err) {
          callback(err, null);
        } else {
          callback(null, res.result);
        }
      },
    );
  },

  // Set window frame
  setFrame(pid, windowPtr, frame, animate = false, callback) {
    mantle_server_call(
      pid,
      {
        method: "setFrame:display:animate:",
        target: windowPtr,
        args: [frame, true, animate],
        returns: "void",
      },
      (err, res) => {
        if (callback) callback(err, res);
      },
    );
  },

  // Get window title
  getTitle(pid, windowPtr, callback) {
    mantle_server_call(
      pid,
      {
        method: "title",
        target: windowPtr,
        args: [],
        returns: "id",
      },
      (err, res) => {
        if (err) {
          callback(err, null);
        } else {
          callback(null, res.result);
        }
      },
    );
  },

  // Set window title
  setTitle(pid, windowPtr, title, callback) {
    mantle_server_call(
      pid,
      {
        method: "setTitle:",
        target: windowPtr,
        args: [title],
        returns: "void",
      },
      (err, res) => {
        if (callback) callback(err, res);
      },
    );
  },

  // Minimize window
  minimize(pid, windowPtr, callback) {
    mantle_server_call(
      pid,
      {
        method: "miniaturize:",
        target: windowPtr,
        args: [null],
        returns: "void",
      },
      (err, res) => {
        if (callback) callback(err, res);
      },
    );
  },

  // Unminimize window
  unminimize(pid, windowPtr, callback) {
    mantle_server_call(
      pid,
      {
        method: "deminiaturize:",
        target: windowPtr,
        args: [null],
        returns: "void",
      },
      (err, res) => {
        if (callback) callback(err, res);
      },
    );
  },

  // Check if window is minimized
  isMinimized(pid, windowPtr, callback) {
    mantle_server_call(
      pid,
      {
        method: "isMiniaturized",
        target: windowPtr,
        args: [],
        returns: "bool",
      },
      (err, res) => {
        if (err) {
          callback(err, null);
        } else {
          callback(null, res.result);
        }
      },
    );
  },

  // Zoom window (maximize)
  zoom(pid, windowPtr, callback) {
    mantle_server_call(
      pid,
      {
        method: "zoom:",
        target: windowPtr,
        args: [null],
        returns: "void",
      },
      (err, res) => {
        if (callback) callback(err, res);
      },
    );
  },

  // Check if window is zoomed
  isZoomed(pid, windowPtr, callback) {
    mantle_server_call(
      pid,
      {
        method: "isZoomed",
        target: windowPtr,
        args: [],
        returns: "bool",
      },
      (err, res) => {
        if (err) {
          callback(err, null);
        } else {
          callback(null, res.result);
        }
      },
    );
  },

  // Close window
  close(pid, windowPtr, callback) {
    mantle_server_call(
      pid,
      {
        method: "close",
        target: windowPtr,
        args: [],
        returns: "void",
      },
      (err, res) => {
        if (callback) callback(err, res);
      },
    );
  },

  // Order window front
  orderFront(pid, windowPtr, callback) {
    mantle_server_call(
      pid,
      {
        method: "orderFront:",
        target: windowPtr,
        args: [null],
        returns: "void",
      },
      (err, res) => {
        if (callback) callback(err, res);
      },
    );
  },

  // Order window back
  orderBack(pid, windowPtr, callback) {
    mantle_server_call(
      pid,
      {
        method: "orderBack:",
        target: windowPtr,
        args: [null],
        returns: "void",
      },
      (err, res) => {
        if (callback) callback(err, res);
      },
    );
  },

  // Make window key and order front
  makeKeyAndOrderFront(pid, windowPtr, callback) {
    mantle_server_call(
      pid,
      {
        method: "makeKeyAndOrderFront:",
        target: windowPtr,
        args: [null],
        returns: "void",
      },
      (err, res) => {
        if (callback) callback(err, res);
      },
    );
  },

  // Set window alpha (opacity)
  setAlpha(pid, windowPtr, alpha, callback) {
    mantle_server_call(
      pid,
      {
        method: "setAlphaValue:",
        target: windowPtr,
        args: [alpha],
        returns: "void",
      },
      (err, res) => {
        if (callback) callback(err, res);
      },
    );
  },

  // Get window alpha
  getAlpha(pid, windowPtr, callback) {
    mantle_server_call(
      pid,
      {
        method: "alphaValue",
        target: windowPtr,
        args: [],
        returns: "double",
      },
      (err, res) => {
        if (err) {
          callback(err, null);
        } else {
          callback(null, res.result);
        }
      },
    );
  },

  // Set window level
  setLevel(pid, windowPtr, level, callback) {
    mantle_server_call(
      pid,
      {
        method: "setLevel:",
        target: windowPtr,
        args: [level],
        returns: "void",
      },
      (err, res) => {
        if (callback) callback(err, res);
      },
    );
  },

  // Check if window is visible
  isVisible(pid, windowPtr, callback) {
    mantle_server_call(
      pid,
      {
        method: "isVisible",
        target: windowPtr,
        args: [],
        returns: "bool",
      },
      (err, res) => {
        if (err) {
          callback(err, null);
        } else {
          callback(null, res.result);
        }
      },
    );
  },

  // Center window on screen
  center(pid, windowPtr, callback) {
    mantle_server_call(
      pid,
      {
        method: "center",
        target: windowPtr,
        args: [],
        returns: "void",
      },
      (err, res) => {
        if (callback) callback(err, res);
      },
    );
  },

  // Get screen info
  getMainScreen(pid, callback) {
    mantle_server_call(
      pid,
      {
        method: "mainScreen",
        target: "NSScreen",
        args: [],
        returns: "id",
      },
      (err, res) => {
        if (err) {
          callback(err, null);
        } else {
          callback(null, res.result);
        }
      },
    );
  },

  // Get all screens
  getScreens(pid, callback) {
    mantle_server_call(
      pid,
      {
        method: "screens",
        target: "NSScreen",
        args: [],
        returns: "id",
      },
      (err, res) => {
        if (err) {
          callback(err, null);
        } else {
          callback(null, res.result || []);
        }
      },
    );
  },

  // Get screen frame
  getScreenFrame(pid, screenPtr, callback) {
    mantle_server_call(
      pid,
      {
        method: "frame",
        target: screenPtr,
        args: [],
        returns: "{CGRect=dd}",
      },
      (err, res) => {
        if (err) {
          callback(err, null);
        } else {
          callback(null, res.result);
        }
      },
    );
  },

  // Get visible frame (excluding menu bar and dock)
  getScreenVisibleFrame(pid, screenPtr, callback) {
    mantle_server_call(
      pid,
      {
        method: "visibleFrame",
        target: screenPtr,
        args: [],
        returns: "{CGRect=dd}",
      },
      (err, res) => {
        if (err) {
          callback(err, null);
        } else {
          callback(null, res.result);
        }
      },
    );
  },

  // Helper: Iterate all valid windows across all clients
  forEachWindow(callback, onComplete) {
    const clients = this.getClients();
    if (clients.length === 0) {
      if (onComplete) onComplete();
      return;
    }

    let pending = clients.length;

    clients.forEach((client) => {
      this.getApplication(client.pid, (err, app) => {
        if (err || !app) {
          pending--;
          if (pending === 0 && onComplete) onComplete();
          return;
        }

        this.getWindows(client.pid, app._ptr, (err, windows) => {
          if (!err && windows) {
            windows.forEach((window, index) => {
              if (window && window._ptr) {
                callback(client.pid, client.processName, window, index);
              }
            });
          }
          pending--;
          if (pending === 0 && onComplete) onComplete();
        });
      });
    });
  },

  // Helper: Iterate windows only for non-problematic clients
  forEachSafeWindow(callback, onComplete) {
    const clients = this.getSafeClients();
    if (clients.length === 0) {
      if (onComplete) onComplete();
      return;
    }

    let pending = clients.length;

    clients.forEach((client) => {
      this.getApplication(client.pid, (err, app) => {
        if (err || !app) {
          pending--;
          if (pending === 0 && onComplete) onComplete();
          return;
        }

        this.getWindows(client.pid, app._ptr, (err, windows) => {
          if (!err && windows) {
            windows.forEach((window, index) => {
              if (window && window._ptr) {
                callback(client.pid, client.processName, window, index);
              }
            });
          }
          pending--;
          if (pending === 0 && onComplete) onComplete();
        });
      });
    });
  },

  // Get all valid windows from all clients at once
  getAllValidWindows(callback) {
    const clients = this.getClients();
    if (clients.length === 0) {
      callback([]);
      return;
    }

    const allWindows = [];
    let pending = clients.length;

    clients.forEach((client) => {
      this.getApplication(client.pid, (err, app) => {
        if (err || !app) {
          pending--;
          if (pending === 0) callback(allWindows);
          return;
        }

        this.getWindows(client.pid, app._ptr, (err, windows) => {
          if (!err && windows) {
            windows.forEach((win) => {
              if (win && win._ptr) {
                allWindows.push({
                  pid: client.pid,
                  processName: client.processName,
                  ptr: win._ptr,
                  _type: win._type,
                });
              }
            });
          }
          pending--;
          if (pending === 0) callback(allWindows);
        });
      });
    });
  },

  // Get all valid windows from non-problematic clients
  getSafeWindows(callback) {
    const clients = this.getSafeClients();
    if (clients.length === 0) {
      callback([]);
      return;
    }

    const allWindows = [];
    let pending = clients.length;

    clients.forEach((client) => {
      this.getApplication(client.pid, (err, app) => {
        if (err || !app) {
          pending--;
          if (pending === 0) callback(allWindows);
          return;
        }

        this.getWindows(client.pid, app._ptr, (err, windows) => {
          if (!err && windows) {
            windows.forEach((win) => {
              if (win && win._ptr) {
                allWindows.push({
                  pid: client.pid,
                  processName: client.processName,
                  ptr: win._ptr,
                  _type: win._type,
                });
              }
            });
          }
          pending--;
          if (pending === 0) callback(allWindows);
        });
      });
    });
  },
};

// Window level constants
const WindowLevel = {
  normal: 0,
  floating: 3,
  submenu: 3,
  tornOffMenu: 3,
  mainMenu: 24,
  status: 25,
  modalPanel: 8,
  popUpMenu: 101,
  screenSaver: 1000,
};

// Export for use
if (typeof module !== "undefined") {
  module.exports = { WindowManager, WindowLevel };
}
