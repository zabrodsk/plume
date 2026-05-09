import React from "react";
import {
  AbsoluteFill,
  interpolate,
  spring,
  useCurrentFrame,
  useVideoConfig,
} from "remotion";
import { COLORS, FONTS } from "../colors";

export const CTABeat: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  const wordIn = spring({
    frame,
    fps,
    config: { damping: 200, mass: 0.7 },
    durationInFrames: 28,
  });

  const subIn = interpolate(frame, [16, 36], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
  const subLift = interpolate(frame, [16, 36], [12, 0], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

  const urlIn = interpolate(frame, [30, 54], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

  const arrowFloat = interpolate(
    Math.sin((frame - 30) / 6),
    [-1, 1],
    [-3, 3],
  );

  return (
    <AbsoluteFill
      style={{
        backgroundColor: COLORS.bg,
        alignItems: "center",
        justifyContent: "center",
      }}
    >
      <div
        style={{
          position: "absolute",
          inset: 0,
          background:
            "radial-gradient(ellipse 50% 40% at 50% 50%, rgba(121,184,255,0.10), transparent 70%)",
          opacity: wordIn,
        }}
      />

      <div
        style={{
          fontFamily: FONTS.serif,
          fontStyle: "italic",
          fontWeight: 500,
          fontSize: 240,
          color: COLORS.ink,
          letterSpacing: -6,
          lineHeight: 1,
          opacity: wordIn,
          transform: `translateY(${(1 - wordIn) * 18}px)`,
        }}
      >
        Plume
      </div>

      <div
        style={{
          marginTop: 28,
          fontFamily: FONTS.sans,
          fontSize: 28,
          color: COLORS.inkDim,
          letterSpacing: 8,
          textTransform: "uppercase",
          opacity: subIn,
          transform: `translateY(${subLift}px)`,
        }}
      >
        free · macos 12+ · mit
      </div>

      <div
        style={{
          marginTop: 56,
          fontFamily: FONTS.mono,
          fontSize: 30,
          color: COLORS.accent,
          opacity: urlIn,
          display: "flex",
          alignItems: "center",
          gap: 12,
        }}
      >
        <span
          style={{
            display: "inline-block",
            transform: `translateY(${arrowFloat}px)`,
          }}
        >
          ↓
        </span>
        github.com/zabrodsk/plume
      </div>
    </AbsoluteFill>
  );
};
