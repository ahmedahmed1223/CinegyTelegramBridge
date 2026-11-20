import {
  ActionIcon,
  Alert,
  Badge,
  Button,
  Card,
  Group,
  Paper,
  SimpleGrid,
  Skeleton,
  Stack,
  Text,
  TextInput,
  Title,
} from '@mantine/core'
import { useQuery } from '@tanstack/react-query'
import { IconPlayerPlay, IconRefresh, IconSearch } from '@tabler/icons-react'
import { useState } from 'react'
import { getTemplates, type TemplateDto } from '../../api/air'
import { messageFor } from '../../api/messages'
import { ShowModal } from './ShowModal'

export function TemplatesPage() {
  const [search, setSearch] = useState('')
  const [selectedTemplate, setSelectedTemplate] = useState<TemplateDto | null>(null)
  const { data: templates, error, isLoading, refetch, isFetching } = useQuery({
    queryKey: ['templates'],
    queryFn: getTemplates,
  })

  const q = search.trim().toLowerCase()
  const filtered = (templates ?? []).filter((t) => {
    if (!q) return true
    return (
      t.name.toLowerCase().includes(q) ||
      t.key.toLowerCase().includes(q) ||
      (t.category && t.category.toLowerCase().includes(q)) ||
      t.layer.toString() === q
    )
  })

  return (
    <Stack gap="xl">
      <Group justify="space-between" align="flex-end" wrap="wrap">
        <div>
          <Title order={2}>مكتبة القوالب</Title>
          <Text c="dimmed" size="sm">
            اختر قالبًا وجهّز نصه قبل العرض.
          </Text>
        </div>
        <Group gap="xs">
          <ActionIcon
            variant="default"
            size="lg"
            radius="md"
            onClick={() => refetch()}
            loading={isFetching}
            aria-label="تحديث القوالب"
          >
            <IconRefresh size={18} />
          </ActionIcon>
        </Group>
      </Group>

      <TextInput
        aria-label="بحث في القوالب"
        placeholder="الاسم أو التصنيف أو رقم الطبقة"
        leftSection={<IconSearch size={16} />}
        value={search}
        onChange={(e) => setSearch(e.currentTarget.value)}
        size="md"
        radius="md"
      />

      {error ? (
        <Alert color="red" title="تعذّر تحميل القوالب" role="alert">
          <Stack align="flex-start" gap="xs">
            {messageFor(error.message)}
            <Button variant="default" size="xs" onClick={() => refetch()} loading={isFetching}>
              إعادة المحاولة
            </Button>
          </Stack>
        </Alert>
      ) : isLoading ? (
        <SimpleGrid cols={{ base: 1, sm: 2, lg: 3 }} spacing="md">
          <Skeleton h={140} radius="md" />
          <Skeleton h={140} radius="md" />
          <Skeleton h={140} radius="md" />
        </SimpleGrid>
      ) : filtered.length === 0 ? (
        <Paper p="xl" radius="lg" ta="center">
          <Text fw={600}>{q ? 'لا توجد قوالب مطابقة' : 'مكتبة القوالب فارغة'}</Text>
          <Text size="sm" c="dimmed" mt={4}>
            {q ? 'جرّب اسمًا آخر أو رقم الطبقة.' : 'تظهر هنا القوالب المسجّلة في الجسر.'}
          </Text>
        </Paper>
      ) : (
        <SimpleGrid cols={{ base: 1, sm: 2, lg: 3 }} spacing="md">
          {filtered.map((template) => (
            <Card key={template.key} padding="lg" radius="lg" withBorder>
              <Stack justify="space-between" h="100%" gap="md">
                <Stack gap="xs">
                  <Group justify="space-between" align="flex-start" wrap="nowrap">
                    <div>
                      <Text fw={700} size="md" lineClamp={1} title={template.name}>
                        {template.name}
                      </Text>
                      <Text size="xs" c="dimmed" className="cgb-mono">
                        {template.key}
                      </Text>
                    </div>
                    <Badge color="blue" variant="light" size="sm" radius="sm">
                      طبقة {template.layer}
                    </Badge>
                  </Group>

                  <Group gap={6} mt={4}>
                    {template.category && (
                      <Badge variant="outline" color="gray" size="xs">
                        {template.category}
                      </Badge>
                    )}
                    {template.disabled && (
                      <Badge variant="filled" color="red" size="xs">
                        معطّل
                      </Badge>
                    )}
                    <Badge variant="subtle" color="gray" size="xs">
                      {template.fields.length} حقول
                    </Badge>
                  </Group>
                </Stack>

                <Button
                  variant="light"
                  leftSection={<IconPlayerPlay size={16} />}
                  disabled={template.disabled}
                  onClick={() => setSelectedTemplate(template)}
                  fullWidth
                >
                  تجهيز للعرض
                </Button>
              </Stack>
            </Card>
          ))}
        </SimpleGrid>
      )}

      {selectedTemplate && <ShowModal template={selectedTemplate} onClose={() => setSelectedTemplate(null)} />}
    </Stack>
  )
}
