# Local app bundle

`FotoLoop.app` is built locally from the Swift package in `Desenvolvimento/` and is ignored by Git. Cloning the repository does not download the app bundle.

From the repository root, build and open it with:

```sh
cd Desenvolvimento
./scripts/build-app.sh
open ../Aplicativo/FotoLoop.app
```

Export requires FFmpeg with `libx264` on the Mac. Video import also requires FFprobe beside FFmpeg. The current bundle is not signed or notarized for distribution.
