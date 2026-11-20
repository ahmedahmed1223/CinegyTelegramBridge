import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { api, errorCode, type Schemas } from '../../api/client'

type Command =
  | { action: 'review'; revision: number; stamp: string }
  | { action: 'start'; revision: number; stamp: string; review: string }
  | { action: 'stop'; runId: string }

const playbackKey = (id: string) => ['bulletin-playback', id] as const

export function useBulletinPlayback(id: string, enabled: boolean) {
  return useQuery<Schemas['BulletinPlayback']>({
    queryKey: playbackKey(id),
    enabled,
    retry: false,
    refetchInterval: ({ state }) => state.data?.run?.state === 'playing' ? 1000 : 4000,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/content/bulletins/playback', { params: { query: { id } }, signal })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })
}

export function usePlaybackCommand(id: string) {
  const client = useQueryClient()
  return useMutation({
    mutationFn: async (change: Command) => {
      const { data, error, response } = await api.POST('/api/content/bulletins/playback', {
        body: { id, revision: null, stamp: null, review: null, runId: null, ...change },
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    onSettled: (result, _, change) => {
      if (change.action === 'review') return
      if (result) client.setQueryData(playbackKey(id), result)
      void client.invalidateQueries({ queryKey: playbackKey(id) })
      void client.invalidateQueries({ queryKey: ['bulletin-editor', id] })
    },
  })
}
