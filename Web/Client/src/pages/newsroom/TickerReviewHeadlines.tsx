import { ScrollArea, Stack, Text, Title } from '@mantine/core'
import classes from './NewsroomPage.module.css'

const number = new Intl.NumberFormat('ar')

export function TickerReviewHeadlines({ title, items }: { title: string; items: string[] }) {
  return (
    <Stack gap="xs">
      <Title order={5}>{title} · {number.format(items.length)}</Title>
      {items.length === 0 ? <Text c="dimmed" size="sm">لا توجد أخبار.</Text> : (
        <ScrollArea.Autosize mah="27vh" type="auto" tabIndex={0} role="region" aria-label={title}>
          <ol className={classes.reviewItems}>
            {items.map((item, index) => <li key={index}><Text size="sm" dir="auto">{item}</Text></li>)}
          </ol>
        </ScrollArea.Autosize>
      )}
    </Stack>
  )
}
