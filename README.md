# vovo-mel-viz

MelViz is a macOS spectogram visualizer that shows the actual `[T, 100]` log-mel a TTS model produces.  It lets you re-runs the vocoder so you can *hear* the edit, and A/Bs it against the original.  It's all live, and can work mid-sentence.  It was built to help debug [Vovo](https://github.com/franckverrot/vovo-core), a TTS voice model made from-scratch in Swift with Metal kernels, as a tool to find out *where* the model didn't perform properly.

![2-D heatmap](docs/screenshot-2d.png)

![3-D terrain of the same mel](docs/screenshot-3d.png)

## What it does

- **Sources**: any WAV (through the same mel extractor the model trains on), or a sentence synthesized by a Vovo checkpoint, with the decoder output and the encoder's prior μ as switchable layers.
- **View**: a Metal heatmap on a fixed colormap scale (so level errors don't hide behind auto-scaling), and a SceneKit 3D terrain you can rotate/zoom into.
- **Develop panel**: exposure, contrast around a pivot, highlights/shadows, low/high spectral tilt, high cut (mute bands above N), floor, temporal smoothing.  Every move re-applies instantly and re-vocodes after a short debounce.
- **Listen**: Vocos or Griffin-Lim; play, A/B, and a **Live** loop that hot-swaps the audio at the playhead with a 20 ms crossfade so you hear a slider move within ~150 ms without restarting the sentence.
- **Models**: the downloaded Vovo voice, plus any Vovo acoustic checkpoint / Vocos vocoder you point it at (the Model and Vocoder menus list every `.safetensors` found in the weights folder and under `checkpoints/`, `exports/`, `assets/` of the current directory, classified by reading the file header; `…` browses anywhere).  Switching re-synthesizes / re-vocodes.
- **Export**: original and edited WAV + PNG + the parameters as JSON.
- **Local API** on `127.0.0.1:4747` so the app can be driven and inspected from a shell (or by an agent): `GET /state`, `/mel.png`, `/audio.wav`, `/screenshot.png`, `/models`; `POST /load`, `/params`, `/vocoder`, `/models`, `/play`, `/stop`, `/view`, `/export`.  It's all local, nothing leaves the machine, but that endpoint is not protected so don't expose it to anything.



## How to build and run it

The app is a SwiftUI + Metal + SceneKit executable. Everything it needs to run the model (the Metal inference engine, mel extraction, the acoustic model, the Vocos vocoder and the text front-end) is in this repository.

```
git clone git@github.com:franckverrot/vovo-mel-viz.git
cd vovo-mel-viz
swift build -c release
.build/release/vovo-mel
```

`VOVO_MEL_WAV=path.wav` preloads a file; `VOVO_MEL_PORT` changes the API port. Requires macOS 15+ on Apple silicon.

### Downloading weight/tensor files

The app ships without weights: upon first launch, it will offer to download about 135MB of Vovo voice (acoustic files and vocoder,) from `[franckverrot/vovo](https://huggingface.co/franckverrot/vovo)` into
`~/Library/Application Support/vovo-mel-viz/weights/` and selects them.  Until then, WAVs still load and edit (vocoded with Griffin-Lim).

## Turning some knobs


| control              | formula                                       | question it asks                       |
| -------------------- | --------------------------------------------- | -------------------------------------- |
| Exposure (dB)        | `v += exposure·k`                             | is the vocoder level-sensitive?        |
| Contrast, Pivot      | `x = (v − pivot)·contrast`                    | dynamic range around the speech median |
| Highlights / Shadows | `x > 0 ? x·(1+h) : x·(1−s)`                   | loud vs quiet cells separately         |
| Low / High tilt (dB) | `v += (tiltLow·(1−b/99) + tiltHigh·(b/99))·k` | spectral tilt                          |
| High cut             | bands `≥ N` → floor                           | is the artifact in the top bands?      |
| Floor (dB)           | `v = max(v, floor)`                           | does hiss come from the floor?         |
| Smooth               | first-order EMA over frames                   | frame-to-frame jitter?                 |




## License

MIT.