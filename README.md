# vovo-mel-viz

MelViz is a macOS spectrogram visualizer that shows the actual `[T, 100]` log-mel a TTS model produces.  It lets you re-run the vocoder so you can *hear* the edit, and A/Bs it against the original.  It's all live, and can work mid-sentence.  It was built to help debug [Vovo](https://github.com/franckverrot/vovo-core), a TTS voice model made from-scratch in Swift with Metal kernels, as a tool to find out *where* the model didn't perform properly.

It also went one step further than looking: you can **drag the pitch contour and drop in pauses and emphasis right on the picture**, and the app writes the SSML back into the text box.  Think Adobe Premiere, but for spectrograms.

![The editor: F0 contour and phone ribbon over the mel, a draggable playhead, and the SSML the canvas edits produced](docs/screenshot-2d.png)

Above: a sentence synthesized from SSML.  The blue line is the measured F0 contour, the row of symbols under the mel is the phone each moment is pronouncing, the orange triangle is the playhead (drag it, or scrub anywhere on the ruler), and the text box at the bottom holds markup that was written *by dragging the picture* — `<prosody pitch="+9.0st">` came from pulling the contour up over "red".

![3-D terrain of the same mel](docs/screenshot-3d.png)

## What it does

- **Timeline**: the measured F0 contour and a phone ribbon drawn over the mel, a real time ruler with ticks and seconds, and a playhead you can drag or scrub.  You see which sound is being pronounced at any moment, which is what makes a spectrogram legible in the first place.
- **Draw the prosody**: in ✎ Pitch mode, drag the contour and the phones under your cursor are re-synthesized *from the same starting noise*, so only what you dragged changes — that is the difference between an edit and a re-roll.
- **Structural edits**: `❚❚ Break` inserts a pause of an exact length at the playhead, `Emphasize` / `Soften` set an emphasis level on the word under it.
- **It writes the markup**: canvas edits become SSML in the text field — a break or an emphasis lands there as soon as you apply it (`<break time="400ms"/>`, `<emphasis level="strong">`), and pitch drags accumulate until you press **Write markup**, which turns them into `<prosody pitch="+2.2st">` around the words you bent.  The text is the document; the picture is another way to type into it.  Edit either one.
- **Transport**: Play resumes from the playhead (Pause keeps its position), and the space bar toggles them unless you're typing.
- **Sources**: any WAV (through the same mel extractor the model trains on), or a sentence synthesized by a Vovo checkpoint, with the decoder output and the encoder's prior μ as switchable layers.
- **View**: a Metal heatmap on a fixed colormap scale (so level errors don't hide behind auto-scaling), and a SceneKit 3D terrain you can rotate/zoom into.
- **Develop panel**: exposure, contrast around a pivot, highlights/shadows, low/high spectral tilt, high cut (mute bands above N), floor, temporal smoothing.  Every move re-applies instantly and re-vocodes after a short debounce.
- **Listen**: Vocos or Griffin-Lim; play, A/B, and a **Live** loop that hot-swaps the audio at the playhead with a 20 ms crossfade so you hear a slider move within ~150 ms without restarting the sentence.
- **Models**: the downloaded Vovo voice, plus any Vovo acoustic checkpoint / Vocos vocoder you point it at (the Model and Vocoder menus list every `.safetensors` found in the weights folder and under `checkpoints/`, `exports/`, `assets/` of the current directory, classified by reading the file header; `…` browses anywhere).  Switching re-synthesizes / re-vocodes.
- **Prosody knobs**: guidance, ODE steps, pitch (semitones), range and volume in the bottom bar, applied to the whole sentence — the same controls `vovo say` and `vovo-mlx` expose.
- **Export**: original and edited WAV + PNG + the parameters as JSON.
- **Local API** on `127.0.0.1:4747` so the app can be driven and inspected from a shell (or by an agent): `GET /state`, `/mel.png`, `/audio.wav`, `/screenshot.png`, `/models`, `/pitch`; `POST /load`, `/params`, `/vocoder`, `/models`, `/play`, `/stop`, `/view`, `/pitch`, `/export`.  `/pitch` is the whole editing surface: `{"phone": 12, "hz": 180}` to bend a note, `{"scrub": 0.68}` to move the playhead, `{"break": 300}` / `{"emphasis": "strong"}` to edit at it, `{"commit": true}` to write the markup out.  It's all local, nothing leaves the machine, but that endpoint is not protected so don't expose it to anything.



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

## Drawing prosody

The loop the app was built around:

1. Type a sentence in the bottom field and press **Say** (or `⌘↵`).
2. Switch on **✎ Pitch** and drag the blue contour where the reading is wrong — over one word, or across a phrase.  Each drag re-synthesizes from the same noise, so only what you touched moves.
3. Scrub to a word boundary and press **❚❚ Break** for a pause of an exact length, or **Emphasize** / **Soften** on the word under the playhead.
4. Press **Write markup**.  The text field now holds the SSML that reproduces what you drew:

```xml
<speak>I said <prosody pitch="+9.0st">red,</prosody> not
<prosody pitch="+10.4st"><emphasis level="reduced">blue.</emphasis></prosody></speak>
```

That markup is portable — it is the same subset `vovo say` and [`vovo-mlx`](https://github.com/franckverrot/vovo-mlx) accept, so a reading you dialed in by hand is something you can ship.

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