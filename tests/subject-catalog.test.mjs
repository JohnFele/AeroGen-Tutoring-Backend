import { test } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import { subjectCatalog } from '../src/data/subjectCatalog.js'

test('bundled frontend catalogue matches the canonical database seed', () => {
  const snapshot = JSON.parse(fs.readFileSync(new URL('../../../Frontend/AeroGen-Tutoring/src/data/subjectCatalog.json', import.meta.url), 'utf8'))
  assert.deepEqual(snapshot, subjectCatalog)
})

test('catalogue has unique stable names/slugs, valid categories, and one or more valid levels', () => {
  const { categories, levels, subjects } = subjectCatalog
  assert(subjects.length > 400)
  assert.equal(new Set(subjects.map(subject => subject.name)).size, subjects.length)
  assert.equal(new Set(subjects.map(subject => subject.slug)).size, subjects.length)
  const categorySlugs = new Set(categories.map(category => category.slug))
  const levelCodes = new Set(levels.map(level => level.code))
  for (const subject of subjects) {
    assert(categorySlugs.has(subject.category), subject.name)
    assert(subject.levels.length > 0, subject.name)
    assert(subject.levels.every(level => levelCodes.has(level)), subject.name)
    assert.equal(new Set(subject.levels).size, subject.levels.length)
    assert(subject.name.length <= 100, subject.name)
    assert.match(subject.slug, /^[a-z0-9]+(?:-[a-z0-9]+)*$/)
  }
})

test('all previously seeded subjects remain available, preserving names and slugs for existing references', () => {
  const seed = fs.readFileSync(new URL('../supabase/migrations/20261023162155_catalog_indexes_security.sql', import.meta.url), 'utf8')
  const previous = [...seed.matchAll(/\('([^']+)', '[^']+', '([^']+)'\)/g)]
  assert.equal(previous.length, 53)
  for (const [, name, slug] of previous) {
    const subject = subjectCatalog.subjects.find(subject => subject.name === name)
    assert(subject, `Missing original subject: ${name}`)
    assert.equal(subject.slug, slug, name)
  }
})

test('coverage spans primary, secondary, TVET, and major university disciplines', () => {
  for (const [name, level] of [['Phonics','foundation'],['Life Skills','intermediate'],['Economic & Management Sciences','senior'],['Mathematical Literacy','fet'],['Electrical Trade Theory','college'],['Linear Algebra','undergraduate'],['Nursing','undergraduate'],['Constitutional Law','undergraduate'],['Research Methodology','postgraduate']]) {
    assert(subjectCatalog.subjects.find(subject => subject.name === name)?.levels.includes(level), `${name} at ${level}`)
  }
  for (const language of ['English','Afrikaans','isiZulu','isiXhosa','Sesotho','Setswana','Sepedi','Siswati','Tshivenda','Xitsonga','isiNdebele','South African Sign Language']) {
    assert(subjectCatalog.subjects.some(subject => subject.name === `${language} Home Language`), language)
  }
})
