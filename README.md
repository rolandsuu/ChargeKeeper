# ChargeKeeper

A personal Mac app for controlling battery charging on Apple silicon: a charge limit, heat protection, a switch for the MagSafe light, and a live view of where the power is going. It's a regular window app with no menu bar icon, and a small background service does the work whether the window is open or not.

Built for and tested on an M2 MacBook Air, on macOS 27.0.1 and 27.2.

## How it works

ChargeKeeper doesn't stop charging itself. It moves **Apple's own charge limit**, and macOS enforces that limit.

- **The limit outlives the app.** macOS holds it, so it stays in place during sleep and if the service stops.
- **The app never cuts power itself.** Its only SMC write is to the MagSafe light, and it can't write anything else. What happens on the charger is up to macOS:
  - **Below the limit:** the battery charges.
  - **At the limit:** charging stops and the Mac runs from the charger.
  - **Above the limit:** the Mac runs on battery until it drains down to the limit, even though it's plugged in. On the M2 Air, the charger dropped to about 0.3 W during this.
- **The worst likely failure is a limit stuck too low.** The battery would drain to that level and hold there, and a limit can't be set below 10%.

Apple's own setter stops at 80%. Lower values are written to the preference `PowerUIAgent` reads (`com.apple.smartcharging.topoffprotection`), which needs root. That's why there's a background service.

**This relies on undocumented Apple behaviour, so a macOS update could break it.** Every change is checked against what `pmset -g battlimit` reports, and the window warns you if the two disagree. macOS only lists the limit while the charger is attached, so the check is skipped on battery and runs again as soon as you plug in.

## Building and installing

Needs the Command Line Tools or Xcode, and an Apple Development certificate. Set `SIGNING_IDENTITY` in `scripts/build.sh` and `Identity.teamID` in `Sources/Shared/ServiceProtocol.swift` to your own.

Xcode is only needed to recompile the icon after editing it. Without Xcode, the build uses the compiled copy in `Resources/CompiledIcon`.

```bash
scripts/build.sh
```

This builds, signs and installs `/Applications/ChargeKeeper.app`. Open the app, choose **Install background service**, then switch on ChargeKeeper in **System Settings → General → Login Items & Extensions**.

When you install a new build, the running service notices within 30 seconds and restarts on the new version.

The app isn't notarized, so it's meant for the Mac it's built on. When the signing certificate expires, it may need rebuilding.

## Using it

| Control | What it does |
|---|---|
| **Stop charging at** | Sets the limit from 10% to 99%. 100% means no limit. Raising a limit usually applies at once. Lowering one can take a minute or two. |
| **Charge to 100% once** | Lifts the limit until the battery is full, then returns to it. |
| **Pause charging when hot** | At the set temperature, sets a temporary limit 1% above the current charge, so charging stops without draining the battery. Resumes 2°C below that temperature. There's no new pause below 20%. |
| **Show the MagSafe light** | Off by default. macOS lights it again whenever you plug in, and the service switches it off within about half a second. Turning this on hands the light back to macOS. |

While the service is installed, it reapplies your saved limit, so changes made in System Settings get overwritten.

## What to expect

- **Resume point is Apple's.** At the limit, charging restarts after about a 5% drop, and this isn't adjustable.
- **Occasional charge to 100%.** Apple says the Mac sometimes does this to keep its estimates accurate. Other people have reported the limit being suspended if the battery hasn't reached 100% in about 21 days.
- **The heat check only runs while awake.** A pause already in place stays during sleep, but a new one can't start until the Mac wakes.
- **A low heat threshold will trip often** on a fanless Air.
- **Plugging in while asleep hasn't been tested.** The service can't act during sleep, so the MagSafe light may stay on until the Mac wakes.

## Uninstalling

1. Open ChargeKeeper and choose **Remove background service**. This restores your saved limit, hands the MagSafe light back to macOS, and deletes the service's files.
2. Move ChargeKeeper to the Trash.

The limit itself stays in macOS. To change or remove it afterwards, use **System Settings → Battery → Charging**. Limits below 80% can't be set there, so raise the limit in ChargeKeeper before removing the service if you want System Settings to manage it.

## Project layout

| Path | Purpose |
|---|---|
| `Sources/ChargeKeeper/` | SwiftUI window, and registration of the service |
| `Sources/ChargeKeeperService/` | The root service: XPC commands, 30-second cycle, saved state |
| `Sources/Shared/ChargeLimit.swift` | Reads and sets Apple's limit, and confirms changes |
| `Sources/Shared/Policy.swift` | The heat decisions, as a pure function |
| `Sources/Shared/Battery.swift` | Battery registry and sensor readings, read-only |
| `Sources/Shared/SMC.swift` | All SMC access: reading, and the one write for the MagSafe light |
| `scripts/build.sh` | Builds, signs and installs. `--test` adds a command-line test driver |
| `Resources/AppIcon.icon` | The Liquid Glass app icon, which you can open in Icon Composer |
| `Resources/CompiledIcon/` | The compiled icon, used when Xcode isn't installed |

## Security

The service only accepts connections from ChargeKeeper signed with the same developer certificate. It offers six commands: get state, set limit, set heat protection, charge to 100%, turn the MagSafe light on or off, and prepare for removal. There's no way to run commands or write arbitrary settings through it.

The only SMC write is in `SMC.swift`, and it's `fileprivate` to that file. It can write one key, `ACLC`, and only after checking that it's a one-byte value. The only values it can write are `0x00` (macOS controls the light) and `0x01` (off). The key that cuts wall power, `CHIE`, is never touched.

The app bundle is writable by your user, but launchd checks the service's signature before running it as root. A test on macOS 27.2 confirmed this: an ad hoc signed replacement was killed with `OS_REASON_CODESIGNING` and never ran. A swap like that leaves launchd unable to start the job even once the real file is back, so use **Restart background service** in the window to recover.

The command-line test driver is compiled in only with `scripts/build.sh --test`, so normal builds can't be driven by other programs through the app.

Run the unit tests with `swift test`. They use Swift Testing, so they run with the Command Line Tools as well as Xcode.
