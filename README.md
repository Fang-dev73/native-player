# 🎬 @nyjs/native-player

High-performance **native video player** for React Native powered by:

- ⚡ Android: ExoPlayer (Media3)
- 🍎 iOS: AVPlayer

Supports **playlist, subtitles, custom controls, resume playback, and events**.

---

# 🚀 Installation

```bash
npm install @nyjs/native-player
```

---

# 📱 iOS Setup

```bash
cd ios && pod install
```

## ⚠️ Swift Requirement

This library is written in Swift.

If your project does not support Swift:

1. Open your project in Xcode
2. Create a new Swift file
3. Click **"Create Bridging Header"**

---

# 🤖 Android Setup

## ✅ Autolinking supported

No manual linking required.

---

## ⚠️ Minimum Requirements

Ensure:

📄 `android/build.gradle`

```gradle
buildscript {
    ext {
        minSdkVersion = 21
    }
}
```

---

## 🔐 Permissions

📄 `android/app/src/main/AndroidManifest.xml`

```xml
<uses-permission android:name="android.permission.INTERNET" />
```

---

# ⚡ Usage

```tsx
import React from 'react';
import { View } from 'react-native';
import NativePlayer from '@nyjs/native-player';

export default function App() {
  return (
    <View style={{ flex: 1 }}>
      <NativePlayer
        source={{ uri: 'https://www.w3schools.com/html/mov_bbb.mp4' }}
        controls={true}
        paused={false}
        style={{ width: '100%', height: 300 }}
      />
    </View>
  );
}
```

---

# 📦 Source (IMPORTANT)

Player supports **3 formats**:

### 1. Single URL

```ts
source="https://video-url.mp4"
```

---

### 2. Object

```ts
source={{ uri: "https://video-url.mp4", title: "Video 1" }}
```

---

### 3. Playlist (ARRAY)

```ts
source={[
  { uri: "video1.mp4", title: "Video 1" },
  { uri: "video2.mp4", title: "Video 2" }
]}
```

---

# 🎛️ Props

## 🎥 Core Playback

| Prop | Type | Description |
|------|------|------------|
| source | string \| object \| array | Video or playlist |
| paused | boolean | Pause/play control |
| controls | boolean | Show/hide native controls |
| index | number | Start index for playlist |
| title | string | Title displayed in player |

---

## 🔁 Playback Behavior

| Prop | Type | Description |
|------|------|------------|
| resumePlaybackEnabled | boolean | Resume from last position |
| enableSubtitle | boolean | Enable subtitle UI |

---

## 🎨 Player UI Customization

### Progress Bar

| Prop | Description |
|------|------------|
| progressColor | Played progress color |
| trackColor | Background track color |
| thumbColor | Seek thumb color |

---

### Controls Styling

| Prop | Description |
|------|------------|
| buttonTintColor | Play/pause/controls color |
| durationColor | Duration text color |

---

### Subtitle Styling

| Prop | Description |
|------|------------|
| subtitleColor | Subtitle text color |
| subtitleCheckboxColor | Subtitle toggle checkbox |
| subtitleDescriptionColor | Subtitle description text |

---

## 📡 Events

| Prop | Description |
|------|------------|
| onLoad | Called when video loads |
| onProgress | Playback progress updates |
| onVideoEnd | When video finishes |
| onBack | Back button pressed |

---

# 🧠 Important Behaviors (Based on Native Code)

### 🎥 Playlist Handling
- Automatically switches videos using `index`
- Maintains playback state

---

### ⏯ Resume Playback
- Uses native caching/storage
- Works across sessions (Android + iOS)

---

### 📡 Progress Events
- Emitted from native layer (high accuracy)
- Suitable for analytics or UI sync

---

### 🎛 Native Controls
- Fully native (no JS lag)
- Includes:
  - play/pause
  - seek
  - next/previous (playlist)
  - subtitles (if enabled)

---

# 🛠️ Troubleshooting

---

## ❌ Android Crash / Build Issues

```bash
cd android
./gradlew clean
```

---

## ❌ iOS Issues

```bash
cd ios
pod deintegrate
pod install
```

---

## ❌ Video not playing

- Check valid `uri`
- Ensure internet permission
- Test with MP4 (HLS support depends on stream)

---

# 📦 Example App

```bash
cd example
npm install
npm run android
# or
npm run ios
```

---

# ⚠️ Known Limitations

- DRM not supported (yet)
- Advanced streaming (DASH/HLS tuning) depends on source
- Requires proper network permissions

---

# 📄 License

MIT © Yash Narula