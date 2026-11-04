import {IntlMessageFormat} from 'intl-messageformat';

// Kolibri's generated English ICU messages, with the same translator surface
// consumed by its unchanged wrapPerseusMessages helper.
export function createTranslator(name, source) {
  const messages = Object.fromEntries(Object.entries(source).map(([key, value]) => [key, typeof value === 'string' ? value : value.message]));
  const translator = {_defaultMessages: messages};
  for (const [key, value] of Object.entries(messages)) {
    let formatter;
    translator[`${key}$`] = (values = {}) => {
      formatter ||= new IntlMessageFormat(value, 'en', undefined, {ignoreTag: true});
      return String(formatter.format(values));
    };
  }
  return translator;
}
export const logger = {error: (...args) => console.error(...args), warn: (...args) => console.warn(...args), debug: () => {}, info: () => {}};
export const logging = {getLogger: () => logger};
export const urls = {static: path => new URL(path.replace(/^assets\//, ''), 'nomad-perseus://local/renderer/').href};
