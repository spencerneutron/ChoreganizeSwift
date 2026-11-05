# Completion effects: handoff package

The "visual flair" patch, first experiment (started 2026-11-04). Three pieces, decided on 2026-11-05 after review in the playground:

1. **The wash.** A one-shot nebula that rolls across the Work day page behind the cards when the day's last open chore is completed. Shader iteration 06 "night haze", calm look, roll-through motion, 8 s.
2. **The section rim.** A hairline light on each section card's edge that fills round the perimeter with that section's progress, eases between levels, and is retraced in full when the section is finished. Honey by day, lavender by night, lit from outside only.
3. **The "promise" toggles.** Chore toggles whose off track is a quiet warm grey (morning, a promise not yet kept) and whose on track is a soft lavender (evening, kept).

`BEHAVIOR.md` is the specification: what triggers what, the timelines, the edge cases, and the open investigations. `tokens.json` holds every colour and number. `../STYLE.md` section 7 holds the generalized design findings.

## What is in the repo already

| Piece | Where | State |
|---|---|---|
| Wash shader | `Choreganize/ChoreWash.metal` | Shipping iteration 06. Signature: `choreWash(position, color, size, time, duration, seed, colorA, colorB, glow, dark, look, motion, strength)` |
| Wash plumbing | `Choreganize/CompletionWash.swift` | `CompletionWash` (constants, `shader()`, DEBUG hooks), `WashTrigger` (pure rule), `CompletionWashLayer` (background layer + Reduce Motion fade), `WashHaptics` |
| Day page hook | `Choreganize/WorkViews.swift` (`DayPage`, `ChoreRowView.onComplete`) | Trigger wired for the page's own actions; draws behind the page's List. **Not yet:** the Duo/iPad spread-wide layer (see BEHAVIOR §2.4) |
| Photo check-off hook | `Choreganize/PhotoCheckView.swift` (`willCommit`) | Done |
| Shader prewarm | `Choreganize/CalendarViews.swift` (`GlowPrewarm`) | Done |
| Tests | `ChoreganizeTests/CompletionWashTests.swift` | `WashTrigger` rules, 7 tests |
| Toggles | `Choreganize/PromiseToggleStyle.swift`, applied in `ChoreRowView` | Prototype behind DEBUG `-toggleLook promise`; colours final |
| Section rim | none | **Not written.** Demo only (`wash-lab.html`). Plan in BEHAVIOR §3.6 |
| Lab | `tools/wash-lab/` | Mac GPU renderer of the shipping shader (`run.sh`), the playground builder (`playground.py`), every shader iteration (`iterations/`) |

## Files in this folder

| File | What |
|---|---|
| `BEHAVIOR.md` | Behaviour and trigger specification, edge cases, open investigations |
| `tokens.json` | Colours, durations, opacities, contrast figures |
| `wash-lab.html` | The playground, self-contained. Open it in any WebGL2 browser: every shader iteration, the mock Work page (tap the last open toggle to fire the wash), the rim candidates, the toggle looks, appearance, device, scrubber. The published copy is at https://claude.ai/artifact/VQWjKbhrxqs54aBGQmMX9i |
| `reference/wash-06-roll-calm-8s-light-dark.mp4` | The chosen wash at real speed, light and dark side by side, rendered from the shipping Metal file |
| `reference/rim-B-lavender-night-honey-day.png` | The rim mid-retrace, settling and at rest (dark), and at rest (light) |
| `reference/rim-B-rest-dark-zoom.png` | The resting rim at 100 % in dark, close up |
| `reference/toggles-promise-light-dark.png` | The toggles in the mock, 4 of 5 done |
| `reference/app-toggles-promise-*.png` | The toggles in the real app (Simulator, DEBUG flag) |

## Reproducing the renders

```bash
tools/wash-lab/run.sh /tmp/wash --fps 60            # frames of the shipping shader (light)
tools/wash-lab/run.sh /tmp/wash --dark --times 2,4,6 # single frames, dark
python3 tools/wash-lab/playground.py /tmp/wash-lab.html   # rebuild the playground from iterations/
```

Launch arguments for the app (DEBUG builds): `-toggleLook promise`, `-washLook N`, `-washMotion 0|1`; environment `CHOREGANIZE_WASH_AT=<s>` freezes a wash at that time on today's page, `CHOREGANIZE_WASH_DEMO=<s>` starts one that long after the page appears.
