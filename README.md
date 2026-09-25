# NetUnstick

NetUnstick is a native macOS app for diagnosing and repairing local-network connectivity after disconnecting from a VPN. The first target is FortiClient connected to FortiGate. A Mac may appear connected to Wi-Fi yet fail to discover or reach a TV, another Mac, or another device until macOS is restarted. NetUnstick aims to identify the cause and apply the smallest useful repair without rebooting.

**Status:** product and implementation plan. There is no working app yet, and no repair is considered proven until it resolves a reproduced failure.

## Product behavior

- Show the current Wi-Fi and VPN state, the result of each diagnostic check, and what the app is doing now.
- Provide an explicit **Check Network** action. Present a recommended repair only when the evidence supports one; show its likely effect before running it.
- Distinguish device discovery failures (Bonjour/mDNS), name resolution failures (DNS), and direct connectivity or routing failures. Permit a known device address for a direct-connection check.
- Record a before-and-after snapshot for each repair. Report success only when the relevant check improves; otherwise show what failed and a useful next step.
- Keep each operation bounded and cancellable where possible. Never silently restart macOS or change FortiClient/FortiGate policy.
- Avoid network-changing repairs while a VPN tunnel is active. If the state is uncertain, stop and explain why.

The initial repair candidates are refreshing Wi-Fi/DHCP state, refreshing name resolution or local discovery, and restoring a clearly identified stale setting. They are **hypotheses**, not a blanket reset sequence. Do not delete routes, DNS settings, or firewall rules just because they look VPN-related. A future incident should supply the evidence needed to prioritize and validate them.

## Activity and diagnostic logs

The app must make its work visible in a dedicated activity view, including progress, timestamps, check/repair names, results, and failures. A concise status belongs in the main window; expandable details explain what was checked and what changed.

Each diagnostic session should have a stable ID and record:

- App and macOS versions; FortiClient version and VPN type when detectable or provided by the user.
- Check/repair start and end times, duration, outcome, and relevant error domain/code.
- Sanitized network state before and after an action, plus the result of the verification check.
- Whether an action was skipped, cancelled, denied permission, timed out, or failed.

Use Apple's unified logging (`Logger`) for developer diagnostics and an app-owned, bounded session history for the in-app activity view and export. Do not rely on reading the entire system log to build the user's export. Log failures with enough context to reproduce them, but never record VPN credentials, tokens, keys, or connection contents. Redact or omit private identifiers such as public IPs, device names, Wi-Fi SSIDs, and internal domains by default. Show the export preview and let the user save a UTF-8 diagnostic report to a chosen location. Export happens only on request; no automatic upload or telemetry.

## macOS experience

- Build in **Swift** with **SwiftUI**, using Apple's Network and SystemConfiguration frameworks where appropriate. Use AppKit only when a macOS capability needs it. Avoid third-party runtime dependencies in the first version.
- Use a standard macOS app with a main window and a visible **Dock icon**. A menu-bar shortcut can complement the window, but must not be the only way to open the app or inspect logs.
- Follow the system appearance automatically: light, dark, accent color, increased contrast, text scaling, reduced motion, and keyboard/VoiceOver access. Use native controls, semantic colors, and SF Symbols where they fit.
- Create a recognizable NetUnstick app icon that reads clearly at Dock size and fits current macOS icon conventions. Provide the required icon assets and appearance variants supported by the chosen Xcode/macOS target. Do not use a generic network symbol as the final app icon.
- Keep repair controls and activity history understandable without exposing raw command output as the primary interface. Advanced details may show sanitized technical data.

## Implementation boundaries

- Choose and document the minimum supported macOS version when the Xcode project is created; do not claim compatibility that has not been tested.
- Separate network observation, diagnosis, repair actions, logging/export, and UI so that diagnostics remain useful even when repair is unavailable.
- Prefer supported macOS APIs. If a repair must invoke a system utility, use a fixed command and arguments, capture its exit status and sanitized output, and explain any required privilege before requesting it. Never construct a shell command from user input.
- Do not build or replace a VPN client. Avoid changing FortiClient-managed configuration. If elevated operations become necessary, use a narrowly scoped helper and document its exact actions.
- Verify each proposed repair on a real failure when possible. Until then, label the result as unvalidated and retain the diagnostic evidence.

## First milestones

1. Native app shell, main status view, Dock icon, appearance and accessibility support.
2. Read-only network checks and visible session history with redacted export.
3. One conservative repair at a time, with before-and-after verification and clear errors.
4. Reproduce the FortiClient case, improve the checks from exported reports, and document which repairs actually work.

Relevant Apple guidance: [macOS app design](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/), [app icons](https://developer.apple.com/design/human-interface-guidelines/app-icons), [Network path monitoring](https://developer.apple.com/documentation/network/nwpathmonitor), and [unified logging](https://developer.apple.com/documentation/os/logging/).
