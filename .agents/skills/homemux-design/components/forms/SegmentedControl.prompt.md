iOS segmented control. Selected pill slides between options.

```jsx
const [t, setT] = React.useState("automatic");
<SegmentedControl
  options={[{label:"Automatic",value:"automatic"},{label:"SSH",value:"ssh"},{label:"Mosh",value:"mosh"}]}
  value={t} onChange={setT} />
```
