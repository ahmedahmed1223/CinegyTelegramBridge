import { Alert, Button, Checkbox, Group, Modal, Radio, Skeleton, Stack, Text, Title } from '@mantine/core'
import { notifications } from '@mantine/notifications'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import { isAdmin, sessionKey, useSession } from '../../api/session'

type Scope = Schemas['HideAllLayerScopeView']
type Review = Schemas['HideAllScopePreview']
type Mode = 'all' | 'selected' | 'none'
const number = new Intl.NumberFormat('ar')

function scopeMode(mode: string): Mode {
  return mode === 'all' || mode === 'selected' ? mode : 'none'
}

function scopeError(code: string) {
  switch (code) {
    case 'hide_all_scope_invalid': return 'اختر نطاقًا صالحًا من الطبقات المعروفة.'
    case 'hide_all_scope_unchanged': return 'هذا هو النطاق الحالي.'
    case 'hide_all_scope_stale': return 'تغيّر النطاق أو قائمة الطبقات، أو انتهت المراجعة.'
    case 'hide_all_scope_save_failed': return 'تعذّر الحفظ. بقي نطاق الإخفاء السابق قائمًا.'
    default: return messageFor(code)
  }
}

function ScopeSummary({ mode, selected, available }: { mode: string; selected: number[]; available: Scope['knownLayers'] }) {
  if (mode === 'none') return <Text>بلا طبقات</Text>
  const labels = selected.map((id) => {
    const layer = available.find((option) => option.id === id)
    return layer?.name ? `${number.format(id)} · ${layer.name}` : number.format(id)
  })
  return (
    <Stack gap={2}>
      {mode === 'all' && <Text fw={600}>كل الطبقات المعروفة</Text>}
      <Text size="sm"><bdi>{labels.join('، ')}</bdi></Text>
    </Stack>
  )
}

export function HideAllLayerScopeModal({ onClose }: { onClose: () => void }) {
  const session = useSession()
  const key = ['hide-all-layer-scope', session.data?.id] as const
  const query = useQuery({
    queryKey: key,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/air/emergency-hide/scope', { signal })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    enabled: !!session.data,
    retry: false,
    gcTime: 0,
  })
  if (!query.data || query.isError) {
    return (
      <Modal opened title="نطاق إخفاء الكل" onClose={onClose} dir="rtl">
        {query.error ? <Alert color="orange">{scopeError(query.error.message)}</Alert> : <Skeleton height={100} />}
      </Modal>
    )
  }
  return <HideAllLayerScopeForm key={query.data.revision} scope={query.data} canManage={isAdmin(session.data) && query.data.canManage}
    queryKey={key} reload={() => void query.refetch()} onClose={onClose} />
}

function HideAllLayerScopeForm({ scope, canManage, queryKey, reload, onClose }: {
  scope: Scope; canManage: boolean; queryKey: readonly unknown[]; reload: () => void; onClose: () => void
}) {
  const client = useQueryClient()
  const [mode, setMode] = useState<Mode>(scopeMode(scope.mode))
  const [layers, setLayers] = useState(scope.selectedLayers.map(String))
  const [preview, setPreview] = useState<Review | null>(null)
  const [failure, setFailure] = useState('')

  function fail(error: Error) {
    setFailure(error.message)
    setPreview(null)
    if (['forbidden', 'unauthorized'].includes(error.message)) void client.invalidateQueries({ queryKey: sessionKey })
  }

  const checking = useMutation({
    mutationFn: async () => {
      const { data, error, response } = await api.POST('/api/air/emergency-hide/scope/review', {
        body: { revision: scope.revision, mode, ...(mode === 'selected' ? { layers: layers.map(Number) } : {}) },
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    onSuccess: setPreview,
    onError: fail,
  })
  const saving = useMutation({
    mutationFn: async (decision: Review) => {
      const { data, error, response } = await api.POST('/api/air/emergency-hide/scope/confirm', { body: { review: decision.review } })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    onSuccess: (data) => {
      client.setQueryData(queryKey, data)
      notifications.show({ color: 'teal', message: 'حُفظ نطاق إخفاء الكل.' })
      onClose()
    },
    onError: fail,
  })
  const busy = checking.isPending || saving.isPending

  return (
    <Modal opened title="نطاق إخفاء الكل" onClose={() => { if (!busy) onClose() }}
      withCloseButton={!busy} closeOnClickOutside={!busy} closeOnEscape={!busy} dir="rtl">
      <Stack gap="md">
        {!scope.enabled && <Alert color="yellow">إخفاء الكل معطّل حاليًا.</Alert>}
        {failure && <Alert color="orange" role="alert">
          <Stack gap="xs">
            {scopeError(failure)}
            {failure === 'hide_all_scope_stale' && <Button variant="default" size="xs" onClick={reload}>تحميل النطاق الحالي</Button>}
          </Stack>
        </Alert>}
        <div>
          <Title order={3} size="h5" mb={4}>النطاق الحالي</Title>
          <ScopeSummary mode={scope.mode} selected={scope.selectedLayers} available={scope.knownLayers} />
        </div>
        {canManage && (preview ? (
          <>
            <div>
              <Title order={3} size="h5" mb={4}>النطاق بعد الحفظ</Title>
              <ScopeSummary mode={preview.mode} selected={preview.selectedLayers} available={preview.current.knownLayers} />
            </div>
            <Group justify="end">
              <Button variant="default" disabled={busy} onClick={() => setPreview(null)}>رجوع</Button>
              <Button loading={saving.isPending} onClick={() => saving.mutate(preview)}>تأكيد حفظ النطاق</Button>
            </Group>
          </>
        ) : (
          <>
            <Radio.Group label="النطاق الجديد" value={mode} onChange={(value) => setMode(scopeMode(value))}>
              <Stack gap="xs" mt="xs">
                <Radio value="all" label="كل الطبقات المعروفة" description="يشمل الطبقات التي تُعرّف لاحقًا." disabled={busy} />
                <Radio value="selected" label="طبقات محددة" disabled={busy} />
                <Radio value="none" label="بلا طبقات" disabled={busy} />
              </Stack>
            </Radio.Group>
            {mode === 'selected' && (
              <Checkbox.Group label="الطبقات المستهدفة" value={layers} onChange={setLayers}>
                <Stack gap={5} mt="xs">
                  {scope.knownLayers.map((layer) => (
                    <Checkbox key={layer.id} value={String(layer.id)} disabled={busy}
                      label={<bdi>{layer.name ? `${number.format(layer.id)} · ${layer.name}` : number.format(layer.id)}</bdi>} />
                  ))}
                </Stack>
              </Checkbox.Group>
            )}
            <Group justify="end">
              <Button loading={checking.isPending} disabled={mode === 'selected' && !layers.length}
                onClick={() => { setFailure(''); checking.mutate() }}>مراجعة النطاق</Button>
            </Group>
          </>
        ))}
      </Stack>
    </Modal>
  )
}
