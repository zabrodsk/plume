import React from "react";
import {
  AbsoluteFill,
  interpolate,
  spring,
  useCurrentFrame,
  useVideoConfig,
} from "remotion";
import { COLORS, FONTS } from "../colors";

const FILES: Array<{ name: string; size: string; time: string; dir?: boolean }> =
  [
    { name: "drafts/", size: "—", time: "Apr 14", dir: true },
    { name: "hello-world.md", size: "1.2 KB", time: "Apr 18" },
    { name: "thoughts-on-typing.md", size: "4.7 KB", time: "Apr 22" },
    { name: "2025-summer.md", size: "8.1 KB", time: "May 02" },
    { name: "release-notes.md", size: "2.3 KB", time: "May 07" },
  ];

export const SSHBeat: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  const intro = spring({
    frame,
    fps,
    config: { damping: 200, mass: 0.6 },
    durationInFrames: 30,
  });

  const exit = interpolate(frame, [165, 180], [1, 0], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

  // Cursor walks down the file list, then "opens" the highlighted file.
  const cursorIndex = Math.min(
    FILES.length - 1,
    Math.floor(interpolate(frame, [40, 130], [0, FILES.length - 1], {
      extrapolateLeft: "clamp",
      extrapolateRight: "clamp",
    })),
  );

  const captionOpacity = interpolate(frame, [10, 30], [0, 1], {
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
      <div
        style={{
          opacity: captionOpacity,
          fontFamily: FONTS.sans,
          fontSize: 28,
          color: COLORS.inkDim,
          letterSpacing: 6,
          textTransform: "uppercase",
          marginBottom: 36,
        }}
      >
        edit anywhere — over ssh
      </div>

      <div
        style={{
          width: 1180,
          backgroundColor: COLORS.bgSoft,
          borderRadius: 14,
          boxShadow:
            "0 30px 90px rgba(0,0,0,0.55), 0 0 0 1px rgba(212,207,192,0.06)",
          overflow: "hidden",
          transform: `translateY(${(1 - intro) * 24}px)`,
          opacity: intro,
        }}
      >
        <TitleBar host="dusanek@plume-md.dev" path="/var/www/blog" />
        <div
          style={{
            padding: "20px 28px 28px",
            fontFamily: FONTS.mono,
            fontSize: 22,
            color: COLORS.ink,
          }}
        >
          {FILES.map((f, i) => (
            <FileRow
              key={f.name}
              entry={f}
              active={i === cursorIndex}
              opening={frame > 130 && i === FILES.length - 1}
              delay={i * 4}
            />
          ))}
        </div>
      </div>
    </AbsoluteFill>
  );
};

const TitleBar: React.FC<{ host: string; path: string }> = ({ host, path }) => (
  <div
    style={{
      display: "flex",
      alignItems: "center",
      gap: 8,
      padding: "14px 18px",
      borderBottom: `1px solid rgba(212,207,192,0.08)`,
      fontFamily: FONTS.mono,
      fontSize: 18,
      color: COLORS.inkDim,
    }}
  >
    <Dot color="#ff5f57" />
    <Dot color="#febc2e" />
    <Dot color="#28c840" />
    <span style={{ marginLeft: 18, color: COLORS.inkDim }}>
      <span style={{ color: COLORS.accent }}>{host}</span>
      <span>:</span>
      <span style={{ color: COLORS.warm }}>{path}</span>
    </span>
  </div>
);

const Dot: React.FC<{ color: string }> = ({ color }) => (
  <span
    style={{
      width: 12,
      height: 12,
      borderRadius: 12,
      backgroundColor: color,
      display: "inline-block",
    }}
  />
);

const FileRow: React.FC<{
  entry: { name: string; size: string; time: string; dir?: boolean };
  active: boolean;
  opening: boolean;
  delay: number;
}> = ({ entry, active, opening, delay }) => {
  const frame = useCurrentFrame();
  const reveal = interpolate(frame, [20 + delay, 32 + delay], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
  const slide = interpolate(frame, [20 + delay, 32 + delay], [-12, 0], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

  const openLift = opening
    ? interpolate(frame, [130, 165], [0, -28], {
        extrapolateLeft: "clamp",
        extrapolateRight: "clamp",
      })
    : 0;
  const openOpacity = opening
    ? interpolate(frame, [130, 165], [1, 0.2], {
        extrapolateLeft: "clamp",
        extrapolateRight: "clamp",
      })
    : 1;

  return (
    <div
      style={{
        display: "grid",
        gridTemplateColumns: "1fr 110px 110px",
        padding: "10px 18px",
        borderRadius: 8,
        backgroundColor: active ? "rgba(121,184,255,0.10)" : "transparent",
        color: active ? COLORS.ink : COLORS.inkDim,
        opacity: reveal * openOpacity,
        transform: `translateX(${slide}px) translateY(${openLift}px)`,
        transition: "background-color 120ms ease",
      }}
    >
      <span>
        {entry.dir ? (
          <span style={{ color: COLORS.accent }}>{entry.name}</span>
        ) : (
          entry.name
        )}
      </span>
      <span style={{ textAlign: "right" }}>{entry.size}</span>
      <span style={{ textAlign: "right" }}>{entry.time}</span>
    </div>
  );
};
