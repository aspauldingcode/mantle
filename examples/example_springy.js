// --- Physics Configuration ---
const ANIMATION_CONFIG = {
  stiffness: 0.12, // Bounciness/Speed
  damping: 0.8, // Friction (0.8 = smooth stop, 0.5 = bouncy)
  threshold: 0.5, // Pixel precision
  fps: 60,
};

function isWindowResizable(pid, ptr, cb) {
  mantle_server_call(
    pid,
    {
      method: "styleMask",
      target: ptr,
      args: [],
      returns: "unsigned long long",
    },
    (_, res) => cb(!!(res?.result & 8)),
  );
}

function getWindowNumber(pid, ptr, cb) {
  mantle_server_call(
    pid,
    {
      method: "windowNumber",
      target: ptr,
      args: [],
      returns: "int",
    },
    (_, res) => cb(res?.result ?? 0),
  );
}

// --- Animation System ---
const SpringAnimator = {
  states: new Map(),
  key: (pid, ptr) => `${pid}:${ptr}`,

  setTarget: function (pid, ptr, targetFrame, initialFrame) {
    const k = this.key(pid, ptr);
    if (!this.states.has(k)) {
      this.states.set(k, {
        pid,
        ptr,
        current: { ...initialFrame },
        target: targetFrame,
        velocity: { x: 0, y: 0, width: 0, height: 0 },
        isResting: false,
      });
    } else {
      const state = this.states.get(k);
      if (this.needsUpdate(state.target, targetFrame)) {
        state.target = targetFrame;
        state.isResting = false;
      }
    }
  },

  needsUpdate: (a, b) =>
    a.x !== b.x || a.y !== b.y || a.width !== b.width || a.height !== b.height,

  tick: function () {
    this.states.forEach((state) => {
      if (state.isResting) return;

      let active = false;
      ["x", "y", "width", "height"].forEach((prop) => {
        const dist = state.target[prop] - state.current[prop];
        state.velocity[prop] += dist * ANIMATION_CONFIG.stiffness;
        state.velocity[prop] *= ANIMATION_CONFIG.damping;
        state.current[prop] += state.velocity[prop];

        if (
          Math.abs(dist) > ANIMATION_CONFIG.threshold ||
          Math.abs(state.velocity[prop]) > ANIMATION_CONFIG.threshold
        ) {
          active = true;
        } else {
          state.current[prop] = state.target[prop];
          state.velocity[prop] = 0;
        }
      });

      if (active) {
        WindowManager.setFrame(
          state.pid,
          state.ptr,
          {
            x: Math.round(state.current.x),
            y: Math.round(state.current.y),
            width: Math.round(state.current.width),
            height: Math.round(state.current.height),
          },
          false,
        );
      } else {
        state.isResting = true;
      }
    });
  },
};

// Physics loop
setInterval(() => SpringAnimator.tick(), 1000 / ANIMATION_CONFIG.fps);

// --- Layout Logic ---

function masterStackLayout(masterRatio = 0.6, padding = 10) {
  WindowManager.getClients((clients) => {
    if (!clients.length) return;
    const pid0 = clients[0].pid;

    WindowManager.getScreens(pid0, (e, screens) => {
      if (e || !screens?.length) return;
      const screenInfo = [];
      let pendingScreens = screens.length;

      screens.forEach((s) =>
        WindowManager.getScreenVisibleFrame(pid0, s._ptr, (_, f) => {
          if (f) screenInfo.push({ ptr: s._ptr, frame: f });
          if (--pendingScreens === 0) collectWindows();
        }),
      );

      function collectWindows() {
        const windows = [];
        WindowManager.forEachWindow(
          (pid, _, win) => windows.push({ pid, ptr: win._ptr }),
          () => processWindows(windows),
        );
      }

      function processWindows(wins) {
        const placed = [];
        let pending = wins.length;
        if (!pending) return;

        wins.forEach((w) => {
          WindowManager.isVisible(w.pid, w.ptr, (_, vis) => {
            if (!vis) return done();
            isWindowResizable(w.pid, w.ptr, (resizable) => {
              if (!resizable) return done();
              WindowManager.getFrame(w.pid, w.ptr, (_, f) => {
                if (!f) return done();

                const cx = f.x + f.width / 2;
                const cy = f.y + f.height / 2;
                const screen =
                  screenInfo.find(
                    (s) =>
                      cx >= s.frame.x &&
                      cy >= s.frame.y &&
                      cx <= s.frame.x + s.frame.width &&
                      cy <= s.frame.y + s.frame.height,
                  ) || screenInfo[0];

                placed.push({ ...w, frame: f, screen });
                done();
              });
            });
          });
        });

        function done() {
          if (--pending === 0) calculateTargets(placed);
        }
      }

      function calculateTargets(windows) {
        screenInfo.forEach((screen) => {
          // --- PID SORTING ADDED HERE ---
          const ws = windows
            .filter((w) => w.screen === screen)
            .sort((a, b) => a.pid - b.pid);

          if (!ws.length) return;

          const f = screen.frame;
          const W = f.width - padding * 2;
          const H = f.height - padding * 2;
          const apply = (win, target) =>
            SpringAnimator.setTarget(win.pid, win.ptr, target, win.frame);

          if (ws.length === 1) {
            return apply(ws[0], {
              x: f.x + padding,
              y: f.y + padding,
              width: W,
              height: H,
            });
          }

          const masterW = W * masterRatio;
          const stackW = W - masterW - padding;
          const stackH = (H - padding * (ws.length - 2)) / (ws.length - 1);

          // Master (Lowest PID)
          apply(ws[0], {
            x: f.x + padding,
            y: f.y + padding,
            width: masterW,
            height: H,
          });

          // Stack (Remaining PIDs)
          ws.slice(1).forEach((w, i) =>
            apply(w, {
              x: f.x + padding + masterW + padding,
              y: f.y + padding + i * (stackH + padding),
              width: stackW,
              height: stackH,
            }),
          );
        });
      }
    });
  });
}

setInterval(() => masterStackLayout(0.5, 128), 128);
