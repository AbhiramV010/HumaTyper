# HumaTyper

Types your text into any window as real keystrokes, with timing and typos drawn from a
model of real typists. Useful wherever pasting doesn't work: paste-blocking forms, remote
desktops, chat boxes. Windows only.

![platform](https://img.shields.io/badge/platform-Windows-blue) ![license](https://img.shields.io/badge/license-MIT-green)

## Install

```powershell
irm https://github.com/AbhiramV010/HumaTyper/raw/main/install.ps1 | iex
```

Open a new terminal and run `humatype`. To uninstall, run the same script with `-Uninstall`:
`& ([scriptblock]::Create((irm <url above>))) -Uninstall`. From source: `npm install && npm start`.

## Use

1. Pick the target window, paste your text, and set the WPM and typos per 100 characters.
2. Press **Start typing** or **F6**. After a 3-second countdown, HumaTyper raises the window and types.
3. **F6**, **F7**, or **Esc** stops it. If focus leaves the target, typing stops on its own.

Apps running as administrator need HumaTyper running as administrator too.

## How it works

The Electron UI hands each run to `src/typer.ps1`, which injects keys through Win32
`SendInput` as Unicode input. The target can't tell them from a real keyboard, and any
character types correctly regardless of layout, emoji included.

Before a run, `src/model/sampler.ts` turns the text into a schedule of keystrokes and delays:

- **Letter pairs** set each interval: `th` takes 0.67× the median gap, `e!` takes 3.87×. Unseen pairs fall back to character classes, then a global fit.
- **Pace** is fixed per run, plus independent per-key variation. The data shows no drift within a run.
- **Typos** come from a confusion matrix learned from real corrections (QWERTY neighbours as a fallback), with fitted pauses for noticing, backspacing and resuming. Every typo is fixed, so the final text always matches.
- The whole schedule is scaled once, so the run hits your WPM with corrections included.

Turn **Rhythm** off for an even pace instead.

## Training data

The model is fitted on the [136M Keystrokes dataset](https://userinterfaces.aalto.fi/136Mkeystrokes/).
From 2,000 randomly sampled participants, 1,787 had enough data: 26,399 sentences, about
1.1 million keystrokes. Their median pace is 160 ms per key (75 WPM), and they corrected
3.1% of characters. Only aggregate statistics are committed (`src/model/typing-model.json`),
never raw keystrokes.

To refit:

```sh
npm run dataset:fetch -- --n 2000   # range requests, not the 1.4 GB archive
npm run model:train
npm run model:verify                # replayed text must match the input exactly
```

## License

MIT. The model derives from the 136M Keystrokes dataset, free for non-commercial use with
attribution: Dhakal, Feit, Kristensson, Oulasvirta. *Observations on Typing from 136 Million
Keystrokes.* CHI '18. [doi:10.1145/3173574.3174220](https://doi.org/10.1145/3173574.3174220)
