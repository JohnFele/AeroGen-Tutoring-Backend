create table public.saved_tutors (
  user_id uuid not null references public.profiles(id) on delete cascade,
  tutor_id uuid not null references public.tutor_profiles(user_id) on delete cascade,
  primary key (user_id, tutor_id)
);
create index saved_tutors_tutor_idx on public.saved_tutors(tutor_id);
alter table public.saved_tutors enable row level security;
revoke all on public.saved_tutors from public, anon, authenticated;
grant select, insert, delete on public.saved_tutors to authenticated;

create policy "Users can read their saved tutors" on public.saved_tutors
for select to authenticated using (user_id = (select auth.uid()));
create policy "Users can save visible tutors" on public.saved_tutors
for insert to authenticated with check (
  user_id = (select auth.uid())
  and exists (select 1 from public.tutor_directory d where d.id = tutor_id)
);
create policy "Users can remove their saved tutors" on public.saved_tutors
for delete to authenticated using (user_id = (select auth.uid()));

create or replace function private.admin_support_stats(_admin uuid) returns jsonb
language sql stable set search_path = '' as $$
  with work as (
    select count(*) as replies, count(first_response_on_time) as first_responses,
      count(*) filter (where first_response_on_time) as on_time
    from private.ticket_replies where author = _admin and from_support
  ), feedback as (
    select count(*) as ratings, avg(f.score) as average_score, count(*) filter (where f.score >= 4) as helpful
    from private.support_reply_ratings f join private.ticket_replies r on r.id = f.reply_id
    where r.author = _admin and r.from_support
  )
  select jsonb_build_object(
    'replies', w.replies, 'first_responses', w.first_responses, 'on_time', w.on_time,
    'ratings', f.ratings, 'helpful', f.helpful, 'average_feedback', round(f.average_score, 2),
    'rating', case when f.ratings >= 3 then round(
      case when w.first_responses = 0 then f.average_score
      else 0.8 * f.average_score + 0.2 * (1 + 4 * w.on_time::numeric / w.first_responses) end, 2) end,
    'resolved', (select count(*) from public.booking_safety_cases c
      where c.assigned_to = _admin and c.status = 'resolved' and c.auto_resolved_at is null)
  ) from work w cross join feedback f;
$$;

notify pgrst, 'reload schema';
