import React from "react";
import { AbsoluteFill, Sequence } from "remotion";
import { loadFont as loadFraunces } from "@remotion/google-fonts/Fraunces";
import { COLORS } from "./colors";
import { HeroBloom } from "./scenes/HeroBloom";
import { SSHBeat } from "./scenes/SSHBeat";
import { LightThemeBeat } from "./scenes/LightThemeBeat";
import { FindBeat } from "./scenes/FindBeat";
import { CTABeat } from "./scenes/CTABeat";

loadFraunces("italic", { weights: ["400", "500"] });
loadFraunces("normal", { weights: ["400", "500"] });

export const Plume: React.FC = () => {
  return (
    <AbsoluteFill style={{ backgroundColor: COLORS.bg, overflow: "hidden" }}>
      <Sequence from={0} durationInFrames={180} name="hero">
        <HeroBloom />
      </Sequence>

      <Sequence from={180} durationInFrames={180} name="ssh">
        <SSHBeat />
      </Sequence>

      <Sequence from={360} durationInFrames={180} name="theme">
        <LightThemeBeat />
      </Sequence>

      <Sequence from={540} durationInFrames={120} name="find">
        <FindBeat />
      </Sequence>

      <Sequence from={660} durationInFrames={90} name="cta">
        <CTABeat />
      </Sequence>
    </AbsoluteFill>
  );
};
