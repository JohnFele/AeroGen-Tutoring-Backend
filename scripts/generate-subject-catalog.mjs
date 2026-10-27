import fs from 'node:fs'
import { fileURLToPath } from 'node:url'
import { subjectCatalog } from '../src/data/subjectCatalog.js'

const quote = value => `'${value.replaceAll("'", "''")}'`
const json = value => `${quote(JSON.stringify(value))}::jsonb`
const output = fileURLToPath(new URL('../../../Frontend/AeroGen-Tutoring/src/data/subjectCatalog.json', import.meta.url))
const snapshot = `${JSON.stringify(subjectCatalog, null, 2)}\n`
if (process.argv.includes('--check')) {
  if (fs.readFileSync(output, 'utf8') !== snapshot) throw new Error('Regenerate the frontend subject catalogue snapshot.')
} else {
  fs.writeFileSync(output, snapshot)
}

// The generated SQL is reviewed and applied through Supabase's migration tool.
// On success, save it under the version returned by remote migration history.
export const catalogMigration = `-- Expanded school-to-university subject catalogue.
-- Generated from src/data/subjectCatalog.js. Existing subject IDs are retained.
create table public.subject_categories (
  slug text primary key check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name text not null unique check (length(btrim(name)) > 0),
  emoji text not null default '📚',
  sort_order integer not null default 0 check (sort_order >= 0),
  is_active boolean not null default true
);
create table public.education_levels (
  code text primary key check (code ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name text not null unique check (length(btrim(name)) > 0),
  min_grade smallint,
  max_grade smallint,
  sort_order integer not null default 0 check (sort_order >= 0),
  is_active boolean not null default true,
  constraint education_levels_grade_range check (
    (min_grade is null and max_grade is null) or
    (min_grade is not null and max_grade is not null and min_grade >= 0 and max_grade <= 12 and min_grade <= max_grade)
  )
);
alter table public.subjects
  add column aliases text[] not null default '{}',
  add column is_popular boolean not null default false,
  add column sort_order integer not null default 0 check (sort_order >= 0);
create table public.subject_education_levels (
  subject_id bigint not null references public.subjects(id) on delete cascade,
  level_code text not null references public.education_levels(code) on update cascade on delete restrict,
  primary key (subject_id, level_code)
);
create index subject_education_levels_level_idx on public.subject_education_levels (level_code, subject_id);
create index subjects_category_idx on public.subjects (category);

insert into public.subject_categories (slug, name, emoji, sort_order)
select slug, name, emoji, sort_order
from jsonb_to_recordset(${json(subjectCatalog.categories)}) as c(slug text, name text, emoji text, sort_order integer);
insert into public.education_levels (code, name, min_grade, max_grade, sort_order)
select code, name, min_grade, max_grade, sort_order
from jsonb_to_recordset(${json(subjectCatalog.levels)}) as l(code text, name text, min_grade smallint, max_grade smallint, sort_order integer);

with seed as (
  select * from jsonb_to_recordset(${json(subjectCatalog.subjects)})
  as s(name text, slug text, category text, aliases text[], is_popular boolean, sort_order integer)
)
insert into public.subjects (name, slug, category, aliases, is_popular, sort_order)
select s.name, s.slug, c.name, s.aliases, s.is_popular, s.sort_order
from seed s join public.subject_categories c on c.slug = s.category
on conflict (name) do update set
  category = excluded.category,
  aliases = excluded.aliases,
  is_popular = excluded.is_popular,
  sort_order = excluded.sort_order;

-- Retain any institution-specific subjects that were added outside the seed.
insert into public.subject_categories (slug, name, sort_order)
select distinct 'legacy-' || md5(s.category), s.category, 1000
from public.subjects s where not exists (select 1 from public.subject_categories c where c.name = s.category);
alter table public.subjects add constraint subjects_category_fk
  foreign key (category) references public.subject_categories(name) on update cascade on delete restrict;

with seed as (
  select * from jsonb_to_recordset(${json(subjectCatalog.subjects.map(subject => ({ name: subject.name, levels: subject.levels })))}) as s(name text, levels text[])
)
insert into public.subject_education_levels (subject_id, level_code)
select subject.id, unnest(seed.levels) from seed join public.subjects subject on subject.name = seed.name
on conflict do nothing;

alter table public.subject_categories enable row level security;
alter table public.education_levels enable row level security;
alter table public.subject_education_levels enable row level security;
revoke all on public.subject_categories, public.education_levels, public.subject_education_levels from public, anon, authenticated;
grant select on public.subject_categories, public.education_levels, public.subject_education_levels to anon, authenticated;
create policy "Active subject categories are public" on public.subject_categories
  for select to anon, authenticated using (is_active);
create policy "Active education levels are public" on public.education_levels
  for select to anon, authenticated using (is_active);
create policy "Active subject level mappings are public" on public.subject_education_levels
  for select to anon, authenticated using (
    exists (select 1 from public.subjects s where s.id = subject_id and s.is_active)
    and exists (select 1 from public.education_levels l where l.code = level_code and l.is_active)
  );
comment on table public.subject_categories is 'Extensible subject categories; public read-only, managed by trusted migrations.';
comment on table public.education_levels is 'School phases and tertiary learning stages; Grade R is represented as grade 0. Tags are guidance, not programme accreditation.';
comment on table public.subject_education_levels is 'Many-to-many subject-to-level mapping; one subject can be taught at several education levels.';
comment on column public.subjects.is_popular is 'Editorial discovery ordering; does not assert booking demand or tutor availability.';
comment on column public.subjects.aliases is 'Alternative names and abbreviations for catalogue search.';
notify pgrst, 'reload schema';
`

