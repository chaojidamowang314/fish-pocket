#!/usr/bin/env node
// Translation coverage of the app's String Catalogs: strings-coverage.mjs [language]
// Without an argument, one line per language; with one, also every string it lacks.
// Plain Node, no Xcode: the catalogs are JSON, so a contributor without a Mac can check a translation.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const catalogs = ['app/Shared/Localizable.xcstrings', 'app/DshIOS/InfoPlist.xcstrings'];
const only = process.argv[2];

/** A localization counts when it has a translated value, or plural / device variations that all do. */
function translated(unit) {
  if (!unit) return false;
  if (unit.stringUnit) return unit.stringUnit.state === 'translated';
  const groups = Object.values(unit.variations ?? {});
  return groups.length > 0 && groups.every((group) => Object.values(group).every(translated));
}

/** The languages the app declares (`CFBundleLocalizations` in app/project.yml). */
const declared = readFileSync(root + 'app/project.yml', 'utf8').match(/CFBundleLocalizations:\s*\[([^\]]*)\]/)?.[1]
  .split(',').map((code) => code.trim()).filter(Boolean) ?? [];

let failed = false;
for (const path of catalogs) {
  const catalog = JSON.parse(readFileSync(root + path, 'utf8'));
  const keys = Object.entries(catalog.strings).filter(([, entry]) => entry.shouldTranslate !== false && entry.extractionState !== 'stale');
  const languages = new Set(declared);
  for (const [, entry] of keys) for (const language of Object.keys(entry.localizations ?? {})) languages.add(language);
  languages.delete(catalog.sourceLanguage);
  if (only) languages.add(only);
  console.log(`${path}: ${keys.length} strings, source ${catalog.sourceLanguage}`);
  for (const language of [...languages].sort()) {
    if (only && language !== only) continue;
    const missing = keys.filter(([, entry]) => !translated(entry.localizations?.[language]));
    console.log(`  ${language}: ${keys.length - missing.length}/${keys.length}`);
    if (only) for (const [key] of missing) console.log(`    ${JSON.stringify(key)}`);
    if (missing.length) failed = true;
  }
}
process.exitCode = only && failed ? 1 : 0;
