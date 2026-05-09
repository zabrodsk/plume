import React from "react";
import { AbsoluteFill, interpolate, useCurrentFrame } from "remotion";
import { COLORS, FONTS } from "../colors";

const PARAGRAPH = `Writing should not feel like fighting your tools. What you focus on grows. So we let you focus.`;

export const LightThemeBeat: React.FC = () => {
  const frame = useCurrentFrame();

  // Sweep wipes left → right between frames 50 and 130.
  const wipe = interpolate(frame, [50, 130], [0, 100], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

  const captionOpacity = interpolate(frame, [10, 30], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

  const exit = interpolate(frame, [165, 180], [1, 0], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

  return (
    <AbsoluteFill style={{ opacity: exit }}>
      {/* Dark base layer */}
      <Page
        bg={COLORS.bg}
        ink={COLORS.ink}
        inkDim={COLORS.inkDim}
        accent={COLORS.accent}
      />

      {/* Light layer revealed via clip-path sweep */}
      <div
        style={{
          position: "absolute",
          inset: 0,
          clipPath: `polygon(0 0, ${wipe}% 0, ${wipe}% 100%, 0 100%)`,
        }}
      >
        <Page
          bg={COLORS.paper}
          ink={COLORS.paperInk}
          inkDim={COLORS.paperInkDim}
          accent="#3a6ea8"
        />
      </div>

      {/* Sweep edge: a thin warm line tracking the wipe */}
      <div
        style={{
          position: "absolute",
          top: 0,
          bottom: 0,
          left: `calc(${wipe}% - 1px)`,
          width: 2,
          background:
            "linear-gradient(180deg, transparent, rgba(232,168,124,0.6), transparent)",
          opacity: wipe > 0 && wipe < 100 ? 1 : 0,
        }}
      />

      <div
        style={{
          position: "absolute",
          bottom: 70,
          left: 0,
          right: 0,
          textAlign: "center",
          opacity: captionOpacity,
          fontFamily: FONTS.sans,
          fontSize: 28,
          color: wipe > 50 ? COLORS.paperInkDim : COLORS.inkDim,
          letterSpacing: 6,
          textTransform: "uppercase",
          mixBlendMode: "difference",
        }}
      >
        follows your system theme
      </div>
    </AbsoluteFill>
  );
};

const Page: React.FC<{
  bg: string;
  ink: string;
  inkDim: string;
  accent: string;
}> = ({ bg, ink, inkDim, accent }) => (
  <div
    style={{
      width: "100%",
      height: "100%",
      backgroundColor: bg,
      display: "flex",
      alignItems: "center",
      justifyContent: "center",
    }}
  >
    <div
      style={{
        width: 1200,
        fontFamily: FONTS.serif,
      }}
    >
      <h1
        style={{
          fontStyle: "italic",
          fontSize: 84,
          fontWeight: 500,
          color: ink,
          margin: 0,
          marginBottom: 24,
          letterSpacing: -2,
        }}
      >
        On typing
      </h1>
      <div
        style={{
          fontSize: 22,
          color: inkDim,
          fontFamily: FONTS.sans,
          marginBottom: 36,
          letterSpacing: 1,
        }}
      >
        <span style={{ color: accent }}>#</span> a draft
      </div>
      <p
        style={{
          fontSize: 38,
          lineHeight: 1.5,
          color: ink,
          margin: 0,
          fontFamily: FONTS.serif,
          fontWeight: 400,
        }}
      >
        {PARAGRAPH}
      </p>
    </div>
  </div>
);
