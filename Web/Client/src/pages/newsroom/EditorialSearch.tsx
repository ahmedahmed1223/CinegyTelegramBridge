import { Group, NativeSelect, TextInput } from '@mantine/core'
import { IconSearch } from '@tabler/icons-react'

export type EditorialOrder = 'sequence' | 'title-asc' | 'title-desc'

export function EditorialSearch({ label, sequenceLabel, titleLabel = 'العنوان', search, order, disabled, onSearch, onOrder }: {
  label: string
  sequenceLabel?: string
  titleLabel?: string
  search: string
  order: EditorialOrder
  disabled?: boolean
  onSearch: (search: string) => void
  onOrder: (order: EditorialOrder) => void
}) {
  return <Group grow align="flex-end">
    <TextInput type="search" label={label} dir="rtl" value={search} leftSection={<IconSearch size={16} />}
      disabled={disabled} maxLength={120} onChange={(event) => onSearch(event.currentTarget.value)} />
    <NativeSelect label="ترتيب العرض" value={order} disabled={disabled}
      onChange={(event) => onOrder(event.currentTarget.value as EditorialOrder)} data={[
        ...(sequenceLabel ? [{ value: 'sequence', label: sequenceLabel }] : []),
        { value: 'title-asc', label: `${titleLabel} تصاعديًا` },
        { value: 'title-desc', label: `${titleLabel} تنازليًا` },
      ]} />
  </Group>
}
