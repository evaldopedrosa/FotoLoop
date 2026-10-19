<div align='center'>
  <img src='Design/FotoLoop-AppIcon-1024.png' alt='FotoLoop app icon' width='112'>
  <h1>FotoLoop</h1>
  <p>Turn a sequence of photos into a GIF or MP4 on your Mac.</p>
  <p>Native macOS · Offline · Free and open source</p>
  <p><a href='#getting-started'>Get started</a> · <a href='#features'>Features</a> · <a href='README.pt-BR.md'>Português</a></p>
</div>

FotoLoop is a small macOS app for animating photo sequences. Import images, arrange them, adjust the timing and framing, and export. Your photos stay on your Mac.

## Preview

![FotoLoop with a ten-photo sequence loaded in dark mode](docs/images/fotoloop-editor-dark.png)

<details>
<summary>See the initial screen</summary>

![FotoLoop initial screen in dark mode](docs/images/fotoloop-empty-dark.png)

</details>

## Getting started

**Current release: source code.** There is no DMG or Homebrew package for FotoLoop yet. Homebrew is used below only to install FFmpeg, which the app needs for export.

Requirements: macOS 13 or later, a Swift 5.9+ toolchain with the macOS SDK, and FFmpeg with `libx264`. This version was built and checked on an Apple Silicon Mac; Intel Macs and macOS 13 hardware have not been verified.

1. Install Apple's Command Line Tools with `xcode-select --install` (or use Xcode). If you do not have Homebrew, follow the instructions at [brew.sh](https://brew.sh/).
2. Install FFmpeg, then clone and build FotoLoop:

   ```sh
   brew install ffmpeg
   git clone https://github.com/evaldopedrosa/FotoLoop.git
   cd FotoLoop/Desenvolvimento
   ./scripts/build-app.sh
   open ../Aplicativo/FotoLoop.app
   ```

The build script creates `Aplicativo/FotoLoop.app` with the project icon. To keep it in your Applications folder, move the app there with Finder. The generated app is ignored by Git.

FotoLoop looks for FFmpeg at `/opt/homebrew/bin/ffmpeg`, `/usr/local/bin/ffmpeg`, or `/usr/bin/ffmpeg`. A copy installed elsewhere is not detected automatically.

## Features

- Import JPG, PNG, and HEIC images, including folders with subfolders, in natural filename order.
- Reorder photos by dragging thumbnails or using the arrow buttons.
- Set a pace from 4 to 30 photos per second, enable ping-pong, and repeat the full sequence 1–20 times. GIF playback loops independently of these repetitions.
- Export in the original aspect ratio, 1:1, 4:5, 5:4, 16:9, or 9:16. Fit the whole image with margins or fill the canvas with a centered crop.
- Preview the result, choose resolution and quality, and clear the session to start again.
- Follow the macOS appearance or choose a saved light or dark preference.

### Basic workflow

1. Add photos or import a folder.
2. Drag thumbnails into order, or select one and use the arrows.
3. Adjust speed, ping-pong, repeats, aspect ratio, framing, resolution, and quality.
4. Export a GIF or MP4. Clear the session when you want to begin another sequence.

**Fit (Ajustar)** keeps the entire photo and adds black margins where needed. **Fill (Preencher)** crops from the center without stretching. Every frame in the exported file has consistent dimensions. GIF timing is rounded to hundredths of a second; MP4 files use a 30 fps output stream.

## Built for a small, offline workflow

The interface uses SwiftUI and AppKit, ImageIO reads the photos, and an external FFmpeg executable encodes the output. There are no accounts, analytics, network features, or third-party Swift packages. The app interface is currently in Portuguese.

## Source and verification

| Path | Purpose | In Git |
| --- | --- | --- |
| `Desenvolvimento/` | SwiftPM source, tests, and build scripts | Yes, excluding build caches and `work/` |
| `Design/` | App icon artwork and macOS icon file | Yes |
| `Aplicativo/` | Locally built app | Only the folder guide; the `.app` is ignored |

Run the automated tests with:

```sh
cd Desenvolvimento
./scripts/test.sh
```

The test suite uses synthetic images and checks import, ordering, sessions, framing, and actual GIF/MP4 output across 42 export combinations. Import, drag-and-drop, export through the macOS save panels, and starting a new session were also checked in the app with synthetic images.

[Performance notes](PERFORMANCE.md) document the local measurements and their limits. They do not claim a measured improvement in whole-app frame rate or memory use.

## Current limits

- The app has not been signed or notarized for distribution. There is no downloadable installer yet.
- Intel Macs and a physical macOS 13 machine have not been tested.
- Export cannot be cancelled once encoding starts. The crop stays centered; sessions are not saved.
- A cold preview cache can skip frames in demanding sequences.

## Credits and license

Made by **Evakdo 🇧🇷**. Licensed under [MIT](LICENSE).
