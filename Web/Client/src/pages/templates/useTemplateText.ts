import { useQuery } from '@tanstack/react-query'
import { api, errorCode } from '../../api/client'
import { useSession } from '../../api/session'

export function useTemplateText(key: string) {
  const actor = useSession().data?.id
  return useQuery({
    queryKey: ['shared-template-text', actor, key],
    enabled: actor != null,
    refetchInterval: 4000, retry: false,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/air/templates/{key}/presets', {
        params: { path: { key }, query: { page: 0 } }, signal,
      })
      if (!data) throw new Error(errorCode(error, response))
      return data.lastValues ?? {}
    },
  })
}
