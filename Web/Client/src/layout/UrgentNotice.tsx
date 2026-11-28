import { Anchor, Stack, Text } from '@mantine/core'
import { notifications } from '@mantine/notifications'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useRef } from 'react'
import { api, errorCode } from '../api/client'
import { manualKey } from '../pages/newsroom/urgentManualApi'

export function UrgentNotice({ actor, noticeId }: { actor?: number | null; noticeId?: string | null }) {
  const client = useQueryClient()
  const lastNotice = useRef('')
  const notice = useQuery({
    queryKey: ['urgent-notice', actor, noticeId],
    enabled: actor != null && !!noticeId,
    staleTime: Infinity,
    gcTime: 60_000,
    retry: false,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/content/urgent/manual', { signal })
      if (!data) throw new Error(errorCode(error, response))
      return { id: data.noticeId ?? '', headline: data.noticeHeadline }
    },
  })

  useEffect(() => {
    if (actor == null || !noticeId || notice.data === undefined) return
    const key = `${actor}:${noticeId}`
    if (lastNotice.current === key) return
    lastNotice.current = key
    void client.invalidateQueries({ queryKey: manualKey, exact: true })
    if (notice.data.id !== noticeId) return
    notifications.show({
      id: `urgent-${key}`,
      title: 'عُرض عاجل على الهواء',
      color: 'red',
      message: <Stack gap={4}>
        <Text size="sm" dir="auto">{notice.data.headline || 'أكّد Cinegy عرض العاجل.'}</Text>
        <Anchor href="/newsroom?section=urgent" size="sm">افتح العواجل</Anchor>
      </Stack>,
    })
  }, [actor, client, notice.data, noticeId])

  return null
}
