# Big Beautiful Data Monitor

<img src="Branding/Logo.png" width="240" alt="Big Beautiful Data Monitor glass-wave logo">

A native Mac menu bar app for seeing how much internet data your Mac uses and which apps use it, with a calm, visual interface.

The [product specification](SPEC.md) describes the experience; [App](App/) is the menu bar app and [Engine](Engine/) is the Swift package with the monitoring engine and storage. Requires macOS 26 or later and Swift 6.2. Everything stays on this Mac: no account, no cloud, no VPN, no permission prompts.

Logo artwork and its generation prompt are in [Branding](Branding/).

## Using it

- **Menu bar.** The small wave rises and falls with live activity. Click it to open the panel.
- **Panel.** Today's total, a ribbon of the last minute (downloads above the line, uploads below),
  and the apps active right now. Hover the total for an everyday comparison, hover the ribbon for
  that second's speed, hover an icon for its name and today's amount. Click an icon for details.
- **Open** shows the window, with three views:
  - **Now:** a pond of bubbles, one per active app. Busy apps swell; idle ones fade away.
  - **Day:** a 24-hour ring, midnight at the top. Hover a petal for that hour; click it to see its apps.
    Up to three short notes ("Moments") sit underneath; hover one and click the × to dismiss it.
  - **Month:** one circle per day, sized by that day's total. Click a day to open it.
- **⋯ menu** in the panel: Open at login, Show speed in menu bar, Reset data, Quit.
- Shortcuts while the window is in front: ⌘1, ⌘2, ⌘3 switch views; ⌘W closes the window.

## Where things live

- The app: `/Applications/Big Beautiful Data Monitor.app`
- Its history: `~/Library/Application Support/Big Beautiful Data Monitor/Usage.sqlite`
  (minute detail for 30 days, hourly totals forever; about 25 MB at most for the minute detail).

## Rebuilding after a change

In Terminal, from this folder:

```bash
./install.sh
```

Or in Xcode: open `App/Big Beautiful Data Monitor.xcodeproj`, pick **DataMonitor** in the scheme menu at
the top of the window, then choose **Product › Run**. (That runs a development copy from Xcode's build
folder; `install.sh` is what puts the real one in Applications.)

## Removing it

1. Click the wave, then **⋯ › Quit**.
2. Drag `Big Beautiful Data Monitor` from Applications to the Trash.
3. Optionally delete the folder `~/Library/Application Support/Big Beautiful Data Monitor`.
4. If it still appears under **System Settings › General › Login Items & Extensions**, remove it there.

## How it measures

The kernel's interface counters give the true total each second; a long-running `nettop` splits it by
app every second while a window is open, every 10 seconds otherwise. Each minute the per-app numbers
are fitted to the true total: packet headers are shared out by usage, and anything left unexplained
(for example file sharing done inside the kernel) is shown as "Mac system".

Proxies and VPN tunnels such as AdGuard and Tailscale resend other apps' traffic through their own
connections, so `nettop` sees those bytes twice. The app recognizes them from their network extension
type and counts them last: the app that asked for the data keeps it, and the proxy or tunnel only gets
what nothing else explains (its own updates, or tunnel traffic no app can be matched to).

Notes from building it on macOS 27, where the spec's assumptions did not hold:

| Spec said | What actually happens | What the app does |
|---|---|---|
| `NET_RT_IFLIST2` gives 64-bit totals | Only the low 32 bits, rounded to 1 KB | Reads `net.link.generic.ifdata`, exact to the byte |
| Read `nettop` through a pipe | Output arrives in 6-second clumps | Runs it on a pseudo-terminal |
| (not covered) | `nettop` spins at ~140% CPU when its input is closed | Gives it an input that never closes |
| (not covered) | An orphaned `nettop` keeps running after a crash | Ties it to the app; the kernel stops it |
| `nettop` defaults are fine | It also counts traffic that never leaves the Mac | Adds `-t wifi -t wired` |
| `proc_pidinfo` works for all processes | Refused for other users' processes | Uses the `kern.proc` sysctl |

The engine has its own command-line probe and tests:

```bash
cd Engine && swift test
```

```bash
Engine/.build/release/engine-probe --report
```
