import type { BridgeStatus } from '../api/client'
import type { LiveStatus } from '../hooks/useStatusStream'
import type { Lamp } from '../layout/SignalLamp'
import { isFresh } from './time'

export interface LampReading {
  state: Lamp
  detail: string
}

/** Can this page trust what it shows? Two links: browser-server, server-bridge. */
export function bridgeLamp(live: LiveStatus): LampReading {
  if (live.stream === 'connecting') return { state: 'unknown', detail: 'يتصل بخادم الويب…' }
  if (live.stream === 'reconnecting') return { state: 'warn', detail: 'انقطع الاتصال بخادم الويب، يُعاد الآن' }
  if (!live.bridgeOnline) return { state: 'down', detail: 'الجسر لا يجيب: ما تراه آخر حالة معروفة' }
  return { state: 'ok', detail: 'الجسر يعمل والحالة حيّة' }
}

export function cinegyLamp(status: BridgeStatus | null, now: number): LampReading {
  if (!status) return { state: 'unknown', detail: 'لا قراءة بعد' }
  const health = status.cinegy.health
  if (health === 'unreachable') return { state: 'down', detail: 'المحرك لا يُجيب' }
  if (health === 'unhealthy') return { state: 'warn', detail: 'المحرك يُجيب لكن صحته غير سليمة' }
  if (!isFresh(status.cinegy.freshUntil, now)) return { state: 'warn', detail: 'آخر قراءة للطبقات غير مؤكَّدة' }
  return { state: 'ok', detail: 'المحرك سليم والقراءة حديثة' }
}

export function telegramLamp(status: BridgeStatus | null): LampReading {
  if (!status) return { state: 'unknown', detail: 'لا قراءة بعد' }
  if (status.telegram.state === 'connected') return { state: 'ok', detail: 'البوت متصل بـ Telegram' }
  if (status.telegram.state === 'disconnected') {
    return { state: 'down', detail: `البوت منقطع عن Telegram (${status.telegram.failures} محاولة فاشلة) — الويب يعمل رغم ذلك` }
  }
  return { state: 'unknown', detail: 'حالة Telegram غير معروفة بعد' }
}
