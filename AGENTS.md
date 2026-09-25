# NetUnstick contributor guidance

This repository is for a native macOS utility. Read `README.md` for the product scope and keep it aligned with implemented behavior. The app does not exist yet; do not present planned checks or repairs as working features.

## Architecture

- Use Swift and SwiftUI for the app and its primary interface. Use Apple's Network/SystemConfiguration APIs for observation when suitable; introduce AppKit for specific macOS integration only.
- Keep these responsibilities separate: network state collection, diagnosis, individual repair actions, session logging/export, and presentation.
- A diagnostic check must be read-only. A repair must be explicit, narrowly scoped, and independently testable.
- Do not add a full VPN implementation or modify FortiClient/FortiGate-managed settings.
- Choose a minimum macOS deployment target when creating the project, record it in `README.md`, and verify it in the build configuration.

## Diagnostic and repair contract

- Every check and repair returns a structured result with start/end time, outcome, sanitized evidence, and a stable error code when it fails. Do not use an unstructured console message as the only result.
- Show progress in the app during operations; show failure reasons and a next step in plain language. Maintain an expandable technical detail view.
- Capture relevant state before and after a repair and rerun the check it was meant to fix. Never report a repair as successful solely because a command exited with code 0.
- If VPN state is active or unknown, skip network-changing actions and explain why. Add timeouts and avoid repeating a failing action indefinitely.
- Never indiscriminately flush routes, DNS settings, firewall rules, or network services. Do not change FortiClient policy, disable protections, or reboot automatically.
- For a system command, use a fixed executable path and argument array; never interpolate user input into a shell string. Check the exit code and sanitize captured output. Document any privilege requirement before adding it.

## Logs and privacy

- Log diagnostics and errors with Apple's `Logger`. Keep a bounded, app-owned session record for the activity UI and export; do not depend on global system-log access.
- Include session ID, app/macOS version, action/check name, timing, result, error domain/code, and sanitized before/after evidence. Make skipped, cancelled, permission-denied, timeout, and failed outcomes distinguishable.
- Never log secrets, VPN credentials, tokens, keys, or packet contents. Redact or omit device names, Wi-Fi SSIDs, public IPs, and internal domains by default. Treat arbitrary command output as sensitive until sanitized.
- Export a readable UTF-8 report only after the user requests it, with a preview and a standard save dialog. No background upload or telemetry.
- Tests for the logging/export layer must check redaction and error paths with representative sensitive values.

## UI and icon

- Keep a standard macOS main window and visible Dock icon. A menu-bar entry is optional and supplementary.
- Follow system light/dark appearance, accent color, increased contrast, text scaling, reduced motion, keyboard navigation, and VoiceOver labels. Prefer semantic colors and native controls.
- Make the current network state, active operation, result, and next action immediately clear. Raw logs belong in expandable details, not the primary view.
- Supply a distinctive app icon in the Xcode asset catalog, legible at small Dock sizes, with supported appearance variants for the selected target. Check it visually in the Dock and Finder.

## Verification and documentation

- Build the macOS target after code changes. Add focused tests for diagnosis decisions, redaction/export, and repair success/failure paths; do not write tests that simply restate implementation.
- A repair is validated only after an observed failure is resolved and the before/after check confirms it. Until then, describe it as a candidate.
- Update `README.md` when behavior, permissions, supported macOS versions, export format, or known limitations change.
- Do not commit credentials, private network reports, or unredacted diagnostic exports.
