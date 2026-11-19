import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useCallback } from 'react'
import { api, setCsrfToken, type CurrentUser } from './client'

export const sessionKey = ['session'] as const

/** Who is signed in, or null. Also refreshes the anti-forgery token. */
export function useSession() {
  return useQuery({
    queryKey: sessionKey,
    queryFn: async (): Promise<CurrentUser | null> => {
      const { data, error } = await api.GET('/api/session')
      if (error || !data) throw new Error('session')
      setCsrfToken(data.csrfToken)
      return data.user ?? null
    },
    staleTime: 60_000,
  })
}

/** Stable across renders: pages that tick every second depend on it. */
export function useRefreshSession() {
  const client = useQueryClient()
  return useCallback(() => client.invalidateQueries({ queryKey: sessionKey }), [client])
}

export function isAdmin(user: CurrentUser | null | undefined): boolean {
  return user?.role === 'admin' || user?.role === 'owner'
}

export const roleLabel: Record<string, string> = {
  owner: 'المالك',
  admin: 'مشرف',
  operator: 'مشغّل',
  none: 'بلا صلاحية',
}
