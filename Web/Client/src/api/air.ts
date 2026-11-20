import { api, errorCode } from './client'
import type { Schemas } from './client'

export type TemplateDto = Schemas['TemplateDto']
export type TemplateFieldDto = Schemas['TemplateFieldDto']
export type ShowTemplateRequest = Schemas['ShowTemplateRequest']

export async function getTemplates(): Promise<TemplateDto[]> {
  const { data, error, response } = await api.GET('/api/air/templates')
  if (error || !data) throw new Error(errorCode(error, response))
  return data
}

export async function showTemplate(request: ShowTemplateRequest): Promise<void> {
  const { error, response } = await api.POST('/api/air/show', { body: request })
  if (error) throw new Error(errorCode(error, response))
}

export async function hideLayer(layer: number): Promise<void> {
  const { error, response } = await api.POST('/api/air/hide/{layer}', {
    params: { path: { layer } },
  })
  if (error) throw new Error(errorCode(error, response))
}

export async function exitLayer(layer: number): Promise<void> {
  const { error, response } = await api.POST('/api/air/exit/{layer}', {
    params: { path: { layer } },
  })
  if (error) throw new Error(errorCode(error, response))
}
