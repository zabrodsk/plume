import React from "react";
import { Composition } from "remotion";
import { Plume } from "./Plume";

export const Root: React.FC = () => {
  return (
    <Composition
      id="plume"
      component={Plume}
      durationInFrames={750}
      fps={30}
      width={1920}
      height={1080}
    />
  );
};
