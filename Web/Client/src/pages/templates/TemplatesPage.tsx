import {
  ActionIcon,
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
import { ShowModal } from './ShowModal'

export function TemplatesPage() {
  const [search, setSearch] = useState('')
  const [selectedTemplate, setSelectedTemplate] = useState<TemplateDto | null>(null)
  const [modalOpened, setModalOpened] = useState(false)

  const { data: templates, isLoading, refetch, isFetching } = useQuery({
    queryKey: ['templates'],
    queryFn: getTemplates,
  })

  const filtered = (templates || []).filter((t) => {
    const q = search.trim().toLowerCase()
    if (!q) return true
    return (
      t.name.toLowerCase().includes(q) ||
      t.key.toLowerCase().includes(q) ||
      (t.category && t.category.toLowerCase().includes(q)) ||
      t.layer.toString() === q
    )
  })

  const handleOpenShow = (template: TemplateDto) => {
    setSelectedTemplate(template)
    setModalOpened(true)
  }

  return (
    <Stack gap="xl">
      <Group justify="space-between" align="flex-end" wrap="wrap">
        <div>
          <Title order={2}>مكتبة القوالب</Title>
          <Text c="dimmed" size="sm">
            عرض وتشغيل قوالب الرسوم والمشاهد على الهواء مباشرة.
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
        placeholder="ابحث باسم القالب أو المعرّف أو التصنيف أو رقم الطبقة..."
        leftSection={<IconSearch size={16} />}
        value={search}
        onChange={(e) => setSearch(e.currentTarget.value)}
        size="md"
        radius="md"
      />

      {isLoading ? (
        <SimpleGrid cols={{ base: 1, sm: 2, lg: 3 }} spacing="md">
          <Skeleton h={140} radius="md" />
          <Skeleton h={140} radius="md" />
          <Skeleton h={140} radius="md" />
        </SimpleGrid>
      ) : filtered.length === 0 ? (
        <Paper p="xl" radius="lg" ta="center">
          <Text fw={600}>لا توجد قوالب مطابقة</Text>
          <Text size="sm" c="dimmed" mt={4}>
            لم يُعثر على قوالب تطابق البحث أو لم يتم تسجيل قوالب في templates.json بعد.
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
                  color="teal"
                  variant="light"
                  leftSection={<IconPlayerPlay size={16} />}
                  disabled={template.disabled}
                  onClick={() => handleOpenShow(template)}
                  fullWidth
                >
                  عرض على الهواء
                </Button>
              </Stack>
            </Card>
          ))}
        </SimpleGrid>
      )}

      <ShowModal
        template={selectedTemplate}
        opened={modalOpened}
        onClose={() => {
          setModalOpened(false)
          setSelectedTemplate(null)
        }}
      />
    </Stack>
  )
}
