import React from "react";
import { interpolate, useCurrentFrame } from "remotion";

type Props = {
  char: string;
  startFrame: number;
  bloomFrames?: number;
  liftFrames?: number;
  fadeOutStart?: number;
  fadeOutFrames?: number;
};

/**
 * Plume's signature 90 ms letter bloom: opacity 0.4 → 1 over 3 frames at 30 fps,
 * with a small downward settle so the letter feels like it lands.
 */
export const BloomLetter: React.FC<Props> = ({
  char,
  startFrame,
  bloomFrames = 3,
  liftFrames = 9,
  fadeOutStart,
  fadeOutFrames = 12,
}) => {
  const frame = useCurrentFrame();
  const local = frame - startFrame;

  const opacityIn = interpolate(local, [0, bloomFrames], [0.4, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

  const lift = interpolate(local, [0, liftFrames], [-6, 0], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

  let opacity = local < 0 ? 0 : opacityIn;

  if (fadeOutStart !== undefined) {
    const out = interpolate(
      frame,
      [fadeOutStart, fadeOutStart + fadeOutFrames],
      [1, 0],
      { extrapolateLeft: "clamp", extrapolateRight: "clamp" },
    );
    opacity = Math.min(opacity, out);
  }

  return (
    <span
      style={{
        display: "inline-block",
        opacity,
        transform: `translateY(${lift}px)`,
        whiteSpace: "pre",
      }}
    >
      {char}
    </span>
  );
};
