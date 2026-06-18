Inset-grouped list row — the saved-host row. Compose with `IconTile` (leading), `Badge`/`PaletteDots` (trailing), and `chevron`.

```jsx
<ListRow
  leading={<IconTile><Icon name="terminal" /></IconTile>}
  title="Mac mini · claude"
  subtitle="alex@mac-mini.local"
  detail={<><Icon name="rectangle-stack" size={13}/> tmux · claude · Automatic</>}
  trailing={<PaletteDots theme="homemux-dark" />}
  onClick={open}
/>
```
