import React from "react";
import {
  AbsoluteFill,
  interpolate,
  spring,
  useCurrentFrame,
  useVideoConfig,
} from "remotion";
import { COLORS, FONTS } from "../colors";

const PARA =
  "Every keystroke blooms onto the page. The render layer stays a single text node — typing stays free even at one hundred kilobytes. The DOM stays clean. The page stays calm. Typing feels like typing.";

const QUERY = "typing";

export const FindBeat: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  const barOpen = spring({
    frame: frame - 5,
    fps,
    config: { damping: 200, mass: 0.6 },
    durationInFrames: 20,
  });

  // Type the query character by character into the bar.
  const typedCount = Math.min(
    QUERY.length,
    Math.max(0, Math.floor((frame - 18) / 3)),
  );
  const typed = QUERY.slice(0, typedCount);

  // After the query is fully typed, pulse the matches.
  const pulse = interpolate(
    Math.sin((frame - 40) / 6),
    [-1, 1],
    [0.55, 1],
  );

  const matchHighlight = frame > 36 ? pulse : 0;

  const exit = interpolate(frame, [105, 120], [1, 0], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

  return (
    <AbsoluteFill
      style={{
        backgroundColor: COLORS.bg,
        alignItems: "center",
        justifyContent: "center",
        opacity: exit,
      }}
    >
      <div style={{ position: "relative", width: 1280 }}>
        <FindBar query={typed} progress={barOpen} matchCount={3} />

        <p
          style={{
            fontFamily: FONTS.serif,
            fontWeight: 400,
            fontSize: 40,
            lineHeight: 1.55,
            color: COLORS.ink,
            margin: 0,
            marginTop: 110,
          }}
        >
          {renderWithMatches(PARA, QUERY, typedCount > 0, matchHighlight)}
        </p>
      </div>
    </AbsoluteFill>
  );
};

const FindBar: React.FC<{
  query: string;
  progress: number;
  matchCount: number;
}> = ({ query, progress, matchCount }) => (
  <div
    style={{
      position: "absolute",
      top: 0,
      right: 0,
      transformOrigin: "top right",
      transform: `scaleX(${progress}) translateY(${(1 - progress) * -8}px)`,
      opacity: progress,
      display: "flex",
      alignItems: "center",
      gap: 16,
      padding: "12px 20px",
      backgroundColor: COLORS.bgSoft,
      borderRadius: 10,
      boxShadow:
        "0 12px 40px rgba(0,0,0,0.45), 0 0 0 1px rgba(212,207,192,0.06)",
      fontFamily: FONTS.mono,
      fontSize: 24,
      color: COLORS.ink,
      minWidth: 360,
    }}
  >
    <span style={{ color: COLORS.inkDim }}>⌘F</span>
    <span style={{ flex: 1 }}>
      {query}
      <Caret />
    </span>
    {query.length > 0 && (
      <span style={{ color: COLORS.accent, fontSize: 20 }}>
        1 / {matchCount}
      </span>
    )}
  </div>
);

const Caret: React.FC = () => {
  const frame = useCurrentFrame();
  const visible = Math.floor(frame / 8) % 2 === 0;
  return (
    <span
      style={{
        display: "inline-block",
        width: 2,
        height: 24,
        backgroundColor: COLORS.ink,
        opacity: visible ? 1 : 0,
        transform: "translateY(4px)",
        marginLeft: 2,
      }}
    />
  );
};

function renderWithMatches(
  text: string,
  query: string,
  active: boolean,
  highlight: number,
): React.ReactNode {
  if (!active || !query) return text;
  const parts: React.ReactNode[] = [];
  const regex = new RegExp(`(${query})`, "gi");
  const tokens = text.split(regex);
  tokens.forEach((tok, i) => {
    if (tok.toLowerCase() === query.toLowerCase()) {
      parts.push(
        <mark
          key={i}
          style={{
            backgroundColor: `rgba(232, 168, 124, ${0.15 + highlight * 0.35})`,
            color: COLORS.ink,
            padding: "0 6px",
            borderRadius: 4,
            boxShadow: `0 0 0 1px rgba(232,168,124, ${highlight * 0.5})`,
          }}
        >
          {tok}
        </mark>,
      );
    } else {
      parts.push(<span key={i}>{tok}</span>);
    }
  });
  return parts;
}
