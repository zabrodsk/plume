import React from "react";
import { AbsoluteFill, interpolate, useCurrentFrame } from "remotion";
import { COLORS, FONTS } from "../colors";
import { BloomLetter } from "../components/BloomLetter";

const WORD = "plume";
const STAGGER = 7;
const TAGLINE_FROM = 60;

export const HeroBloom: React.FC = () => {
  const frame = useCurrentFrame();

  const taglineOpacity = interpolate(
    frame,
    [TAGLINE_FROM, TAGLINE_FROM + 18],
    [0, 1],
    { extrapolateLeft: "clamp", extrapolateRight: "clamp" },
  );
  const taglineLift = interpolate(
    frame,
    [TAGLINE_FROM, TAGLINE_FROM + 18],
    [12, 0],
    { extrapolateLeft: "clamp", extrapolateRight: "clamp" },
  );

  const exitOpacity = interpolate(frame, [160, 180], [1, 0], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

  return (
    <AbsoluteFill
      style={{
        backgroundColor: COLORS.bg,
        alignItems: "center",
        justifyContent: "center",
        opacity: exitOpacity,
      }}
    >
      <Glow />

      <div
        style={{
          fontFamily: FONTS.serif,
          fontStyle: "italic",
          fontWeight: 500,
          fontSize: 320,
          color: COLORS.ink,
          letterSpacing: -8,
          lineHeight: 1,
          textShadow: `0 0 60px rgba(121, 184, 255, 0.08)`,
        }}
      >
        {WORD.split("").map((c, i) => (
          <BloomLetter
            key={i}
            char={c}
            startFrame={i * STAGGER}
            bloomFrames={3}
            liftFrames={11}
          />
        ))}
      </div>

      <div
        style={{
          marginTop: 32,
          fontFamily: FONTS.sans,
          fontSize: 32,
          color: COLORS.inkDim,
          letterSpacing: 12,
          textTransform: "uppercase",
          opacity: taglineOpacity,
          transform: `translateY(${taglineLift}px)`,
        }}
      >
        less app · more page
      </div>
    </AbsoluteFill>
  );
};

const Glow: React.FC = () => {
  const frame = useCurrentFrame();
  const o = interpolate(frame, [0, 60], [0, 0.6], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
  return (
    <div
      style={{
        position: "absolute",
        inset: 0,
        background:
          "radial-gradient(ellipse 50% 35% at 50% 48%, rgba(121,184,255,0.10), transparent 70%)",
        opacity: o,
      }}
    />
  );
};
