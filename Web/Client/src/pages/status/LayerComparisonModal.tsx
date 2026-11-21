import { Alert, Button, Group, Modal, Select, Stack, Text } from '@mantine/core'
import { useMutation, useQuery } from '@tanstack/react-query'
import type { Schemas } from '../../api/client'
import { useState } from 'react'
import { api, errorCode } from '../../api/client'
import { messageFor } from '../../api/messages'
import { formatClock } from '../../lib/time'

const messages: Readonly<Record<string, string>> = {
  forbidden: 'حسابك لا يملك صلاحية فحص الطبقات.',
  layer_comparison_missing: 'الطبقة المحددة لم تعد ضمن طبقات الجسر.',
  layer_comparison_busy: 'يجري فحص الطبقات. أعد المحاولة بعد لحظة.',
  layer_adoption_stale: 'تغيّر المشهد أو سجل الجسر، أو انتهت المراجعة. افحص الطبقة مجددًا.',
  layer_adoption_unavailable: 'لا تتوفر بيانات كافية لإضافة هذا المشهد بأمان إلى سجل الجسر.',
  layer_adoption_save_failed: 'تعذّر حفظ سجل الجسر. أعد الفحص والمراجعة قبل المحاولة مجددًا.',
  layer_forget_stale: 'تغيّرت حالة الطبقة أو سجل الجسر، أو انتهت المراجعة. افحص الطبقة مجددًا.',
  layer_forget_unavailable: 'يتطلّب حذف السجل خلو الطبقة المؤكد وألّا ترتبط بعملية بث أخرى.',
  layer_forget_save_failed: 'تعذّر حفظ سجل الجسر. أعد الفحص والمراجعة قبل المحاولة مجددًا.',
  layer_replacement_stale: 'تغيّر المشهد أو سجل الجسر، أو انتهت المراجعة. افحص الطبقة مجددًا.',
  layer_replacement_unavailable: 'استبدال السجل يتطلّب مشهدًا خارجيًا جديدًا مؤكد الهوية وطبقة بلا عملية بث مرتبطة.',
  layer_replacement_save_failed: 'تعذّر استبدال السجل. بقي السجل القديم كما هو.',
}
const findings: Readonly<Record<string, string>> = {
  add: 'أبلغ Cinegy عن مشهد مسمّى على الطبقة لا يتتبّعه الجسر.',
  remove: 'لم تؤكّد القراءة المشهد الذي يتتبّعه الجسر على هذه الطبقة.',
  update: 'تختلف بيانات المشهد في Cinegy عن سجل الجسر.',
  keep: 'تتوافق القراءة مع سجل الجسر.',
  failed: 'تعذّر التحقق من حالة الطبقة.',
}

type RecordAction = 'adopt' | 'forget' | 'replace'
type RecordReview = (Schemas['LayerAdoptionReview'] | Schemas['LayerForgetReview'] | Schemas['LayerReplacementReview']) & {
  action: RecordAction
  oldTemplateKey?: string
}

const actionLabels = {
  adopt: { review: 'مراجعة الإضافة', confirm: 'تأكيد إضافة المشهد', approved: 'أُضيف المشهد إلى سجل الجسر.',
    title: 'إضافة المشهد إلى سجل الجسر', detail: 'يُحفظ سجل المشهد الحالي فقط ويستمر العرض في Cinegy.' },
  forget: { review: 'مراجعة إزالة السجل', confirm: 'تأكيد إزالة السجل المحلي', approved: 'أُزيل سجل المشهد القديم من الجسر.',
    title: 'إزالة سجل المشهد القديم', detail: 'يُحذف سجل المشهد القديم من سجل الجسر فقط.' },
  replace: { review: 'مراجعة استبدال السجل', confirm: 'تأكيد استبدال السجل المحلي', approved: 'استُبدل السجل المحلي بسجل المشهد الحالي.',
    title: 'استبدال سجل المشهد الخارجي', detail: 'يُنشأ سجل محلي جديد للمشهد الحالي دون نقل ملكية أو تأكيد من السجل القديم. يستمر العرض في Cinegy.' },
} satisfies Record<RecordAction, { review: string; confirm: string; approved: string; title: string; detail: string }>

