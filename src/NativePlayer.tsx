import React from 'react';
import {
  requireNativeComponent,
  ViewProps,
  StyleProp,
  ViewStyle,
} from 'react-native';

type VideoSourceItem = {
  uri: string;
  title?: string;
};

type VideoSource =
  | string
  | VideoSourceItem
  | VideoSourceItem[];

export type NativePlayerProps = ViewProps & {
  source?: VideoSource;

  paused?: boolean;
  controls?: boolean;
  enableSubtitle?: boolean;

  index?: number;
  title?: string;
  resumePlaybackEnabled?: boolean;

  progressColor?: string;
  trackColor?: string;
  thumbColor?: string;
  buttonTintColor?: string;
  durationColor?: string;

  subtitleColor?: string;
  subtitleCheckboxColor?: string;
  subtitleDescriptionColor?: string;

  onLoad?: (event: any) => void;
  onProgress?: (event: any) => void;
  onVideoEnd?: () => void;
  onBack?: () => void;

  style?: StyleProp<ViewStyle>;
};

const NativeVideoPlayer =
  requireNativeComponent<NativePlayerProps>('RNVideoPlayer');

export const NativePlayer = (props: NativePlayerProps) => {
  return <NativeVideoPlayer {...props} />;
};