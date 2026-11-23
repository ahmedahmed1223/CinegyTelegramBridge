import { describe, expect, it } from 'vitest'
import type { BridgeStatus } from '../api/client'
import { bridgeLamp, cinegyLamp, telegramLamp } from './lamps'

const status = (overrides: Partial<BridgeStatus['cinegy']> = {}, telegram = 'connected'): BridgeStatus => ({
  version: '9.0.0',
  startedAt: 0,
  publishedAt: 0,
  telegram: { state: telegram, failures: 3 },
  cinegy: { address: '10.0.0.5', channel: 0, health: 'healthy', lastReadAt: 900, freshUntil: 2_000, ...overrides },
  layers: [],
  feed: null,
  urgentNoticeId: null,
})

describe('bridgeLamp', () => {
  it('does not call a stale picture live when the bridge stopped answering', () => {
    expect(bridgeLamp({ stream: 'live', bridgeOnline: false, status: status() }).state).toBe('down')
    expect(bridgeLamp({ stream: 'reconnecting', bridgeOnline: true, status: status() }).state).toBe('warn')
    expect(bridgeLamp({ stream: 'live', bridgeOnline: true, status: status() }).state).toBe('ok')
  })
})

describe('cinegyLamp', () => {
  it('turns amber once the last reading passes its deadline, even if health said healthy', () => {
    expect(cinegyLamp(status(), 1_000).state).toBe('ok')
    expect(cinegyLamp(status(), 2_500).state).toBe('warn')
  })

  it('puts an unreachable engine first', () => {
    expect(cinegyLamp(status({ health: 'unreachable' }), 1_000).state).toBe('down')
  })
})

describe('telegramLamp', () => {
  it('says the web keeps working while Telegram is down', () => {
    const reading = telegramLamp(status({}, 'disconnected'))
    expect(reading.state).toBe('down')
    expect(reading.detail).toContain('الويب يعمل')
  })
})
