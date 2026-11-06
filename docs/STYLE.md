# Choreganize style guide

Colour and design-language choices the code already makes. Each value cites its source file. Where the code is silent, this guide says so. Paths are relative to the repo root.

Platforms: iPhone, iPad, iPhone Duo (iOS app, `Choreganize/`) and Mac (`ChoreganizeMac/`, shared sources from `Choreganize/`).

## 1. Palette

### 1.1 App icon gradient

The brand pair. Source: `CGZ2.icon/icon.json` (the Icon Composer file).

| Stop | Display P3 | Position |
|---|---|---|
| Amber | (1.00000, 0.75608, 0.00000) | top, y = 0 |
| Periwinkle | (0.70686, 0.71639, 1.00000) | y = 0.7, x = 0.5 |

- The gradient is linear and vertical (start x 0.5, y 0; stop x 0.5, y 0.7).
- The glyph layers (frame, two checks, three lines) sit at 0.8 opacity on that fill. Translucency is on at 0.5. The shadow is neutral at 0.5.
- `Choreganize/Assets.xcassets/AppIcon.appiconset` holds only pre-rendered PNGs and a `Contents.json`. The colours are not stored there.

### 1.2 sRGB tokens (completion wash and App Store creative)

The same pair, plus honey, in sRGB. Sources: `Choreganize/CompletionWash.swift:13-15`, `build/ppo/2026-11-04/creative/creative.css:12-20`.

| Token | Hex | Role in code |
|---|---|---|
| amber | #FFC233 | Icon gradient top; wash warm colour |
| honey | #FFD978 | Perfect-day glow; wash bloom and highlight |
| lavender | #AEB4FF | Icon gradient bottom; wash cool colour |
| ink | #26264A | Creative text colour (`creative.css` only) |
| paper | #F0F3F5 | Icon glyph white (`creative.css` only) |
| done | #34C759 | iOS system green, "the Work view's done toggle" (`creative.css`) |

The app code defines amber, lavender and honey only in `CompletionWash.swift`. Ink and paper exist only in the creative CSS.

### 1.3 Gradient rule: blend in a perceptual space

An sRGB blend of amber and periwinkle goes muddy grey at the midpoint. Every place that blends the pair avoids that:

| Where | How | Source |
|---|---|---|
| Day rail | `Gradient(...).colorSpace(.perceptual)` | `DayRail.swift:225` |
| Wash reduced-motion fade | `.colorSpace(.perceptual)` | `CompletionWash.swift:146` |
| Wash shader | mixes in OKLab (Ottosson) | `ChoreWash.metal` header and `namespace wash` |
| App Store slides | `linear-gradient(180deg in oklab, amber 0%, lavender 100%)` | `build/ppo/2026-11-04/creative/slides.py:55` |

Rule: blend amber and lavender or periwinkle in OKLab or `.perceptual`, never in plain sRGB.

### 1.4 Day rail colours (iPhone Duo)

The rail uses the icon pair, stepped per appearance. Source: `DayRail.swift:205-232` (`DayRailStyle.amber`, `DayRailStyle.periwinkle`).

Why stepped: the glass pill's rim must keep at least 3:1 non-text contrast on the grouped background. The steps are made in OKLab lightness. The doc comment records the validation: light on #F2F2F7 and white, dark on #000000 and #1C1C1E.

| Colour | Light | Dark |
|---|---|---|
| `amber` | #BB7400 | #C48500 |
| `periwinkle` | #7A7CC6 | #888ACF |

- The skeleton (line and ticks) uses the gradient at opacity 0.40 light, 0.45 dark, 0.75 with Increase Contrast (`DayRail.swift:46`).
- The pill rim is 1.5 pt, or 2.5 pt with Increase Contrast (`DayRail.swift:49`).
- The rim shows a stretch of the gradient twice the pill's span, so its two stages read: gold at the top of the rail, periwinkle at the bottom (`DayRailMath.rimSlice`).

### 1.5 Perfect-day green

Used by the calendar's perfect-day bar. Source: `CalendarViews.swift:615-618` (`NeonCompletionBar.base`).

| Appearance | RGB |
|---|---|
| Light | (0.05, 0.62, 0.30) |
| Dark | (0.18, 0.95, 0.45) |

