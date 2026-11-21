import {
  ActionIcon,
  Alert,
  Badge,
  Button,
  Card,
  Group,
  Menu,
  Paper,
  SimpleGrid,
  Skeleton,
  Stack,
  Text,
  TextInput,
} from '@mantine/core'
import { useQuery } from '@tanstack/react-query'
import { IconFlask, IconPlayerPlay, IconPlus, IconRefresh, IconSearch, IconSettings } from '@tabler/icons-react'
import { useState } from 'react'
import { getTemplates, type TemplateDto } from '../../api/air'
import { messageFor } from '../../api/messages'
import { isAdmin, useSession } from '../../api/session'
import { PageHeader } from '../../components/PageHeader'
import { ShowModal } from './ShowModal'
import { TemplateIssues } from './TemplateIssues'
import { TemplateBackups } from './TemplateBackups'
import { TemplateRehearsal } from './TemplateRehearsal'
import { TemplateRegistration } from './TemplateRegistration'
import { TemplateDefinitionEditor } from './TemplateDefinitionEditor'
import { TemplateRerun, type TemplateRerunKind } from './TemplateRerun'

export function TemplatesPage() {
  const [search, setSearch] = useState('')
  const [selectedTemplate, setSelectedTemplate] = useState<TemplateDto | null>(null)
  const [trialTemplate, setTrialTemplate] = useState<TemplateDto | null>(null)
  const [registering, setRegistering] = useState(false)
  const [backupsOpen, setBackupsOpen] = useState(false)
  const [issuesOpen, setIssuesOpen] = useState(false)
  const [managingKey, setManagingKey] = useState<string | null>(null)
  const [rerunKind, setRerunKind] = useState<TemplateRerunKind | null>(null)
  const session = useSession()
  const canRehearse = isAdmin(session.data)
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
      <PageHeader title="مكتبة القوالب" description="ابحث عن القالب وجهّز حقوله قبل العرض." actions={
        <Group gap="xs">
          <Button variant="default" onClick={() => setRerunKind('repeat')}>إعادة آخر عرض</Button>
          <Button variant="default" onClick={() => setRerunKind('retry')}>إعادة آخر محاولة</Button>
          {canRehearse && <Menu>
            <Menu.Target><Button variant="default">إدارة السجل</Button></Menu.Target>
            <Menu.Dropdown>
              <Menu.Item leftSection={<IconPlus size={17} />} onClick={() => setRegistering(true)}>تسجيل قالب</Menu.Item>
              <Menu.Item onClick={() => setBackupsOpen(true)}>نسخ القوالب</Menu.Item>
              <Menu.Item onClick={() => setIssuesOpen(true)}>قوالب غير صالحة</Menu.Item>
            </Menu.Dropdown>
          </Menu>}
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
      } />
      {registering && <TemplateRegistration onClose={() => setRegistering(false)} />}
      {issuesOpen && <TemplateIssues onClose={() => setIssuesOpen(false)} />}
      {backupsOpen && <TemplateBackups onClose={() => setBackupsOpen(false)} />}
      {rerunKind && <TemplateRerun key={rerunKind} kind={rerunKind} onClose={() => setRerunKind(null)} />}

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
                    <div style={{ minWidth: 0 }}>
                      <Text fw={700} size="md" lineClamp={1} title={template.name}>
                        {template.name}
                      </Text>
                      <Text size="xs" c="dimmed" className="cgb-mono" style={{ overflowWrap: 'anywhere' }}>
                        {template.key}
                      </Text>
                    </div>
                    <Badge color="blue" variant="light" size="sm" radius="sm" style={{ flexShrink: 0 }}>
                      طبقة {template.layer}
                    </Badge>
                    {canRehearse && <ActionIcon variant="subtle" color="gray" style={{ flexShrink: 0 }}
                      aria-label={`إدارة قالب ${template.name}`} onClick={() => setManagingKey(template.key)}>
                      <IconSettings size={18} />
                    </ActionIcon>}
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

                <Group gap="xs" grow>
                  <Button variant="light" leftSection={<IconPlayerPlay size={16} />} disabled={template.disabled}
                    onClick={() => setSelectedTemplate(template)}>تجهيز للعرض</Button>
                  {canRehearse && <Button variant="default" leftSection={<IconFlask size={16} />}
                    onClick={() => setTrialTemplate(template)}>بروفة</Button>}
                </Group>
              </Stack>
            </Card>
          ))}
        </SimpleGrid>
      )}

      {selectedTemplate && <ShowModal template={selectedTemplate} onClose={() => setSelectedTemplate(null)} />}
      {trialTemplate && <TemplateRehearsal template={trialTemplate} onClose={() => setTrialTemplate(null)} />}
      {managingKey && <TemplateDefinitionEditor templateKey={managingKey} onClose={() => setManagingKey(null)} />}
    </Stack>
  )
}
