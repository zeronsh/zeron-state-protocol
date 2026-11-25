// A seeded generator for tests: xorshift128 on 32-bit words, seeded by splitmix32. Quick, and enough for tests.

export type Random = {
  int: (lo: number, hi: number) => number; // from lo to hi, both included, as Luau's math.random(lo, hi)
  shuffle: <T>(list: T[]) => void;
};

export function random(seed: number): Random {
  let s = seed >>> 0;
  const mix = (): number => {
    s = (s + 0x9e3779b9) >>> 0;
    let z = s;
    z = Math.imul(z ^ (z >>> 16), 0x85ebca6b);
    z = Math.imul(z ^ (z >>> 13), 0xc2b2ae35);
    return (z ^ (z >>> 16)) >>> 0 || 1;
  };
  let x = mix();
  let y = mix();
  let z = mix();
  let w = mix();
  const next = (): number => {
    const t = x ^ (x << 11);
    x = y;
    y = z;
    z = w;
    w = (w ^ (w >>> 19) ^ (t ^ (t >>> 8))) >>> 0;
    return w;
  };
  const int = (lo: number, hi: number): number => lo + Math.floor(((next() * 2 ** 21 + (next() >>> 11)) / 2 ** 53) * (hi - lo + 1));
  return {
    int,
    shuffle<T>(list: T[]): void {
      for (let j = list.length - 1; j > 0; j--) {
        const k = int(0, j);
        const v = list[j];
        list[j] = list[k];
        list[k] = v;
      }
    },
  };
}
