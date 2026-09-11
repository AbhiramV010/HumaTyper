'use strict';

// Sampled up front so the timing statistics are testable offline.

import { LogNormal, TypingModel, charClass } from './types';

export interface Keystroke {
  kind: 'char' | 'backspace';
  /** Empty for a backspace. */
  ch: string;
  delayUs: number;
}

export interface SampleOptions {
  text: string;
  /** Net speed over the original text, corrections included. */
  wpm: number;
  /** Per character; the text always ends correct. */
  errorRate?: number;
  lineDelayMs?: number;
  seed?: number;
}

/** Fallback when the model has no confusion row. */
const KEYBOARD_ROWS = ['`1234567890-=', 'qwertyuiop[]\\', "asdfghjkl;'", 'zxcvbnm,./'];
/** Row stagger, in key widths. */
const ROW_OFFSETS = [0, 0.5, 0.75, 1.25];

const adjacency = buildAdjacency();

function buildAdjacency(): Map<string, string[]> {
  const map = new Map<string, string[]>();
  for (let row = 0; row < KEYBOARD_ROWS.length; row++) {
    for (let col = 0; col < KEYBOARD_ROWS[row].length; col++) {
      const key = KEYBOARD_ROWS[row][col];
      const neighbours: string[] = [];
      const x = col + ROW_OFFSETS[row];
      for (let otherRow = Math.max(0, row - 1); otherRow <= Math.min(KEYBOARD_ROWS.length - 1, row + 1); otherRow++) {
        for (let otherCol = 0; otherCol < KEYBOARD_ROWS[otherRow].length; otherCol++) {
          if (otherRow === row && otherCol === col) continue;
          const otherX = otherCol + ROW_OFFSETS[otherRow];
          if (Math.abs(otherX - x) <= 1) neighbours.push(KEYBOARD_ROWS[otherRow][otherCol]);
        }
      }
      map.set(key, neighbours);
    }
  }
  return map;
}

