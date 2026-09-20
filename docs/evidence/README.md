# Evidence renders

Images referenced from PR bodies, kept here because `gh` cannot attach files to
a pull request and a SPEC §9.1 tint change is not reviewable from numbers alone.

Every file is produced by rendering through the shipping path
(`StatusItemIcon.apply`), never by screenshotting a running app, so what it
shows is what the code draws. The harness is a throwaway XCTest in
`Tests/ContextBuddyAppTests/`; it is not committed, because a render is
evidence for one change, not a gate. The numbers beside each render are the
resolved-tint contrasts §9.1's table states — see SPEC §9.1 on why contrast is
never measured from rendered pixels.

| File | Change |
|---|---|
| `89-sleep-before-after.png` | #89: `sleep` loses its 3:1 exemption. `.secondaryLabelColor` -> white at alpha 0.60 (dark) / black at alpha 0.55 (light). |
