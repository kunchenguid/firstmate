Grouped text field with optional label, leading icon, and footnote. `mono` for commands/session names.

```jsx
<TextField label="Host" value={host} onChange={setHost} placeholder="mac-mini.local" />
<TextField label="Session name" mono value={s} onChange={setS} footnote="Attaches if it exists, or creates it." />
```
