import { Alert, Button, Group, Loader, Modal, Stack, Text } from '@mantine/core'
import { notifications } from '@mantine/notifications'
import { useMutation, useQuery } from '@tanstack/react-query'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import { useNow } from '../../hooks/useNow'

export type RemovalOperation = 'hide' | 'exit'

const operationLabel: Record<RemovalOperation, string> = {
  hide: 'إخفاء الطبقة من الهواء',
  exit: 'خروج من حلقة المشهد',
}

const errors: Record<string, string> = {
  layer_removal_stale: 'تغيّر المشهد أو انتهت مهلة المراجعة. راجع الحالة من جديد.',
  layer_removal_ambiguous: 'تعذّر التحقق من جميع المشاهد التي قد يتأثر بها الأمر.',
  layer_removal_unverified: 'تعذّر التحقق من هوية المشهد المعروض ووقت بدئه.',
  layer_removal_refused: 'لم يصل تأكيد قبول الأمر. راجع حالة الطبقة قبل المحاولة.',
}

function removalError(error: Error) {
  return errors[error.message] ?? messageFor(error.message)
}

async function request(layer: number, body: Schemas['AirLayerRemovalCommand'], signal?: AbortSignal) {
  const { data, error, response } = await api.POST('/api/air/layers/{layer}/removal', {
    params: { path: { layer } },
    body,
    signal,
  })
  if (error || !data) throw new Error(errorCode(error, response))
  return data
}

export function LayerRemovalModal({
  layer, operation, onClose,
}: { layer: number; operation: RemovalOperation; onClose: () => void }) {
  const now = useNow()
  const query = useQuery({
    queryKey: ['air-layer-removal-review', layer, operation],
    queryFn: async ({ signal }) => {
      const preview = (await request(layer, { action: 'preview', operation, review: null }, signal)).preview
      if (!preview) throw new Error('layer_removal_unverified')
      return preview
    },
    retry: false,
    gcTime: 0,
    refetchOnWindowFocus: false,
    refetchOnReconnect: false,
  })
  const apply = useMutation({
    mutationFn: async (review: string) => {
      const result = await request(layer, { action: 'apply', operation, review })
      if (!result.sent) throw new Error('layer_removal_refused')
    },
    onSuccess: () => {
      notifications.show({
        title: operation === 'hide' ? 'قُبل أمر الإخفاء' : 'قُبل أمر الخروج',
        message: 'تابع حالة الطبقة في لوحة الهواء.',
        color: 'teal',
      })
      onClose()
    },
  })
  const review = query.data
  const expired = review ? review.expiresAt <= now : false
  const error = apply.error ?? query.error

  return (
    <Modal opened title={operationLabel[operation]} onClose={onClose}
      closeOnClickOutside={!apply.isPending} closeOnEscape={!apply.isPending} withCloseButton={!apply.isPending}>
      <Stack>
        {query.isFetching && <Loader size="sm" aria-label="جاري التحقق من المشهد" />}
        {error && <Alert color="red">{removalError(error)}</Alert>}
        {expired && !apply.isPending && <Alert color="yellow">انتهت مهلة المراجعة.</Alert>}
        {review && <Text size="sm">المشهد <strong>{review.templateKey}</strong> على الطبقة {review.layer}.</Text>}
        <Group justify="end">
          <Button variant="default" disabled={apply.isPending} onClick={onClose}>إلغاء</Button>
          {(error || expired) ? (
            <Button disabled={query.isFetching || apply.isPending} onClick={() => { apply.reset(); void query.refetch() }}>
              راجع المشهد مجددًا
            </Button>
          ) : (
            <Button color={operation === 'hide' ? 'red' : 'orange'} loading={apply.isPending}
              disabled={!review || query.isFetching} onClick={() => { if (review) apply.mutate(review.review) }}>
              {operation === 'hide' ? 'تأكيد الإخفاء' : 'تأكيد الخروج'}
            </Button>
          )}
        </Group>
      </Stack>
    </Modal>
  )
}
