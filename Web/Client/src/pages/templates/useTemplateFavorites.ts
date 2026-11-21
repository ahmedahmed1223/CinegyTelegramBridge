import { notifications } from '@mantine/notifications'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { api, errorCode } from '../../api/client'
import { messageFor } from '../../api/messages'
import { sessionKey } from '../../api/session'

export function useTemplateFavorites(actor: number | undefined) {
  const client = useQueryClient()
  const queryKey = ['template-favorites', actor] as const
  const favorites = useQuery({
    queryKey,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/air/templates/favorites', { signal })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    enabled: actor !== undefined,
    retry: false,
  })
  const toggle = useMutation({
    mutationFn: async ({ key, selected }: { key: string; selected: boolean }) => {
      const { data, error, response } = await api.PUT('/api/air/templates/{key}/favorite', {
        params: { path: { key } }, body: { selected },
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    onMutate: async () => client.cancelQueries({ queryKey }),
    onSuccess: (data) => { client.setQueryData(queryKey, data) },
    onError: (error) => {
      const message = error.message === 'favorite_save_failed'
        ? 'تعذّر حفظ التغيير في المفضّلة.'
        : error.message === 'favorites_disabled' ? 'المفضّلة معطّلة حاليًا.' : messageFor(error.message)
      notifications.show({ color: 'red', message })
      if (['forbidden', 'unauthorized'].includes(error.message)) void client.invalidateQueries({ queryKey: sessionKey })
      void client.invalidateQueries({ queryKey })
    },
  })
  return { favorites, toggle }
}
