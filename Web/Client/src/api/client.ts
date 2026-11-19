import createClient, { type Middleware } from 'openapi-fetch'
import type { components, paths } from './schema'

export type Schemas = components['schemas']
export type CurrentUser = NonNullable<Schemas['CurrentUser']>
export type BridgeStatus = NonNullable<Schemas['BridgeStatus']>
export type LayerStatus = Schemas['LayerStatus']
export type StatusEnvelope = Schemas['StatusEnvelope']

// The anti-forgery token from GET /api/session. Bound to the signed-in user,
// so the session query replaces it after every sign-in and sign-out.
let csrfToken = ''

export function setCsrfToken(token: string) {
  csrfToken = token
}

const csrf: Middleware = {
  onRequest({ request }) {
    if (request.method !== 'GET' && csrfToken) request.headers.set('X-XSRF-TOKEN', csrfToken)
    return request
  },
}

export const api = createClient<paths>({ baseUrl: '/', credentials: 'same-origin' })
api.use(csrf)

/** The error code the server sent, or a stand-in for a failure with none. */
export function errorCode(error: unknown, response?: Response): string {
  if (error && typeof error === 'object' && 'error' in error && typeof error.error === 'string') return error.error
  if (response?.status === 429) return 'rate_limited'
  if (response?.status === 401) return 'unauthorized'
  if (response?.status === 403) return 'forbidden'
  return 'unknown'
}
