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

export async function uploadTickerTxt(file: File, revision: string, review?: string): Promise<Schemas['TickerTxtPreview'] | null> {
  const path = '/api/content/ticker/draft/txt' satisfies keyof paths
  const query = new URLSearchParams({ action: review ? 'apply' : 'preview', revision })
  if (review) query.set('review', review)
  const response = await postBinary(path, query, file, 'ticker_txt_size')
  return response.status === 204 ? null : await response.json() as Schemas['TickerTxtPreview']
}

export async function uploadBulletinPhoto(file: File, id: string, rowId: string | null, revision: number, field?: string): Promise<Schemas['BulletinEditor']> {
  const path = '/api/content/bulletins/photo' satisfies keyof paths
  const query = new URLSearchParams({ id, revision: String(revision) })
  if (rowId === null) query.set('createRow', 'true')
  else query.set('rowId', rowId)
  if (field) query.set('field', field)
  const response = await postBinary(path, query, file, 'bulletin_photo_size')
  return await response.json() as Schemas['BulletinEditor']
}

export async function uploadTemplateRegistry(file: File, review?: string): Promise<Schemas['TemplateRegistryImportReview'] | null> {
  const path = (review ? '/api/air/template-registry/import/confirm' : '/api/air/template-registry/import/review') satisfies keyof paths
  const headers = review ? { 'X-Template-Registry-Review': review } : undefined
  const response = await postBinary(path, new URLSearchParams(), file, 'template_registry_import_size', headers)
  return response.status === 204 ? null : await response.json() as Schemas['TemplateRegistryImportReview']
}

export async function uploadAdminSettingsImport(file: File): Promise<Schemas['WebSettingsImportPreview']> {
  const path = '/api/admin/settings/import/review' satisfies keyof paths
  const response = await postBinary(path, new URLSearchParams(), file, 'settings_import_size', undefined, 'application/json')
  return await response.json() as Schemas['WebSettingsImportPreview']
}

async function postBinary(path: string, query: URLSearchParams, file: File, sizeError: string,
  extraHeaders?: Record<string, string>, contentType = 'application/octet-stream') {
  const target = query.size ? `${path}?${query}` : path
  const response = await fetch(target, {
    method: 'POST',
    credentials: 'same-origin',
    headers: { 'Content-Type': contentType, 'X-XSRF-TOKEN': csrfToken, ...extraHeaders },
    body: file,
  })
  if (response.status === 413) throw new Error(sizeError)
  if (!response.ok) throw new Error(errorCode(await response.json().catch(() => undefined), response))
  return response
}

/** The error code the server sent, or a stand-in for a failure with none. */
export function errorCode(error: unknown, response?: Response): string {
  if (error && typeof error === 'object' && 'error' in error && typeof error.error === 'string') return error.error
  if (response?.status === 429) return 'rate_limited'
  if (response?.status === 401) return 'unauthorized'
  if (response?.status === 403) return 'forbidden'
  return 'unknown'
}
