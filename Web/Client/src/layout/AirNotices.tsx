import { notifications } from '@mantine/notifications'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useRef } from 'react'
import { api, errorCode } from '../api/client'
import { manualKey } from '../pages/newsroom/urgentManualApi'
import { UrgentNotice } from './UrgentNotice'

const titles: Record<string, string> = {
  SHOW: 'قُبل عرض القالب على الهواء',
  HIDE: 'قُبل إخفاء القالب من الهواء',
  EXIT: 'قُبل خروج المشهد من حلقة التكرار',
}

export function AirNotices({ actor, noticeId }: { actor: number; noticeId?: string | null }) {
  const client = useQueryClient()
  const storageKey = `air-notices:${actor}`
  const seen = useRef<Set<string> | null>(null)
  const feed = useQuery({
    queryKey: ['shift-notices', 'personal', actor],
    refetchInterval: 4000, refetchIntervalInBackground: true, retry: 1,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/notices/me', { signal })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })
  useEffect(() => {
    const events = feed.data?.events
    if (!events) return
    if (!seen.current) {
      seen.current = new Set()
      try {
        const saved = JSON.parse(sessionStorage.getItem(storageKey) ?? '[]')
        if (Array.isArray(saved)) seen.current = new Set(saved.filter(id => typeof id === 'string'))
      } catch { /* Storage is optional in private browsing. */ }
    }
    let changed = false
    for (const event of events) {
      if (!titles[event.action] || seen.current.has(event.id)) continue
      const urgent = event.key.toLowerCase() === 'urgent'
      seen.current.add(event.id)
      changed = true
      notifications.show({ id: `air-${actor}-${event.id}`, color: urgent ? 'red' : 'blue',
        title: urgent && event.action === 'SHOW' ? 'قُبل عرض عاجل على الهواء' : titles[event.action],
        message: `${event.key} · الطبقة ${event.layer}`, autoClose: urgent ? 12000 : 7000 })
      if (urgent) void client.invalidateQueries({ queryKey: manualKey, exact: true })
    }
    if (changed) {
      seen.current = new Set(Array.from(seen.current).slice(-128))
      try { sessionStorage.setItem(storageKey, JSON.stringify([...seen.current])) } catch { /* In-memory deduplication still works. */ }
    }
  }, [actor, client, feed.data, storageKey])
  return feed.data?.events == null && (feed.isFetched || feed.isError) ? <UrgentNotice actor={actor} noticeId={noticeId} /> : null
}