const sqlIndex = process.argv.indexOf('--sql-output')
if (sqlIndex !== -1) fs.writeFileSync(process.argv[sqlIndex + 1], catalogMigration)
const seedIndex = process.argv.indexOf('--seed-output')
if (seedIndex !== -1) {
  // Subsequent catalogue expansions must not rerun the one-time schema DDL.
  const seed = `-- Additive catalogue refresh; preserve subject IDs and custom level links.
insert into public.subject_categories (slug,name,emoji,sort_order)
select slug,name,emoji,sort_order from jsonb_to_recordset(${json(subjectCatalog.categories)}) as c(slug text,name text,emoji text,sort_order integer)
on conflict (slug) do update set name=excluded.name, emoji=excluded.emoji, sort_order=excluded.sort_order;
insert into public.education_levels (code,name,min_grade,max_grade,sort_order)
select code,name,min_grade,max_grade,sort_order from jsonb_to_recordset(${json(subjectCatalog.levels)}) as l(code text,name text,min_grade smallint,max_grade smallint,sort_order integer)
on conflict (code) do update set name=excluded.name,min_grade=excluded.min_grade,max_grade=excluded.max_grade,sort_order=excluded.sort_order;
with seed as (select * from jsonb_to_recordset(${json(subjectCatalog.subjects)}) as s(name text,slug text,category text,aliases text[],is_popular boolean,sort_order integer))
insert into public.subjects (name,slug,category,aliases,is_popular,sort_order)
select s.name,s.slug,c.name,s.aliases,s.is_popular,s.sort_order from seed s join public.subject_categories c on c.slug=s.category
on conflict (name) do update set category=excluded.category,aliases=excluded.aliases,is_popular=excluded.is_popular,sort_order=excluded.sort_order;
with seed as (select * from jsonb_to_recordset(${json(subjectCatalog.subjects.map(subject => ({ name: subject.name, levels: subject.levels })))}) as s(name text,levels text[]))
insert into public.subject_education_levels (subject_id,level_code)
select s.id,unnest(seed.levels) from seed join public.subjects s on s.name=seed.name on conflict do nothing;
notify pgrst, 'reload schema';
`
  fs.writeFileSync(process.argv[seedIndex + 1], seed)
}
console.log(`Subject catalogue: ${subjectCatalog.subjects.length} subjects, ${subjectCatalog.categories.length} categories, ${subjectCatalog.levels.length} levels. Snapshot ${process.argv.includes('--check') ? 'verified' : 'generated'}.`)
