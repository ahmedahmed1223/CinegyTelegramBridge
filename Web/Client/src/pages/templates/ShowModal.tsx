import { Alert, Button, Group, Modal, NumberInput, Stack, Text, TextInput } from '@mantine/core'
import { notifications } from '@mantine/notifications'
import { IconAlertTriangle, IconSend } from '@tabler/icons-react'
import { useState } from 'react'
import { showTemplate, type TemplateDto } from '../../api/air'
import type { Schemas } from '../../api/client'
import { TemplatePresets } from './TemplatePresets'

interface ShowModalProps {
  template: TemplateDto
  onClose: () => void
}

export function ShowModal({ template, onClose }: ShowModalProps) {
  const [variables, setVariables] = useState<Record<string, string>>({})
  const [autoHide, setAutoHide] = useState<number | string>(0)
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [choosingPreset, setChoosingPreset] = useState(false)
  const [preset, setPreset] = useState<{ item: Schemas['TemplatePresetItem']; revision: string } | null>(null)

  const handleFieldChange = (name: string, value: string) => {
    setVariables((prev) => ({ ...prev, [name]: value }))
  }

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    if (submitting) return
    setError(null)

    // Validate required fields
    for (const f of template.fields) {
      const fromPreset = preset?.item.hiddenFields.includes(f.name) && variables[f.name] === undefined
      if (f.required && !fromPreset && !variables[f.name]?.trim()) {
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
        presetIndex: preset?.item.index ?? null,
        presetRevision: preset?.revision ?? null,
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
    <>
    <Modal
      opened={!choosingPreset}
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
          <Group gap="xs">
            <Button type="button" size="compact-sm" variant="light" disabled={submitting} onClick={() => setChoosingPreset(true)}>
              النصوص الجاهزة
            </Button>
            {preset && <>
              <Text size="sm" dir="auto">{preset.item.name}</Text>
              <Button type="button" size="compact-xs" variant="subtle" disabled={submitting}
                onClick={() => { setPreset(null); setVariables({}); setError(null) }}>إزالة النص الجاهز</Button>
            </>}
          </Group>

          {template.fields.length === 0 ? (
            <Text size="sm" c="dimmed">
              هذا القالب لا يحتوي على متغيرات نصية؛ سيُعرض مباشرة على طبقته المحددة.
            </Text>
          ) : (
            template.fields.map((f) => (
              <TextInput
                key={f.name}
                label={f.label || f.name}
                required={f.required && !(preset?.item.hiddenFields.includes(f.name) && variables[f.name] === undefined)}
                type={f.sensitive ? 'password' : 'text'}
                autoComplete={f.sensitive ? 'off' : undefined}
                description={preset?.item.hiddenFields.includes(f.name) && variables[f.name] === undefined
                  ? 'ستُستخدم القيمة الحساسة المحفوظة.' : f.maxLength ? `الحد الأقصى ${f.maxLength} حرفًا` : undefined}
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
    {choosingPreset && <TemplatePresets templateKey={template.key} templateName={template.name}
      onClose={() => setChoosingPreset(false)}
      onChoose={(item, revision) => {
        setPreset({ item, revision })
        setVariables(item.values)
        setError(null)
        setChoosingPreset(false)
      }} />}
    </>
  )
}
