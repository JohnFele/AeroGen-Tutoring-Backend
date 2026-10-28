-- Additive schema support for explicitly marked integration-test accounts.
-- Apply as a migration before loading the optional demo fixture.
alter table public.profiles add column demo_dataset text;
alter table public.tutor_profiles add column demo_dataset text;
comment on column public.profiles.demo_dataset is 'Trusted test-dataset marker. Client profile-update permissions exclude this column.';
comment on column public.tutor_profiles.demo_dataset is 'Non-null demo tutors are excluded from normal public discovery.';

alter policy "Approved tutors are discoverable" on public.tutor_profiles
  using (is_approved and is_accepting_students and demo_dataset is null);
create policy "Demo members can discover their demo tutors"
  on public.tutor_profiles for select to authenticated using (
    is_approved and is_accepting_students and demo_dataset = (
      select p.demo_dataset from public.profiles p where p.id = (select auth.uid())
    )
  );
create policy "Tutors can read their own tutor profile"
  on public.tutor_profiles for select to authenticated using (user_id = (select auth.uid()));
create policy "Tutors can read their own subject assignments"
  on public.tutor_subjects for select to authenticated using (tutor_id = (select auth.uid()));

-- Existing subject/review discovery policies query tutor_profiles under RLS, so
-- demo subjects and reviews inherit this boundary without exposing profiles.
notify pgrst, 'reload schema';
