# Big Beautiful Data Monitor

Oct 21, 2026 · @Davis Deaton

## The idea

Big Beautiful Data Monitor is a Mac menu bar app that shows, live and beautifully, how much internet data the Mac uses and which apps use it. It reads counters macOS already keeps, so there is no VPN, no account, no cloud and no permission prompts. Anyone should understand any screen in ten seconds without reading more than a few words.

It is built for one person on one Mac, so it skips App Store rules. Note for the builder: verify every macOS API and `nettop` flag named here on the target Mac before relying on it.

## Design principles

Pretty first, numbers on demand. If a screen looks like a dashboard, it is wrong.

- **One big number, one living picture.** Each screen leads with a single figure and a single visual. Everything else is secondary.
- **Numbers on demand.** No axes, gridlines, legends or tables at rest. Hover or click reveals exact figures.
- **App icons are the labels.** Use each app's real icon instead of its name wherever possible.
- **Plain words only.** "iCloud", not "cloudd". "Today", not "24h". Words like bytes, throughput, process and interface never appear in the UI.
- **The ten-second test.** A first-time viewer can say how much was used and by what, without help.
- **Calm, not busy.** Motion is slow and gentle. Nothing blinks, alerts or asks for attention.
- **Friendly units.** Auto-scale between KB, MB and GB with at most one decimal. On hover, an optional relatable equivalent such as "about 40 minutes of HD video", based on Netflix's published estimate of roughly 3 GB per hour for HD (confirm the current figure).

## The experience

Seven pieces, each one glance deep. The main window switches between Now, Day and Month with a quiet segmented control; no sidebar, no toolbar clutter, no settings on screen.

1. **Menu bar.** A small monochrome wave that gently rises and falls with live activity. Optional setting: show the live speed beside it.
2. **Popover.** Clicking the menu bar opens a frosted glass panel:
   - Today's total in large rounded numerals ("2.4 GB") with a small "today" beneath
   - A live ribbon of the last 60 seconds, downloads flowing above a center line and uploads mirrored below
   - The 3 to 5 apps active right now as icons, each with a soft halo that pulses with its live usage
   - One button to open the full window, and a small menu for settings
3. **Now.** A calm pond of floating glass bubbles, one per active app with its icon inside. Busy apps swell, idle ones shrink and fade away. Tiny particles drift into a bubble for downloads and out of it for uploads, with today's total resting at the center.
4. **Day.** A 24-hour ring like a clock face, midnight at the top. Each hour is a petal whose length is that hour's usage, tinted by its top app's color, and the current hour grows live. Clicking a petal blooms that hour's app icons around it; arrows step to earlier days.
5. **Month.** A calendar of soft circles, each sized by that day's total, with today gently pulsing. Clicking a day opens it in Day.
6. **App detail.** Clicking any app icon anywhere opens a sheet: the large icon, today and this month, its own small day ring, and one plain line such as "Usually busiest in the evening" once a week of data exists.
7. **Moments.** At most three one-line cards under the Day ring, generated automatically and dismissible:
   - The biggest spike, explained: "6.1 GB · macOS update · 2 PM"
   - While you were away: what moved while the Mac sat idle, and why
   - Compared to usual: "About a normal Wednesday" or "Twice your usual"

## Look and feel

Think Apple Weather and Fitness rings, not Activity Monitor or a server dashboard.

