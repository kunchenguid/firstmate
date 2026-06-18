Small capsule label. Quiet by default (12% tinted fill). Used for transport (`SSH`/`Mosh`), the active theme name, and access state.

```jsx
<Badge>SSH</Badge>
<Badge tint="var(--accent)">HomeMux Dark</Badge>
<Badge tint="var(--status-connecting)" variant="tinted">Mosh</Badge>
```

`variant`: tinted | outline | solid. `tint`: any color token.
