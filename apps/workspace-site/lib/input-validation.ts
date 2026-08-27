import type { JsonSchema } from './tool-registry';

type JsonObject = Record<string, unknown>;

function fail(message: string): never {
  throw new Error(`Invalid tool input: ${message}`);
}

function validateValue(value: unknown, schema: JsonSchema, path: string): void {
  if (schema.type === 'string') {
    if (typeof value !== 'string') fail(`${path} must be text.`);
    if (Array.isArray(schema.enum) && !schema.enum.includes(value)) fail(`${path} is not an allowed value.`);
    return;
  }
  if (schema.type === 'integer') {
    if (!Number.isInteger(value)) fail(`${path} must be a whole number.`);
    const number = value as number;
    if (typeof schema.minimum === 'number' && number < schema.minimum) fail(`${path} is too small.`);
    if (typeof schema.maximum === 'number' && number > schema.maximum) fail(`${path} is too large.`);
    return;
  }
  if (schema.type === 'array') {
    if (!Array.isArray(value)) fail(`${path} must be a list.`);
    if (typeof schema.minItems === 'number' && value.length < schema.minItems) fail(`${path} has too few values.`);
    if (typeof schema.maxItems === 'number' && value.length > schema.maxItems) fail(`${path} has too many values.`);
    if (schema.items && typeof schema.items === 'object') {
      value.forEach((item, index) => validateValue(item, schema.items as JsonSchema, `${path}[${index}]`));
    }
    return;
  }
  if (schema.type === 'object') {
    validateToolArguments(value, schema, path);
  }
}

export function validateToolArguments(value: unknown, schema: JsonSchema, path = 'arguments'): JsonObject {
  if (!value || typeof value !== 'object' || Array.isArray(value)) fail(`${path} must be an object.`);
  const object = value as JsonObject;
  const properties = schema.properties && typeof schema.properties === 'object'
    ? schema.properties as Record<string, JsonSchema>
    : {};
  const required = Array.isArray(schema.required) ? schema.required.map(String) : [];
  for (const key of required) {
    if (object[key] === undefined || object[key] === null || object[key] === '') fail(`${key} is required.`);
  }
  if (schema.additionalProperties === false) {
    for (const key of Object.keys(object)) if (!properties[key]) fail(`${key} is not supported.`);
  }
  for (const [key, item] of Object.entries(object)) {
    if (item === undefined || item === null) continue;
    const propertySchema = properties[key];
    if (propertySchema) validateValue(item, propertySchema, key);
  }
  return object;
}
