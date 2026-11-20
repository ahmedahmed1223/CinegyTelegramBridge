import { useQuery } from '@tanstack/react-query'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'

export const manualKey = ['urgent-manual']

export async function sendUrgentManual(body: Pick<Schemas['UrgentManualRequest'], 'action'> & Partial<Schemas['UrgentManualRequest']>) {
  const { data, error, response } = await api.POST('/api/content/urgent/manual', {
    body: { itemId: null, autoHideSeconds: null, review: null, ...body },
  })
  if (!data) throw new Error(error?.message || messageFor(errorCode(error, response)))
  return data
}

export function useUrgentManual() {
  return useQuery({
    queryKey: manualKey,
    retry: false,
    refetchInterval: 4000,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/content/urgent/manual', { signal })
      if (!data) throw new Error(messageFor(errorCode(error, response)))
      return data
    },
  })
}
