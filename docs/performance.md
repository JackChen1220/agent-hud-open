# Local CPU verification

The soft glow in Settings uses a resting bitmap and a Core Animation opacity pulse. It no longer
rebuilds the SwiftUI preview for each display refresh. Bitmap and grid previews stop when their
window is closed, minimized or occluded, or their view is hidden, and resume when visible again.
Reduce Motion and frozen previews stay still.

Grid effects request a display-link rate that follows their breathing period and recent drawing
cost, shared across active displays. The existing drawing-time guard remains because a display
link can deliver callbacks above its requested rate. Hidden statistics windows also skip resizing
to updated content.

## Measuring a running copy

Build with `./scripts/build-app.sh release`, launch the resulting application, and verify that the
PID belongs to that exact executable. Allow first-run history indexing to finish before measuring
steady background use. Measure Settings, Statistics and the collapsed island separately; close
and reopen windows to check that their previews resume normally.

```sh
python3 scripts/measure-process-cpu.py PID --duration 30 --interval 5
```

This macOS-only reader measures the change in kernel user plus system CPU time over each wall-clock
interval. Its percentages use one CPU core as 100%. It reports the full-window mean and the maximum
interval mean; it does not measure sub-interval spikes. A process list's lifetime average is not
interchangeable with these measurements.

`PreviewLifecycleTests` checks bitmap reuse, animation restart avoidance, hidden/occluded/closed
window suspension and reopening, and the display-link budget. Its offscreen window explicitly
supplies visibility notifications because the display server may occlude every XCTest window.
These tests verify lifecycle logic; native desktop inspection is still required for acceptance.

## 2026-09-30 local validation

The installed 0.4.22 original and this 0.4.26-based local build read the same installed clients.
Settings and Statistics were closed during each 30-second background measurement. The local build
had finished history indexing and reported eight quota windows before the final measurement.

| Running copy | Main-process mean CPU | Maximum 5-second mean |
| --- | ---: | ---: |
| Original 0.4.22 | 1.549% | 1.780% |
| Local optimized 0.4.26 | 0.074% | 0.083% |

These are separate short observation windows, not a controlled benchmark of only this patch.
Upstream improvements since 0.4.22 also contribute. The values cover the main process; they exclude
separate client-engine and hook processes, and do not rule out short indexing or refresh peaks.
An earlier Settings measurement averaged 0.207%, but history indexing was still pending then.

The release build and signature verification passed. Native previews showed both soft and dot-grid
glows. The full release suite passed 659 XCTest tests with one skipped, plus four Swift Testing tests,
when the test runner's preferred language was explicitly English. Without that override, four existing
English-copy assertions fail on a Chinese system. The override was restored after the run.

The separate local app is installed in `~/Applications/Agent HUD Open.app`. The original installation
and preferences are retained. Startup registration has not been switched to the local copy.
