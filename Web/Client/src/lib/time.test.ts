import { describe, expect, it } from 'vitest'
import { formatAgo, formatClock, isFresh } from './time'

describe('formatClock', () => {
  it('counts minutes and seconds, then hours', () => {
    expect(formatClock(7_000)).toBe('0:07')
    expect(formatClock(725_000)).toBe('12:05')
    expect(formatClock(3_725_000)).toBe('1:02:05')
  })

  it('never shows a negative time for a clock that ran past its moment', () => {
    expect(formatClock(-5_000)).toBe('0:00')
  })
})

describe('formatAgo', () => {
  it('rounds to the unit a person reads', () => {
    expect(formatAgo(10_000)).toBe('الآن')
    expect(formatAgo(5 * 60_000)).toBe('منذ 5 د')
    expect(formatAgo(3 * 3_600_000)).toBe('منذ 3 س')
    expect(formatAgo(72 * 3_600_000)).toBe('منذ 3 يوم')
  })
})

describe('isFresh', () => {
  it('stops trusting a reading at its deadline, and never trusts an unknown one', () => {
    expect(isFresh(2_000, 1_999)).toBe(true)
    expect(isFresh(2_000, 2_000)).toBe(false)
    expect(isFresh(0, 0)).toBe(false)
  })
})
