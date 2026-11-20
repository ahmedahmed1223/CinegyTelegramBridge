import { Alert, Button, Group, Modal, NumberInput, Stack, Text, TextInput } from '@mantine/core'
import { notifications } from '@mantine/notifications'
import { IconAlertTriangle, IconSend } from '@tabler/icons-react'
import { useState } from 'react'
import { showTemplate, type TemplateDto } from '../../api/air'
import { messageFor } from '../../api/messages'

interface ShowModalProps {
  template: TemplateDto | null
  opened: boolean
  onClose: () => void
}

export function ShowModal({ template, opened, onClose }: ShowModalProps) {
  const [variables, setVariables] = useState<Record<string, string>>({})
  const [autoHide, setAutoHide] = useState<number | string>(0)
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<string | null>(null)

  if (!template) return null

  const handleFieldChange = (name: string, value: string) => {
    setVariables((prev) => ({ ...prev, [name]: value }))
  }

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    setError(null)

    // Validate required fields
    for (const f of template.fields) {
      if (f.required && !variables[f.name]?.trim()) {
        setError(`حقل "${f.label || f.name}" مطلوب.`)
        return
      }
    }

    setSubmitting(true)
    try {
      await showTemplate({
        key: template.key,
        variables,
        autoHideSeconds: Number(autoHide) || 0,
      })
      notifications.show({
        title: 'على الهواء الآن!',
        message: `تم عرض قالب "${template.name}" على الطبقة ${template.layer} بنجاح.`,
        color: 'teal',
      })
      onClose()
      setVariables({})
    } catch (err: any) {
      setError(messageFor(err.message))
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <Modal
      opened={opened}
      onClose={onClose}
      title={<Text fw={700}>عرض قالب على الهواء: {template.name}</Text>}
      size="md"
      centered
    >
      <form onSubmit={handleSubmit}>
        <Stack gap="md">
          {error && (
            <Alert color="red" icon={<IconAlertTriangle />} title="خطأ">
              {error}
            </Alert>
          )}

          <Text size="xs" c="dimmed">
            الطبقة المستهدفة: <strong className="cgb-mono">{template.layer}</strong>
          </Text>

          {template.fields.length === 0 ? (
            <Text size="sm" c="dimmed">
              هذا القالب لا يحتوي على متغيرات نصية؛ سيُعرض مباشرة على طبقته المحددة.
            </Text>
          ) : (
            template.fields.map((f) => (
              <TextInput
                key={f.name}
                label={f.label || f.name}
                required={f.required}
                maxLength={f.maxLength ?? undefined}
                value={variables[f.name] || ''}
                onChange={(e) => handleFieldChange(f.name, e.currentTarget.value)}
                placeholder={`اكتب ${f.label || f.name}...`}
                dir="auto"
              />
            ))
          )}

          <NumberInput
            label="إخفاء تلقائي بعد (ثوانٍ)"
            description="اتركه 0 للبقاء حتى الإخفاء اليدوي"
            min={0}
            max={86400}
            value={autoHide}
            onChange={(val) => setAutoHide(typeof val === 'number' || typeof val === 'string' ? val : 0)}
          />

          <Group justify="flex-end" mt="md">
            <Button variant="default" onClick={onClose} disabled={submitting}>
              إلغاء
            </Button>
            <Button
              type="submit"
              color="teal"
              loading={submitting}
              leftSection={<IconSend size={16} />}
            >
              عرض على الهواء (SHOW)
            </Button>
          </Group>
        </Stack>
      </form>
    </Modal>
  )
}
