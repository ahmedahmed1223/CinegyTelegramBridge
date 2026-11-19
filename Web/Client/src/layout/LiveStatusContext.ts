import { createContext, useContext } from 'react'
import type { LiveStatus } from '../hooks/useStatusStream'

/** One event stream per tab, opened by the shell and read by every page. */
export const LiveStatusContext = createContext<LiveStatus>({ stream: 'connecting', bridgeOnline: false, status: null })

export function useLiveStatus(): LiveStatus {
  return useContext(LiveStatusContext)
}