export function LayerComparisonModal({ onClose }: { onClose: () => void }) {
  const [layer, setLayer] = useState<string | null>(null)
  const catalogue = useQuery({
    queryKey: ['layer-comparison-targets'],
    gcTime: 0,
    retry: false,
    refetchOnWindowFocus: false,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/status/layer-comparison', { signal })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })
  const inspect = useMutation({
    mutationFn: async (selected: number) => {
      const { data, error, response } = await api.GET('/api/status/layer-comparison/{layer}', {
        params: { path: { layer: selected } },
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })
  const prepare = useMutation({
    mutationFn: async ({ layer, action }: { layer: number; action: RecordAction }): Promise<RecordReview> => {
      const path = action === 'adopt' ? '/api/status/layer-comparison/{layer}/adopt/review'
        : action === 'forget' ? '/api/status/layer-comparison/{layer}/forget/review'
          : '/api/status/layer-comparison/{layer}/replace/review'
      const { data, error, response } = await api.POST(path, { params: { path: { layer } } })
      if (!data) throw new Error(errorCode(error, response))
      return { ...data, action }
    },
  })
  const apply = useMutation({
    mutationFn: async (approval: RecordReview) => {
      const path = approval.action === 'adopt' ? '/api/status/layer-comparison/{layer}/adopt/confirm'
        : approval.action === 'forget' ? '/api/status/layer-comparison/{layer}/forget/confirm'
          : '/api/status/layer-comparison/{layer}/replace/confirm'
      const { data, error, response } = await api.POST(path, {
        params: { path: { layer: approval.layer } },
        body: { review: approval.review },
      })
      if (!data) throw new Error(errorCode(error, response))
      const saved = 'adopted' in data ? data.adopted : 'forgotten' in data ? data.forgotten : data.replaced
      if (!saved || data.layer !== approval.layer) throw new Error('bridge_outcome_unknown')
      return approval.action
    },
    onSuccess: () => {
      prepare.reset()
      inspect.reset()
    },
  })
  const result = inspect.data
  const approval = prepare.data
  const busy = inspect.isPending || prepare.isPending || apply.isPending
  const error = apply.error ?? prepare.error ?? catalogue.error ?? inspect.error
  const resetReview = () => {
    prepare.reset()
    apply.reset()
  }
  const canConfirm = approval && (!apply.isError || apply.error.message === 'layer_comparison_busy')
  const availableAction = result?.canReviewReplace ? 'replace'
    : result?.canReviewForget ? 'forget' : result?.disposition === 'add' ? 'adopt' : null
  const finding = result?.disposition === 'ignore'
    ? (result.engineActive ? 'أبلغ Cinegy عن عنصر لم يتعرّف عليه الجسر.' : 'لا يظهر مشهد متتبَّع أو عنصر نشط على الطبقة.')
    : result && (findings[result.disposition] ?? findings.failed)

  return (
    <Modal opened onClose={onClose} title="مقارنة طبقات الهواء"
      closeOnEscape={!apply.isPending} closeOnClickOutside={!apply.isPending} withCloseButton={!apply.isPending}>
      <Stack>
        <Text size="sm">قارن سجل الجسر بقراءة مباشرة من Cinegy للطبقة التي تختارها.</Text>
        <Select label="الطبقة" placeholder="اختر طبقة" value={layer}
          data={catalogue.data?.layers.map((item) => ({ value: String(item.layer), label: item.name ? `${item.name} · ${item.layer}` : `طبقة ${item.layer}` })) ?? []}
          disabled={catalogue.isPending || busy}
          onChange={(value) => { resetReview(); inspect.reset(); setLayer(value) }} />
        {catalogue.isPending && <Text size="sm" role="status">جارٍ تحميل الطبقات…</Text>}
        {error && (
          <Alert color="red" role="alert">{messages[error.message] ?? messageFor(error.message)}</Alert>
        )}
        {result && (
          <Alert color={result.disposition === 'failed' ? 'orange' : 'blue'} role="status" title={finding}>
            <Stack gap={2}>
              <Text size="sm">سجل الجسر {result.tracked ? 'يتتبّع مشهدًا' : 'دون مشهد متتبَّع'}</Text>
              <Text size="sm">
                {result.engineActive === true ? 'Cinegy أبلغ عن عنصر نشط' :
                  result.engineActive === false ? 'Cinegy لم يُبلّغ عن عنصر نشط' : 'حالة Cinegy غير مؤكَّدة'}
              </Text>
              <Text size="xs">وقت القراءة <bdi dir="ltr">{formatClock(result.observedAt)}</bdi></Text>
            </Stack>
          </Alert>
        )}
        {approval && (
          <Alert color={approval.action === 'adopt' ? 'blue' : 'orange'} title={actionLabels[approval.action].title}>
            {approval.oldTemplateKey && <Text size="sm">السجل القديم · {approval.oldTemplateKey}</Text>}
            <Text size="sm">{approval.templateKey} · طبقة {approval.layer}</Text>
            <Text size="sm">{actionLabels[approval.action].detail}</Text>
          </Alert>
        )}
        {apply.data && (
          <Alert color="green" role="status">
            {actionLabels[apply.data].approved}
          </Alert>
        )}
        <Group justify="flex-end">
          {catalogue.isError && <Button variant="default" onClick={() => void catalogue.refetch()}>إعادة تحميل الطبقات</Button>}
          <Button loading={inspect.isPending} disabled={busy || layer === null || catalogue.isError}
            variant={result ? 'default' : 'filled'} onClick={() => {
              resetReview()
              if (layer !== null) inspect.mutate(Number(layer))
            }}>
            {result ? 'إعادة الفحص' : 'فحص الطبقة'}
          </Button>
          {result && availableAction && !approval && (
            <Button loading={prepare.isPending} disabled={busy}
              onClick={() => prepare.mutate({ layer: result.layer, action: availableAction })}>
              {actionLabels[availableAction].review}
            </Button>
          )}
          {canConfirm && (
            <Button loading={apply.isPending} disabled={busy} color={approval.action === 'forget' ? 'red' : undefined}
              onClick={() => apply.mutate(approval)}>
              {actionLabels[approval.action].confirm}
            </Button>
          )}
        </Group>
      </Stack>
    </Modal>
  )
}
