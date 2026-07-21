# ScreenFlip product and maintenance plan

## Product outcome

ScreenFlip makes one non-main macOS display usable behind teleprompter glass. The
physical panel shows a left-to-right flipped image while the presenter works in a
normal hidden workspace, so the glass reflection is readable and pointer motion and
click targets feel natural.

## Architecture

1. Create one headless workspace with macOS's private `CGVirtualDisplay` API.
2. Place that workspace beside the main display so macOS handles mouse, keyboard,
   clicks, drags, and app windows normally.
3. Capture the workspace at up to 60 fps with ScreenCaptureKit.
4. render the captured IOSurface into a click-through window on the selected output,
   using a GPU-composited horizontal transform.
5. Draw a passive proxy cursor at the mirrored coordinate. Do not install event taps
   or request Accessibility permission.
6. Save the physical display origins before activation and restore them on shutdown.

The virtual-display API is private. This prevents Mac App Store distribution and is
the main compatibility risk after macOS upgrades. ScreenCaptureKit and display-origin
configuration are public Apple APIs:

- https://developer.apple.com/documentation/screencapturekit/scstream
- https://developer.apple.com/documentation/coregraphics/cgconfiguredisplayorigin(_:_:_:_:)

## Safety rules

- Never offer the main display as a flipped output.
- Never expose a ScreenFlip-created virtual workspace in the display menu.
- Support one flipped output at a time until multi-output layout is explicitly designed.
- Restore the saved arrangement on normal quit and application termination.
- If the virtual display disappears, stop using stale cursor coordinates and rebuild it.

## Milestones

### v0.4 — maintainable macOS MVP

- [x] Build with current Apple command-line tools.
- [x] Limit selection to one non-main physical output.
- [x] Exclude ScreenFlip virtual workspaces from output selection.
- [x] Keep proxy cursor coordinates inside the output at both horizontal edges.
- [x] Add deterministic cursor-geometry tests.
- [x] Prepare a GitHub Actions build-and-test workflow in
      `macos/ci/github-actions-macos.yml`.
- [ ] Enable the workflow under `.github/workflows/` after the GitHub command-line
      token is granted its separate `workflow` permission.
- [x] Create and destroy the private virtual workspace on an M1 Max running macOS
      26.4.1, and verify it is excluded from physical output choices.
- [ ] Validate end-to-end on Apple Silicon with a main display plus teleprompter output.
- [ ] Measure capture latency and verify clicks, drags, text cursors, Mission Control,
      sleep/wake, hot-plug, and application crash recovery.
- [ ] Sign, notarize, and publish the v0.4 DMG.

### v0.5 — operator experience

- Add a guided first-run screen for display choice and Screen Recording permission.
- Add an emergency keyboard shortcut that disables flipping and restores arrangement.
- Add an in-app diagnostics view with versions, displays, permission state, and logs.
- Add launch-at-login and update-check preferences.

### v1.0 — supported release

- Maintain a tested macOS compatibility matrix.
- Add automated lifecycle and display-hot-plug tests where the OS permits them.
- Publish support, privacy, release, and rollback documentation.
- Decide whether the upstream owner will grant an open-source license; until then,
  preserve this work as a fork with the full original history and attribution.

## v0.4 hardware acceptance checklist

- The chosen physical display is fully covered; no unflipped desktop is visible.
- Text is horizontally reversed on the panel and reads normally through the glass.
- Moving the mouse left/right feels correct through the glass.
- Pointer hotspots align at the center and all four edges.
- Click, double-click, right-click, drag, scroll, and keyboard focus work normally.
- The main display is unaffected while ScreenFlip is active.
- Disconnecting the output, sleeping/waking, restarting capture, and quitting leave a
  usable desktop arrangement.