Why: light mode is deepened because halos read poorly on white. In light mode the bar leans on its core and a glyph rather than on the halo.

### 1.6 System colours the app relies on

| Use | Colour | Source |
|---|---|---|
| Accent | `AccentColor` asset: lavender #7370CF light / #8285DF dark (Increase Contrast #4B48AE light; dark unchanged), app and widget. On the Mac it applies under the Multicolor system accent only. Replaced system blue on 2026-11-05 (section 1.7) | `Assets.xcassets/AccentColor.colorset/Contents.json` |
| Page backdrop | `systemBackground` / Mac `windowBackgroundColor` | `PlatformCompat.swift` `compatBackground` |
| Grouped backdrop | `systemGroupedBackground` / Mac `windowBackgroundColor` | `compatGroupedBackground` |
| Card (row) fill | `secondarySystemGroupedBackground` / Mac `controlBackgroundColor` | `compatCardBackground` |
| Done toggle | The system switch, `.tint(.accentColor)`: lavender when on, the system grey when off | `WorkViews.swift` (`ChoreRowView`) |
| Done / success | `Color.green` | `CalendarViews.swift:540`, `AppBannerView.swift:61`, `InsightsViews.swift:303` |
| Day meter remainder | blue (future), red (recent, within window), gray (older) | `CalendarViews.swift:521-526` |
| Chip fill | `tertiarySystemFill` | `WorkViews.swift:70`, `FormComponents.swift:211` |

- Accent tints: Quick Add ghost fill 0.07 and dashed stroke 0.55 (`QuickAdd.swift:254-257`), chore highlight 0.18 (`WorkViews.swift:107`), One-offs row fill 0.10 (`OneOffViews.swift:197`).
- The accent hue comes from the asset catalog. The only explicit `.tint(...)` is on the Work rows' switches, which otherwise stay system green. Remaining hard-coded system colours include the calendar's future-day dashes (`Color.blue`) and the "done = green" spots below.
- Green encodes "done" by fill as well as hue, so it survives grayscale and red-green colour blindness (`CalendarViews.swift:513-516`).
- Insights heatmap uses green at 0.30, 0.50, 0.75 and 1.0 opacity (`InsightsViews.swift:442-445`).

### 1.7 State and celebration tokens (decided 2026-11-05)

Values from `docs/completion-wash/tokens.json`; the accent pair is the `AccentColor` asset, the rim is `SectionRim.swift`.

| Token | Light | Dark | Role |
|---|---|---|---|
| accent / toggle on | #7370CF | #8285DF | A lavender a shade softer than the icon's; the app accent and the switch's on track. 4.2:1 / 3.3:1 against the white thumb; as text 4.2:1 on white, 5.2:1 on the dark card |
| toggle off | system | system | The system switch's own grey (a warm-grey custom track was tried and dropped to keep Apple's switch) |
| section rim | #FFD978 (honey) | #AEB4FF (lavender) | Hairline + outward halo on a finished or part-finished section card |
| wash | amber → lavender, honey glow | same, over a dusky lavender haze | Background nebula for a finished day |

## 2. Surfaces and layout

