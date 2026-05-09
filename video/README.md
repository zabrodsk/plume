# Plume — announcement video

A 25-second 1920×1080 landscape announcement built with [Remotion](https://www.remotion.dev/).
Five scenes: hero bloom, SSH, light/dark theme, find, download CTA.

## Run

```bash
npm install
npm run dev      # Remotion Studio at http://localhost:3000
npm run render   # writes out/plume.mp4
npm run still    # writes out/poster.png (frame 30)
```

`npm run render:hq` enables higher-quality H.264 (CRF 14, ~3× the file size).

## Scenes

| Frames    | Time    | Scene           | What it does                                      |
|-----------|---------|-----------------|---------------------------------------------------|
| 0–180     | 0–6s    | HeroBloom       | "plume" types itself letter-by-letter, tagline    |
| 180–360   | 6–12s   | SSHBeat         | Mock remote file browser revealing markdown files |
| 360–540   | 12–18s  | LightThemeBeat  | Sweep wipe from dark to light, paragraph reflows  |
| 540–660   | 18–22s  | FindBeat        | ⌘F find bar pulses across matched terms           |
| 660–750   | 22–25s  | CTABeat         | Big italic "Plume", URL, download arrow           |

## Brand

- Background `#1a1815`, ink `#d4cfc0`, accent `#79b8ff`
- Light theme: paper `#f5f1e8`, ink `#3d3833`
- Hero font: Fraunces (italic) — loaded via `@remotion/google-fonts`
- Body / mono: system stack — keeps the bundle small

The 90 ms letter bloom is the same easing the app uses (`opacity 0.4 → 1`
over 3 frames at 30 fps), so the video animates the way Plume types.
