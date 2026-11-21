import { Alert, Button, Group, Modal, Stack, Table, Text, TextInput } from '@mantine/core'
import { useMutation } from '@tanstack/react-query'
import { useState } from 'react'
import { api, errorCode } from '../../api/client'
import { messageFor } from '../../api/messages'

const actions: Record<string, string> = { SHOW: 'عرض', HIDE: 'إخفاء', EXIT: 'خروج المشهد', UPDATE: 'تحديث' }
const results: Record<string, string> = { success: 'نجحت', failed: 'تعذّرت', blocked: 'رُفضت' }
const number = new Intl.NumberFormat('ar')

export function OperationReferenceDialog({ initialReference, onClose }: { initialReference: string; onClose: () => void }) {
  const [reference, setReference] = useState(initialReference)
  const trimmed = reference.trim()
  const valid = /^[0-9a-f]{8}$/i.test(trimmed)
  const lookup = useMutation({
    mutationFn: async (value: string) => {
      const { data, error, response } = await api.GET('/api/history/operation-reference', { params: { query: { reference: value } } })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })
  const match = lookup.data
  return (
    <Modal opened title="البحث بمرجع العملية" onClose={onClose} size="lg">
      <Stack>
        <form onSubmit={(event) => { event.preventDefault(); if (valid && !lookup.isPending) lookup.mutate(trimmed) }}>
          <Stack gap="sm">
            <TextInput label="مرجع العملية" description="أدخل الرمز المكوّن من ٨ خانات كما ظهر في الرسالة."
              value={reference} onChange={(event) => { setReference(event.currentTarget.value); lookup.reset() }}
              placeholder="5023333b" dir="ltr" spellCheck={false} autoFocus disabled={lookup.isPending} />
            <Group justify="flex-end">
              <Button variant="default" onClick={onClose}>إغلاق</Button>
              <Button type="submit" loading={lookup.isPending} disabled={!valid}>بحث</Button>
            </Group>
          </Stack>
        </form>
        {lookup.error && <Alert color="red" role="alert">{lookup.error.message === 'operation_reference_invalid'
          ? 'أدخل الرمز المكوّن من ٨ خانات.' : messageFor(lookup.error.message)}</Alert>}
        {match?.status === 'collision' && <Alert color="orange" role="status">يطابق هذا المرجع أكثر من عملية ضمن السجل المقروء.</Alert>}
        {match?.status === 'missing' && <Text role="status">لا توجد عملية بهذا المرجع ضمن أحدث {number.format(match.readLimit)} سجل.</Text>}
        {match?.status === 'found' && (
          <Table.ScrollContainer minWidth={530} tabIndex={0} aria-label="تفاصيل العملية">
            <Table>
              <Table.Thead><Table.Tr>
                <Table.Th>وقت المحطة</Table.Th><Table.Th>العملية</Table.Th><Table.Th>الطبقة</Table.Th>
                <Table.Th>النتيجة</Table.Th><Table.Th>المدة</Table.Th>
              </Table.Tr></Table.Thead>
              <Table.Tbody>
                {match.items.map((item, index) => (
                  <Table.Tr key={`${item.atMs}:${index}`}>
                    <Table.Td><bdi dir="ltr">{item.stationTime}</bdi></Table.Td>
                    <Table.Td>{actions[item.action]}</Table.Td><Table.Td>{item.layer || '—'}</Table.Td>
                    <Table.Td>{results[item.result]}</Table.Td><Table.Td>{number.format(item.durationMs)} ملّي ثانية</Table.Td>
                  </Table.Tr>
                ))}
              </Table.Tbody>
            </Table>
          </Table.ScrollContainer>
        )}
        {match?.truncated && match.status === 'found' && <Text c="dimmed" size="sm">تظهر أحدث النتائج المتاحة ضمن حد القراءة.</Text>}
      </Stack>
    </Modal>
  )
}