| Item | Rule | Source |
|---|---|---|
| Lists | Inset-grouped on iOS, `.inset` on Mac (no grouped style in AppKit) | `PlatformCompat.swift` `compatInsetGroupedList`; used in `WorkViews.swift:782` |
| Day page margin | 32 pt horizontal. `contentMargins` replaces the ~20 pt default. Kept so cards do not shift after the paging chevrons were removed. Marked "revisit with the day-paging review" | `WorkViews.swift:810-814` |
| Bottom clearance | 72 pt (`@ScaledMetric`) where the pill floats; 24 pt (`@ScaledMetric`) with a tab bar | `WorkViews.swift:523-524, 643` |
| Edit / Insights clearance | 100 pt with the pill, 24 pt without | `EditViews.swift:61`, `InsightsViews.swift:159` |
| Page background | Grouped background painted to the physical edges, so the home-indicator band and rounded corners are never black | `WorkViews.swift:393` |
| Mode switcher | Liquid Glass capsule, interactive; iOS 18 fallback is a `.bar` capsule with a 0.12 white hairline and a soft shadow | `ContentView.swift:503-514` |
| Switcher float | Floats over content, so mid-scroll rows slide under the glass and the last row rests above it (#65) | `WorkViews.swift:815-818` |
| Sync chip | Shares the switcher's glass so the two match | `ContentView.swift:462-468` |
| Day rail pill | 26 pt wide Liquid Glass capsule (material fallback before iOS 26) | `DayRail.swift:106, 245-253` |
| Mac day button | Glass rounded rect, 14 pt radius; `.identity` (no glass) in store captures | `MacRootView.swift:371-372` |

### Quick Add ghost

A dashed placeholder row shorter than a chore row. Source: `QuickAdd.swift:213-262`.

| Item | iOS | Mac |
|---|---|---|
| Height | 58 pt | 42 pt |
| Corner radius | 22 pt (iOS/macOS 26+), 12 pt before | same |
| Horizontal padding | 16 pt | 16 pt |
| Fill | accent at 0.07 | same |
| Stroke | accent at 0.55, 1.5 pt, dash 6/4 | same |

- Why shorter: about 74 pt on iOS 26 and 45 pt on Mac for a chore row. The ghost "reads as the next row without passing for one".
- The ghost sits in a fixed-height section footer slot, so nothing moves under the finger.
- On iOS the list adds no section spacing of its own on days that offer Quick Add (`WorkViews.swift:805-809`).
- Past and locked days never offer the ghost (`QuickAdd.swift:55`).
- Mac reveals the ghost on hover (`QuickAdd.swift:206-209`).

### iPhone pill versus tab bar

- One `TabView(.sidebarAdaptable)` in every configuration, so mode views are never rebuilt when sizes change (`ContentView.swift:172-198`).
- `usesSystemTabs` is true when horizontal and vertical size classes are both regular (iPad, Duo inner display), or when the system lays bars out vertically (Duo outer display, Duo inner in landscape) (`ContentView.swift:75-77`).
- Otherwise the floating pill is used, with the tab bar hidden.
- The decision uses what the system reports, never device model.
- The shell sets `clearsModeSwitcher` false when the system tab bar is in use (`ContentView.swift:193`, `AppMode.swift:28-39`).
- Pill style: Liquid Glass morph is the settled default; `.menu` is the alternative. A Developer toggle exists (`ContentView.swift:7-9, 472-486`).

### Mac

- Window: default 980 x 640, minimum 760 x 480 (`ChoreganizeMacApp.swift:38, 75`).
- Sheets set minimum sizes, for example 440 x 560 (`MacRootView.swift:80-109`).
- Backdrop is the window background for both grouped and plain; card fill is `controlBackgroundColor` (`PlatformCompat.swift`).
- The wash page base is the card colour on Mac and the grouped colour on iOS (`WorkViews.swift:889-896`).
- The wash runs at strength 0.55 on Mac (1.0 on iOS). Mac rows sit on the background with no cards, so this keeps text legible (`CompletionWash.swift:18-24`).
- Checkboxes use `.toggleStyle(.checkbox)` (`NotificationSettingsView.swift:62`, Mac sheets).
- There is no Hub on Mac. Plus copy points to Settings instead (`PlatformCompat.swift` `PlatformText`).

## 3. Typography

There is no custom typography. No font files are bundled, and the code never uses `Font.custom`.

- System text styles throughout. About 172 `.font`/weight call sites. Most frequent: `.caption`, `.subheadline`, `.headline`, `.title2`, `.footnote`, `.caption2`, `.callout`.
- Dynamic Type is the default. Fixed `.system(size:)` appears about 21 times, mostly for SF Symbols and decorative glyphs (for example 56 pt light icons in `RoomSnapView.swift:65`, 80 pt in `WorkViews.swift:868`).
- `@ScaledMetric` is used twice, both for the switcher and tab-bar clearance (`WorkViews.swift:523-524`). Why: larger text must still clear the floating pill.
- Rounded design (`design: .rounded`) appears only on the Insights monthly share card (`InsightsViews.swift:522-603`). That card is a fixed 1080 x 1350 image with explicit colours, because `ImageRenderer` content gets no environment or theme (`InsightsViews.swift:505-507`).
- Chore row: name at `.fontWeight(.medium)`, detail in `.caption`, secondary. The Quick Add ghost copies this explicitly, because a list footer sets a smaller font and resolves `.primary` to its secondary style (`QuickAdd.swift:229-239`).
- The App Store creative uses SF Rounded (`/System/Library/Fonts/SFNSRounded.ttf`) with weights 600 to 800 (`creative.css`). This is marketing artwork only. The app itself does not use rounded type outside the share card.
- The code defines no type scale, tracking or line-height rules.

## 4. Motion and feedback

### 4.1 Completion wash

A one-shot celebration behind a day's cards when its last open chore is completed. Sources: `CompletionWash.swift`, `ChoreWash.metal`, `WorkViews.swift:600-611, 796-800`.

| Item | Value |
|---|---|
| Duration | 8.0 s (`CompletionWash.duration`) |
| Motion | Roll-through: enters at the lower trailing corner, slows through the middle, exits at the far corner, never reverses |
| Look | "Calm", smoother haze (`look` 1) |
| Material | Lit, matte gas. No hard edges, foam lines or highlights |
| Colour | Amber, lavender, honey, mixed in OKLab |
| Trigger | A false-to-true edge of "day complete", not locked, with the user's own completion within 3 s (`WashTrigger.window`); again after an uncheck, at most once per 30 s per page |
| Spread | On a two-page spread the container draws it, so it crosses both pages and the fold (`completionWashHost`) |
| Paging | Held still while it plays (the pager and the Duo's day rail); a chore added to the day re-arms the 30 s limit |
| Backdrop | Drawn behind the list. A UIKit-backed List cannot take a `colorEffect`, and `scrollContentBackground` is hidden while it plays |
| Dither | `dithersColor` on, because banding shows in soft gradients on flat backgrounds, most of all in dark mode |

- Why the local-completion rule: page load, a household sync and a widget completion all flip "complete" without a local action on the page.
- Reduce Motion or Low Power Mode: no shader. A top-to-bottom amber-to-lavender gradient fades in to 0.7 opacity at 0.4 s and is gone by 1.4 s (`CompletionWash.swift:116, 155-160`).
- The layer is hit-test off and hidden from accessibility.
- DEBUG-only overrides exist (`-washLook`, `-washMotion`, `CHOREGANIZE_WASH_AT`, `CHOREGANIZE_WASH_DEMO`). Release always ships look 1 and motion 1.

### 4.2 Perfect-day glow (calendar)

Source: `CalendarViews.swift:505-690`, `PerfectDayGlow.metal`, `GlowMotion.swift`.

- A green bar with a slow travelling specular highlight for a day with every chore done.
- On appear it ignites: a spring (response 0.45, damping 0.55) grows it from 0.6 to full height and brightens the halo.
- A run of consecutive perfect days shares one sweep that relays bar to bar via the shared `GlowClock` epoch.
- `TiltProvider` reads device roll (clamped to -1...1) at 30 Hz. The sweep slides with tilt and settles when the phone is set down. It is plain (not observable) on purpose: 30 updates a second would re-render the whole grid.
- It is a no-op where device motion is unavailable (the Simulator). The sweep then falls back to time only.
- `GlowPrewarm.run()` compiles the glow and wash shaders off-main at launch to avoid a first-use hitch (`ChoreganizeApp.swift:30`).
- The bar renders static (glossy, no `TimelineView`) under Reduce Motion, Low Power, or when a sheet covers the calendar (`glowAnimationActive`). Why: shaders behind a sheet starved the sheet's scroll frame rate.

### 4.3 Haptics

| Name | Behaviour | Source |
|---|---|---|
| `SuccessHaptic` | Success notification, kept warm with `prepare()`. No-op on Mac | `PlatformCompat.swift`; used by add flows, Room Snap, Photo Check, Describe |
| `WashHaptics` | Core Haptics: soft swell, a 0.6 tick at 0.05 s, a fading tail. "Gassy, not splashy". Falls back to `SuccessHaptic` | `CompletionWash.swift:164-` |
| Day rail | `.selection` each time the held pill moves to another spread | `DayRail.swift:113` |
| Add flow | `.increase` when the draft count changes | `AddFlowView.swift:302` |
| One-off check-off | `.success` when the poof starts | `OneOffViews.swift:81` |

The Mac has no Taptic Engine, so haptics are no-ops there.

### 4.4 Highlights and transitions

- `highlightedChore` (a deep-linked chore) fills the row with accent at 0.18, clears after 2.2 s, and eases in 0.3 s (`WorkViews.swift:107-110, 543-561`).
- Finish Day shows a confirmation for 1.5 s (`WorkViews.swift:628-630`).
- Day rail selection uses `.snappy`, or a bare scroll under Reduce Motion (`WorkViews.swift:192-200`).
- One-off completion "poof" (scale 1.08, blur 5) is skipped under Reduce Motion (`OneOffViews.swift:69-73`).
- The switcher morph is a spring (response 0.5, damping 0.86) (`ContentView.swift`, `MorphModeSwitcher`).

### 4.5 Conventions

| Setting | Convention | Where |
|---|---|---|
| Reduce Motion | Replace travel with a fade or a still frame | wash, glow, One-offs, Quick Add transition, day rail |
| Low Power Mode | Same fallback as Reduce Motion; also stops `TiltProvider` | wash, glow, `GlowMotion.swift:31` |
| Increase Contrast | Raise rail opacity and rim width | `DayRail.swift:46, 49` |
| Differentiate Without Color | Add a glyph | perfect-day bar only (see section 5) |

## 5. Accessibility conventions

- Decorative layers are hidden: the wash layer and the glow bar use `.accessibilityHidden(true)`. The calendar cell's own label states the count (`CalendarViews.swift:509, 642`).
- Calendar cells combine children and use a summary label (`CalendarViews.swift:507-510`).
- Differentiate Without Color: the perfect-day bar adds a `checkmark.seal.fill` glyph so "perfect" is not carried by colour and glow alone (`CalendarViews.swift:609, 627-634`). This is the only DWC use in the code. The day meter instead encodes done by fill amount.
- Locked days (past, or finished with Finish Day) show a small `lock.fill` at the trailing end of the date line, read as "…, Locked" (`DayDateHeader`). With lavender switches, a locked day's dimmed switches stand out less than green ones did.
- Day rail: one adjustable element. Label "Days shown", value is the two-day spread read out ("Sunday, November 1 and Monday, November 2"), increment and decrement page spreads (`DayRail.swift:55-65`).
- VoiceOver announcements via `AccessibilityNotification.Announcement`:
  - "Day finished" when Finish Day locks the day, "Day complete" when the wash fires, "<section> complete" on a section rim's flourish (`WorkViews.swift`).
  - "The list is unavailable until you save or cancel these chores." Posted once, only when the list is visible (`ContentView.swift:769-773`).
- Identifiers (about 45 in the app) are for UI tests and follow `area.thing` or `thingButton`:

| Pattern | Examples |
|---|---|
| Dotted, feature-first | `roomsnap.add`, `photocheck.markDone`, `describe.read`, `oneOff.add`, `addflow.snapRoom`, `roomvision.takePhoto` |
| Indexed or named | `roomsnap.suggestion.\(index)`, `photocheck.item.\(name)`, `describe.chore.\(index)`, `oneOff.check.\(title)` |
| camelCase buttons | `markAllDoneButton`, `finishDayButton`, `unlockDayButton`, `logCompletionButton`, `photoCheckButton` |
| Calendar | `calendar-day-\(dayNumber)`, `logRow-\(name)` |
| Switcher | `modeSwitcherCollapsed`; menu items use the mode's `rawValue` (UI tests tap by name) |
| Quick Add | `quickAdd.<id>`, or `quickAdd.day` for an empty id (`QuickAdd.swift:183`) |

- The code has no written naming rule. The patterns above are observed, not documented. Hyphenated and dotted forms both occur.
- Copy that points to the Hub puts the icon beside the name, because the button shows only the icon (`PlatformCompat.swift` `PlatformText.hubSymbol`).
- The code states no minimum touch-target size or contrast target beyond the 3:1 rim rule in section 1.4.

## 6. Open / in progress

Provisional. These are being decided and are not yet code rules.

| Topic | State |
|---|---|
| Completion wash look | Iteration 05, "nebula volume", chosen as the basis on 2026-11-05; the shipping shader is iteration 06 (05 plus a dark-mode treatment). Look 1 "calm" and motion 1 "roll-through" are the chosen variants (`CompletionWash.swift`). Every iteration is kept as a snapshot in `tools/wash-lab/iterations/` |
| Wash in dark mode | First treatment in place, not final. Over a light page thin gas tints its way in; over black it switched on. So at night a dusky lavender haze arrives with the front, gas lightness is compressed into the daytime contrast band, and the front and tail are wider (`ChoreWash.metal`, the `dark` branches) |
| Toggle colour language | **Shipped on the branch 2026-11-05**: the system switch tinted with the lavender accent (section 1.7). The custom warm-grey "promise" style was dropped |
| Section rim | **Built 2026-11-05** (iOS): perimeter fill, honey by day and lavender by night, a signed-distance `colorEffect` behind each section card (`SectionRim.swift`, `SectionRimLayer.swift`). None on Mac |
| Day page margin | 32 pt is flagged in a code comment for revisit with the day-paging review (`WorkViews.swift:811-812`) |

The toggle language is adopted (section 1.7). The `done` green (#34C759) still marks done outside the Work rows (calendar, Insights, widget, Mac); bringing those into the day language is an open suggestion.

## 7. Celebration and state language (findings, 2026-11-05)

Generalized from the completion-wash work (`docs/completion-wash/`). These are design rules now; the implementation state is in section 6.

### 7.1 The day gradient carries meaning
- Amber is morning: a promise for the day not yet kept. Lavender is evening: the promise kept, rest. Honey is the light between them. Use the pair to say *before* and *after*, not as decoration.
- So: a chore toggle is the system switch, soft lavender when on (its off grey is the system's own). A section's rim is honey by day and lavender by night. The wash runs amber at its leading edge into lavender in its body.

### 7.2 Two scales of celebration
- Finishing a **section** earns a glow on that section's card. Finishing the **whole day** earns the background wash. Controls (action rows) never glow: they are how you act, not what you achieved.
- Celebrations are **progress-driven, then crowned**: the rim fills with the section's fraction and eases between levels; the last completion retraces it in full. A single moment of flourish reads as earned because the build-up was visible.

### 7.3 Light behaves like light
- Glows emit from an edge outward and never into the surface they light. A band of light with its own far edge reads as a second shape; a falloff from the edge reads as a lit border.
- Keep glows gentle: a hairline on the edge, a halo that tops out well below full opacity. Honey on black is the loudest pairing the palette has; at night, light with lavender.
- Lit gas is shaded warm-light / cool-shadow: shadows deepen toward saturated periwinkle, never toward grey. Dim amber over black turns khaki; amber only belongs where it is bright.

### 7.4 Dark mode is not inverted light mode
- Over a light page a soft effect tints its way in, because thin colour over white is a pale tint. Over black the same effect switches on, because thin colour over black is invisible until it is dense. Give night a dim ambient floor (a dusky haze that arrives with the front), compress lightness into the daytime contrast band, and widen soft edges.

### 7.5 Motion
- One pass, never a reversal, for a celebration that should feel like weather: enter from the lower trailing corner, slow through the middle, leave at the upper leading corner. Linger where the eye is.
- Nothing steps. Progress changes ease (about a quarter of a second). Reduce Motion replaces travel with a fade, never with a jump.
- On a two-page display (iPhone Duo, iPad spread) a whole-day celebration spans the whole display; it never stops at the fold.

### 7.6 Colour discipline
- Mix amber and lavender in OKLab or `.perceptual` only (section 1.3). Lift chroma slightly through the middle of a long blend so the midpoint stays a colour.
- Off states must not read as active: tint the system grey a hint, no more. On states should clear 3:1 against the thumb; off states follow the system's own off grey, which does not.
- Don't colour everything. State should also read by shape, position, fill or lightness, so colour-blind users keep the meaning.

### 7.7 Tooling
- Every visual experiment gets a snapshot (`tools/wash-lab/iterations/`), a GPU render (`tools/wash-lab/run.sh`) and a page in the playground (`playground.py`) so looks are compared side by side before anything ships.
