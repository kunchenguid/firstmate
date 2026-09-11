// Only the JSON Schema keywords used by this module; new keywords fail closed.
export function validate(value, rule, root = rule, at = 'config') {
  const known = ['$schema', '$defs', '$ref', 'type', 'properties', 'required', 'additionalProperties', 'items', 'minimum', 'maximum', 'enum', 'pattern', 'minLength'];
  if (!rule || Object.keys(rule).some(k => !known.includes(k))) throw Error('Unsupported configuration schema');
  if (rule.$ref) return validate(value, root.$defs?.[rule.$ref.replace('#/$defs/', '')], root, at);
  const type = value === null ? 'null' : Array.isArray(value) ? 'array' : typeof value;
  const invalid = () => { throw Error(`Invalid ${at}`); };
  if (rule.type === 'integer' ? !Number.isInteger(value) : type !== rule.type) invalid();
  if (type === 'number' && (!Number.isFinite(value) || value < (rule.minimum ?? -Infinity) || value > (rule.maximum ?? Infinity))) invalid();
  if (rule.enum && !rule.enum.includes(value)) invalid();
  if (type === 'string' && (value.length < (rule.minLength ?? 0) || (rule.pattern && !new RegExp(rule.pattern).test(value)))) invalid();
  if (type === 'array') value.forEach(v => validate(v, rule.items, root, `${at} item`));
  if (type === 'object') {
    if (rule.required?.some(k => !Object.hasOwn(value, k)) || (rule.additionalProperties === false && Object.keys(value).some(k => !Object.hasOwn(rule.properties, k)))) invalid();
    for (const key of Object.keys(rule.properties ?? {})) if (Object.hasOwn(value, key)) validate(value[key], rule.properties[key], root, `${at}.${key}`);
  }
  return value;
}
