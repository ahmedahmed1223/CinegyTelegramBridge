import { Alert, Button, Group, Modal, NumberInput, Stack, Text, TextInput } from '@mantine/core'
import { notifications } from '@mantine/notifications'
import { IconAlertTriangle, IconSend } from '@tabler/icons-react'
import { useState } from 'react'
import { showTemplate, type TemplateDto } from '../../api/air'

interface ShowModalProps {
  template: TemplateDto
  onClose: () => void
}

export function ShowModal({ template, onClose }: ShowModalProps) {
  const [variables, setVariables] = useState<Record<string, string>>({})
  const [autoHide, setAutoHide] = useState<number | string>(0)
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const handleFieldChange = (name: string, value: string) => {
    setVariables((prev) => ({ ...prev, [name]: value }))
  }

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    if (submitting) return
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
        title: 'قُبل أمر العرض',
        message: `تابع القالب «${template.name}» على الطبقة ${template.layer} في لوحة الهواء.`,
        color: 'teal',
      })
      onClose()
    } catch (err) {
      setError(err instanceof Error ? err.message : 'تعذّر إرسال أمر العرض.')
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <Modal
      opened
      onClose={submitting ? () => {} : onClose}
      withCloseButton={!submitting}
      closeOnEscape={!submitting}
      closeOnClickOutside={!submitting}
      title={<Text fw={700}>{template.name}</Text>}
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
            الطبقة المستهدفة <strong className="cgb-mono">{template.layer}</strong>
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
                description={f.maxLength ? `الحد الأقصى ${f.maxLength} حرفًا` : undefined}
                disabled={submitting}
                value={variables[f.name] || ''}
                onChange={(e) => handleFieldChange(f.name, e.currentTarget.value)}
                placeholder={`اكتب ${f.label || f.name}...`}
                dir="auto"
              />
            ))
          )}

          <NumberInput
            label="إخفاء تلقائي بعد (ثوانٍ)"
            description="الصفر يترك مدة العرض لسياسة القالب"
            disabled={submitting}
            allowDecimal={false}
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
              color="red"
              loading={submitting}
              leftSection={<IconSend size={16} />}
            >
              عرض على الهواء
            </Button>
          </Group>
        </Stack>
      </form>
    </Modal>
  )
}