- **Color.** Each app's color comes from its own icon, computed once and cached. System activity is a soft neutral gray. Surfaces use macOS glass materials, with full light and dark mode.
- **Type.** SF Pro Rounded for numbers, large and light. Numbers roll smoothly when they change (SwiftUI's numeric text transition). Few labels, all in sentence case.
- **Motion.** Springs everywhere, nothing linear or jumpy. Drifts and pulses are slow, a few seconds per cycle. With Reduce Motion on, drift becomes gentle fades.
- **Down and up.** Never labeled with words. Downloads flow toward the app or sit above the line; uploads flow away or sit below, in a lighter shade of the same hue.
- **Avoid.** Gridlines, axis labels, legends, pie charts, tables, percentages everywhere, red and green alarm colors, dense sparklines.

## How it measures

Two built-in macOS sources and no VPN or network extension: interface counters give the true total, and `nettop` gives the per-app split.

&#91;embedded content: how the app measures · 2 sources, 2 stores\]

The interface counters set the real total, `nettop` splits it by app, and anything unexplained shows as Mac system.

1. **The true total.** Read the network interface byte counters in-process every second with `sysctl` and `NET_RT_IFLIST2`, which returns 64-bit counters (the simpler `getifaddrs` counters are 32-bit and wrap at 4 GB). Count physical interfaces only (Wi-Fi, Ethernet, iPhone hotspot) and skip loopback and VPN tunnels (`utun`) so nothing counts twice. This costs almost nothing.
2. **The per-app split.** Run one long-lived `nettop` child process in logging mode with per-process summaries, delta mode, raw numbers and a fixed sample interval. Parse its CSV output line by line from stdout. One persistent process is far cheaper than launching `nettop` every second.
3. **Reconcile.** Each minute, compare the app totals with the interface total and show the gap as "Mac system". Every screen then adds up to the real number.
4. **Network type.** Tag each sample with the current network type (Wi-Fi, wired or iPhone hotspot) from `NWPathMonitor`. Every network counts toward the totals, with a quiet icon on days a hotspot was used.
5. **Idle detection.** Flag minutes with no keyboard or mouse input (`CGEventSource` seconds since last event) so Moments can say what happened while you were away.

Before writing the parser, run `man nettop` on the target Mac to confirm flag names, then save real output as test fixtures.

## Naming apps

Raw data names helper processes, not apps, so attribution is the difference between "Google Chrome Helper (Renderer)" and a Chrome icon. `nettop` also truncates names, so always resolve by process ID. Try these in order and stop at the first hit:

1. **Responsible app.** The private `responsibility_get_pid_responsible_for_pid` function, loaded with `dlsym`, is how Activity Monitor groups helpers under their app. It should map Safari's WebKit networking process to Safari; verify this.
2. **Enclosing app bundle.** Get the executable path with `proc_pidpath` and take the outermost `.app` in it. Chrome's helpers live inside Google Chrome.app, so they roll up.
3. **Parent process.** Walk parent process IDs until one belongs to an app.
4. **Friendly name table** for system processes. Starting list, to confirm against real traffic:

| Process | Shown as |
| --- | --- |
| nsurlsessiond | Background downloads |
| cloudd, bird, fileproviderd | iCloud |
| cloudphotod | iCloud Photos |
| softwareupdated | macOS updates |
| apsd | Notifications |
| mDNSResponder | Network housekeeping |
| trustd | Security checks |

Anything still unknown rolls into "Mac system" and is logged in debug builds only, never shown as a raw name. Cache results by process ID plus start time (`proc_pidinfo`), since IDs get reused. App icons come from `NSWorkspace`; system rows get simple SF Symbols.

## Storage

Live detail stays in memory; only small per-minute summaries go to disk, written once a minute.

- **Live buffer.** The last 15 minutes at one-second resolution, in memory only. It feeds the popover ribbon and the Now view.
- **Database.** SQLite through GRDB, in Application Support, one write transaction per minute.
- **Tables.** `apps` (id, display name, bundle id, icon color), `usage_minute` (minute, app, network type, bytes down, bytes up) and `total_minute` (minute, network type, bytes down, bytes up, idle flag), plus matching hourly tables.
- **Retention.** Minute rows for 30 days, then rolled into hourly rows kept forever. The roll-up runs once a day in the background.

Size math, as an upper bound: 25 active apps × 1,440 minutes × about 50 bytes per row is roughly 1.8 MB a day, or about 55 MB for the 30-day minute tier. Hourly rows add about 11 MB a year (25 × 24 × 365 × 50 bytes). Real use will be lower because most minutes have only a few active apps.

## Performance budget

Target under 1% average CPU and under 80 MB of memory, with no noticeable battery impact. These are targets to measure with Instruments, not known numbers.

| Situation | Total counters | Per-app sampling | Drawing |
| --- | --- | --- | --- |
| Popover or window open | every 1 s | every 1 s | smooth live animation |
| Everything closed | every 1 s | every 10 s | menu bar wave redrawn once a second, no animation loop |
| Mac asleep | stopped | stopped | none |

- Changing the per-app interval means restarting the `nettop` child with a new interval. That is cheap and fine.
- Delta mode means slower sampling loses no bytes. Very short-lived processes may be missed, and the reconcile step counts their bytes as "Mac system".
- Stop sampling on sleep and restart on wake (`NSWorkspace` notifications). Keep sampling when only the display is off, since overnight iCloud and update traffic is part of the story.
- All parsing and aggregation run off the main thread; the UI reads snapshots.
- Animation loops (`TimelineView`, `Canvas`) run only while a window is visible.
- If `nettop` itself exceeds the CPU budget in testing, lengthen the closed-state interval first.

## Zero maintenance

The app should never need attention: failures degrade quietly instead of showing errors.

- **Self-healing sampler.** If `nettop` exits or stalls, restart it with backoff: 1 s, 5 s, 30 s, then every 5 minutes.
- **Format guard.** Check `nettop`'s header row on start. If a macOS update changes the format, fall back to totals only (one "All apps" bubble) and show a small dot in the menu, never an alert. The fix is a parser update.
- **Nothing leaves the Mac.** No accounts, no cloud, no network use of its own.
- **No permission prompts.** Nothing in v1 needs Location, Full Disk Access or Accessibility.
- **Launch at login** through `SMAppService`, on by default.
- **Self-pruning storage** per the retention rules. If the database is ever corrupt, set it aside and start fresh rather than crash.
- **Settings** are only three: launch at login, show live speed in the menu bar, and reset data.

## Build setup

A native Swift app built with Claude Code and Xcode on the target Mac, for personal use only.

- **Platform.** macOS 26 or later, Apple silicon, Swift 6, SwiftUI. Use the system's Liquid Glass materials.
- **App type.** Menu bar app with no Dock icon (`LSUIElement`), plus the main window it opens.
- **Sandbox off.** The app launches `nettop` and inspects other processes, which the App Sandbox blocks. That rules out the Mac App Store, which is fine here.
- **Signing.** "Sign to Run Locally" in Xcode, installed to Applications. No developer account and nothing that expires. If launch at login misbehaves with local signing, switch to a free personal team.
- **Dependencies.** GRDB through Swift Package Manager, nothing else. Most visuals are custom SwiftUI shapes and `Canvas`, not chart libraries.

## Build order

Prove the numbers before any design work, then build outward from the menu bar.

1. **Engine probe.** A command-line target that prints live per-app usage every second. Confirms `nettop` flags, parser fixtures, interface counters and attribution.
2. **Accuracy check.** Download a known large file and confirm it lands under the right app at about its real size.
3. **Storage and roll-ups.**
4. **Menu bar and popover.** The first piece that feels like the product.
5. **Now, Day, Month and app detail.**
6. **Moments.**
7. **Polish and performance pass.** Instruments against the budget, sleep and wake, reboot, Reduce Motion, light and dark.

### Done when

- [ ] App totals plus "Mac system" equal the interface total every minute
- [ ] "Mac system" stays a small share in normal use (target under 10%; grow the name table if not)
- [ ] A 1 GB download shows as about 1 GB under the right app
- [ ] Average CPU stays under 1% with the app closed, measured over an hour
- [ ] Sleep, wake, reboot and network changes need no attention
- [ ] First launch shows zero permission prompts
- [ ] Someone who has never seen it can name today's total and the top app within ten seconds

## Not in scope

The app counts and shows; it never controls anything.

- Blocking or limiting apps (that is what needs a VPN-style network extension)
- Per-website breakdown (needs DNS or packet inspection)
- Alerts, notifications and data caps
- Cloud sync, accounts or an iPhone app
- Wi-Fi network names, which need Location permission (a possible v2)
