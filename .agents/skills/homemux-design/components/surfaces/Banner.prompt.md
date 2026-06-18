Inline notice with icon well, title, message, optional action. Tones: warning, danger, accent, info.

```jsx
<Banner tone="warning" title="Could not connect"
  message="Mosh appears installed, but UDP could not reach this host."
  action={<Button size="small">Reconnect</Button>} />
<Banner tone="accent" icon="clock" title="Trial: 12 days left"
  message="Full access is unlocked during the trial." />
```
