'use strict';

// Timings are ratios to the typist's median interval, so any WPM rescales cleanly.

/** Parameters in log space. */
export interface LogNormal {
  mu: number;
  sigma: number;
  n: number;
}

/** Backoff buckets for letter pairs never observed. */
export type CharClass = 'lower' | 'upper' | 'digit' | 'space' | 'punct' | 'newline' | 'other';

export interface ErrorModel {
  /** Corrected errors per character. */
  rate: number;
  /** Sums to 1. */
  kinds: {
    substitution: number;
    insertion: number;
    transposition: number;
  };
  /** P(typed | intended); unseen rows fall back to QWERTY adjacency. */
  confusion: Record<string, Record<string, number>>;
  /** PMF of characters typed before the mistake is noticed. */
  detectionLag: number[];
  /** Before the first backspace. */
  noticePause: LogNormal;
  backspace: LogNormal;
  /** First keystroke after a correction. */
  resume: LogNormal;
}

export interface TypingModel {
  version: number;
  source: {
    name: string;
    url: string;
    citation: string;
    license: string;
  };
  fitted: {
    date: string;
    participants: number;
    sentences: number;
    keystrokes: number;
    /** The base every ratio scales from. */
    medianIkiMs: number;
    medianWpm: number;
  };

  /** Keyed by the two characters. */
  digraphs: Record<string, LogNormal>;
  /** Keyed "prevClass>nextClass". */
  classPairs: Record<string, LogNormal>;
  global: LogNormal;

  /** Absolute ms, not ratios; unused at runtime. */
  holds: Record<string, LogNormal>;

  /** Flat autocorrelation means no drift: a per-run offset plus per-key noise. */
  variation: {
    /** Drawn once per run. */
    runSigma: number;
    keystrokeSigma: number;
    /** Evidence for the flat autocorrelation; unused at runtime. */
    lagProfile: Record<string, number>;
  };

  errors: ErrorModel;
}

export function charClass(ch: string): CharClass {
  if (ch === '\n') return 'newline';
  if (ch === ' ' || ch === '\t') return 'space';
  if (ch >= 'a' && ch <= 'z') return 'lower';
  if (ch >= 'A' && ch <= 'Z') return 'upper';
  if (ch >= '0' && ch <= '9') return 'digit';
  if (/[!-/:-@[-`{-~]/.test(ch)) return 'punct';
  return 'other';
}
