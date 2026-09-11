# HumaTyper

HumaTyper types your text into another window one keystroke at a time. The timing and the
typos come from a model fitted to real people typing. It's for places where you can't paste:
forms that block it, remote desktops, chat boxes. Windows only.

![platform](https://img.shields.io/badge/platform-Windows-blue) ![license](https://img.shields.io/badge/license-MIT-green)

## Install

```powershell
irm https://github.com/AbhiramV010/HumaTyper/raw/main/install.ps1 | iex
```

This puts HumaTyper in `C:\HumaTyper` and adds that folder to your PATH. Open a new terminal
and type `humatype` to start it.

To uninstall:

```powershell
& ([scriptblock]::Create((irm https://github.com/AbhiramV010/HumaTyper/raw/main/install.ps1))) -Uninstall
```

It looks different from the install line because `irm | iex` can't pass arguments to the script.

To run from source instead:

```sh
npm install
npm start
```

## Use

1. Pick the window you want to type into, paste your text, and set the speed (WPM) and how
   many typos you want per 100 characters.
2. Click **Start typing** or press **F6**. After a 3-second countdown, HumaTyper brings that
   window to the front and starts typing.
3. Press **F6**, **F7**, or **Esc** to stop. It also stops by itself if the target window loses focus.

If the app you're typing into runs as administrator, HumaTyper has to run as administrator too.

## How it works

The Electron UI passes each run to `src/typer.ps1`. That script sends keys through the Win32
`SendInput` API as Unicode input, so the target app can't tell them apart from a real keyboard.
Every character comes out right whatever your keyboard layout is, emoji included.

Before a run starts, `src/model/sampler.ts` turns your text into a list of keystrokes and the
delays between them:

- The gap before each key depends on the letter pair. `th` is quick at 0.67× the median gap,
  while `e!` takes 3.87×. If a pair never showed up in the data, the model falls back to
  character classes, and then to one global fit.
- Each run gets one fixed pace, and each key varies a little on its own. In the data, people's
  pace didn't drift over a run, so the model's doesn't either.
- Typos come from a confusion matrix built from corrections people actually made, with QWERTY
  neighbours as a fallback. The pauses for noticing a typo, backspacing and picking back up are
  fitted too. Every typo gets fixed, so the final text always matches what you pasted.
- At the end, the whole schedule is scaled once so the run lands on your WPM, corrections included.

Turn **Rhythm** off if you'd rather have an even pace.

## Training data

The model is fitted on the [136M Keystrokes dataset](https://userinterfaces.aalto.fi/136Mkeystrokes/).
Of 2,000 participants picked at random, 1,787 had enough data to use. That came to 26,399
sentences and about 1.1 million keystrokes. Their median pace was 160 ms per key
(75 WPM), and they corrected 3.1% of characters. The repo only keeps aggregate statistics
(`src/model/typing-model.json`), never raw keystrokes.

To refit the model:

```sh
npm run dataset:fetch -- --n 2000   # uses range requests, so it skips the 1.4 GB archive
npm run model:train
npm run model:verify                # checks that replayed text matches the input exactly
```

## License

MIT. The model is derived from the 136M Keystrokes dataset, which is free for non-commercial
use with attribution: Dhakal, Feit, Kristensson, Oulasvirta. *Observations on Typing from 136
Million Keystrokes.* CHI '18. [doi:10.1145/3173574.3174220](https://doi.org/10.1145/3173574.3174220)