/** Seedable, so a run reproduces exactly. */
function mulberry32(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

class Random {
  private spare: number | null = null;

  constructor(private readonly next: () => number) {}

  uniform(): number {
    return this.next();
  }

  /** Box-Muller; caches the second value. */
  normal(): number {
    if (this.spare !== null) {
      const value = this.spare;
      this.spare = null;
      return value;
    }
    let u = 0;
    let v = 0;
    let s = 0;
    do {
      u = this.next() * 2 - 1;
      v = this.next() * 2 - 1;
      s = u * u + v * v;
    } while (s === 0 || s >= 1);
    const scale = Math.sqrt((-2 * Math.log(s)) / s);
    this.spare = v * scale;
    return u * scale;
  }

  pick<T>(items: T[]): T {
    return items[Math.floor(this.next() * items.length) % items.length];
  }

  weighted(weights: Record<string, number>): string | null {
    let total = 0;
    for (const key in weights) total += weights[key];
    if (total <= 0) return null;
    let roll = this.next() * total;
    for (const key in weights) {
      roll -= weights[key];
      if (roll <= 0) return key;
    }
    return null;
  }

  fromPmf(pmf: number[]): number {
    let roll = this.next();
    for (let i = 0; i < pmf.length; i++) {
      roll -= pmf[i];
      if (roll <= 0) return i;
    }
    return 0;
  }
}

function wrongCharacter(model: TypingModel, intended: string, random: Random): string | null {
  const row = model.errors.confusion[intended];
  const sampled = row ? random.weighted(row) : null;
  if (sampled) return sampled;

  // Unobserved character: hit a neighbouring key.
  const lower = intended.toLowerCase();
  const neighbours = adjacency.get(lower);
  if (!neighbours || !neighbours.length) return null;
  const neighbour = random.pick(neighbours);
  return intended === lower ? neighbour : neighbour.toUpperCase();
}

function expectedInterval(model: TypingModel, prev: string, ch: string): LogNormal {
  const exact = model.digraphs[prev + ch];
  if (exact) return exact;
  const pair = model.classPairs[charClass(prev) + '>' + charClass(ch)];
  if (pair) return pair;
  return model.global;
}

interface PlannedKey {
  kind: 'char' | 'backspace';
  ch: string;
  /** Distribution for the interval before this key. */
  timing: 'normal' | 'notice' | 'backspace' | 'resume';
}

/** Mistakes are always corrected, so the final text is unchanged. */
function planKeys(model: TypingModel, chars: string[], errorRate: number, random: Random): PlannedKey[] {
  const keys: PlannedKey[] = [];
  const kinds = model.errors.kinds;
  const text = chars;

  /** Editors disagree on backspacing astral and combining characters. */
  const simple = (ch: string): boolean => ch.length === 1 && !/\p{M}/u.test(ch);

  /** Stops at line breaks and risky characters. */
  const runLength = (at: number, wanted: number): number => {
    let count = 0;
    while (count < wanted && at + count < text.length && text[at + count] !== '\n' && simple(text[at + count])) {
      count++;
    }
    return count;
  };

  let i = 0;
  while (i < text.length) {
    const ch = text[i];
    const nextSimple = i + 1 >= text.length || simple(text[i + 1]);
    const canErr =
      errorRate > 0 && ch !== '\n' && ch !== '\t' && simple(ch) && nextSimple && random.uniform() < errorRate;

    if (!canErr) {
      keys.push({ kind: 'char', ch, timing: 'normal' });
      i++;
      continue;
    }

    const kind = random.weighted({
      substitution: kinds.substitution,
      insertion: kinds.insertion,
      transposition: kinds.transposition,
    });

    const mistaken: string[] = [];

    if (kind === 'transposition' && i + 1 < text.length && text[i + 1] !== '\n') {
      mistaken.push(text[i + 1], text[i]);
    } else if (kind === 'insertion') {
      const extra = wrongCharacter(model, ch, random);
      if (!extra) {
        keys.push({ kind: 'char', ch, timing: 'normal' });
        i++;
        continue;
      }
      mistaken.push(extra);
    } else {
      const wrong = wrongCharacter(model, ch, random);
      if (!wrong || wrong === ch) {
        keys.push({ kind: 'char', ch, timing: 'normal' });
        i++;
        continue;
      }
      mistaken.push(wrong);
    }

    // Keep typing until noticed, then backspace over all of it.
    const consumed = kind === 'transposition' ? 2 : kind === 'insertion' ? 0 : 1;
    const lag = Math.min(random.fromPmf(model.errors.detectionLag), runLength(i + consumed, 8));
    const followOn: string[] = [];
    for (let k = 0; k < lag; k++) followOn.push(text[i + consumed + k]);

    for (const wrong of mistaken) keys.push({ kind: 'char', ch: wrong, timing: 'normal' });
    for (const extra of followOn) keys.push({ kind: 'char', ch: extra, timing: 'normal' });

    const toDelete = mistaken.length + followOn.length;
    for (let k = 0; k < toDelete; k++) {
      keys.push({ kind: 'backspace', ch: '', timing: k === 0 ? 'notice' : 'backspace' });
    }

    const retype = consumed + lag || 1;
    for (let k = 0; k < retype && i + k < text.length; k++) {
      keys.push({ kind: 'char', ch: text[i + k], timing: k === 0 ? 'resume' : 'normal' });
    }
    i += retype;
  }

  return keys;
}

function sampleLogNormal(distribution: LogNormal, random: Random, extraSigma = 0): number {
  const sigma = Math.sqrt(distribution.sigma ** 2 + extraSigma ** 2);
  return Math.exp(distribution.mu + sigma * random.normal());
}

/** Scaled once at the end, so corrections never change the WPM. */
export function sampleSchedule(model: TypingModel, options: SampleOptions): Keystroke[] {
  const text = options.text.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  if (!text.length) return [];

  // Code points, so an emoji is one keystroke.
  const chars = Array.from(text);

  const random = new Random(mulberry32(options.seed ?? (Math.random() * 2 ** 32) >>> 0));
  const errorRate = Math.max(0, Math.min(0.5, options.errorRate ?? model.errors.rate));
  const keys = planKeys(model, chars, errorRate, random);

  const runOffset = random.normal() * model.variation.runSigma;
  const keystrokeSigma = model.variation.keystrokeSigma;

  const schedule: Keystroke[] = [];
  let previousChar = '';

  for (const key of keys) {
    let ratio: number;
    if (key.timing === 'notice') {
      ratio = sampleLogNormal(model.errors.noticePause, random);
    } else if (key.timing === 'backspace') {
      ratio = sampleLogNormal(model.errors.backspace, random);
    } else if (key.timing === 'resume') {
      ratio = sampleLogNormal(model.errors.resume, random);
    } else if (!previousChar) {
      ratio = 1;
    } else {
      const distribution = expectedInterval(model, previousChar, key.ch);
      // Pair gives the mean; spread comes only from keystrokeSigma.
      ratio = Math.exp(distribution.mu + runOffset + keystrokeSigma * random.normal());
    }

    let delayMs = model.fitted.medianIkiMs * ratio;
    if (previousChar === '\n' && options.lineDelayMs) delayMs += options.lineDelayMs;

    // No holds: realistic ones trigger key-repeat, and intervals are press-to-press.
    schedule.push({
      kind: key.kind,
      ch: key.ch,
      delayUs: Math.max(0, Math.round(delayMs * 1000)),
    });

    if (key.kind === 'char') previousChar = key.ch;
  }

  rescaleToWpm(schedule, chars.length, options.wpm);
  return schedule;
}

/** Measured against the original text, not the keystrokes sent. */
function rescaleToWpm(schedule: Keystroke[], characters: number, wpm: number): void {
  const target = (characters / (Math.max(1, wpm) * 5)) * 60000;
  let total = 0;
  for (const key of schedule) total += key.delayUs / 1000;
  if (total <= 0) return;

  const scale = target / total;
  for (const key of schedule) {
    key.delayUs = Math.max(0, Math.round(key.delayUs * scale));
  }
}
