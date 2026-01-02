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

              getWindowNumber(w.pid, w.ptr, (windowNumber) => {
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

                  placed.push({
                    ...w,
                    frame: f,
                    screen,
                    windowNumber,
                  });

                  done();
                });
              });
            });
          });
        });

        function done() {
          if (--pending === 0) layout(placed);
        }
      }

      function layout(windows) {
        screenInfo.forEach((screen) => {
          // SORTING BY PID HERE
          const ws = windows
            .filter((w) => w.screen === screen)
            .sort((a, b) => a.pid - b.pid);

          if (!ws.length) return;

          const f = screen.frame;
          const W = f.width - padding * 2;
          const H = f.height - padding * 2;

          if (ws.length === 1) {
            return WindowManager.setFrame(
              ws[0].pid,
              ws[0].ptr,
              {
                x: f.x + padding,
                y: f.y + padding,
                width: W,
                height: H,
              },
              false,
            );
          }

          const masterW = W * masterRatio;
          const stackW = W - masterW - padding;
          const stackH = (H - padding * (ws.length - 2)) / (ws.length - 1);

          WindowManager.setFrame(
            ws[0].pid,
            ws[0].ptr,
            {
              x: f.x + padding,
              y: f.y + padding,
              width: masterW,
              height: H,
            },
            false,
          );

          ws.slice(1).forEach((w, i) =>
            WindowManager.setFrame(
              w.pid,
              w.ptr,
              {
                x: f.x + padding + masterW + padding,
                y: f.y + padding + i * (stackH + padding),
                width: stackW,
                height: stackH,
              },
              false,
            ),
          );
        });
      }
    });
  });
}

setInterval(() => masterStackLayout(0.5, 125), 100);
