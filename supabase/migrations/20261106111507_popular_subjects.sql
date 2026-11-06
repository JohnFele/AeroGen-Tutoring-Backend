-- Expose only ranked catalogue slugs. Booking rows remain private.
create function public.popular_subject_slugs() returns text[]
language sql stable security definer set search_path = '' as $$
  with demand as (
    select s.slug,
      count(distinct b.student_id) filter (where account.last_sign_in_at >= now() - interval '30 days') as active_learners,
      count(distinct b.student_id) as learners,
      count(*) filter (where b.status = 'completed') as completed_lessons,
      count(*) filter (where b.status = 'confirmed') as upcoming_lessons
    from public.bookings b
    join public.subjects s on s.id = b.subject_id and s.is_active
    join public.profiles learner on learner.id = b.student_id
      and learner.role = 'student' and learner.demo_dataset is null
    join auth.users account on account.id = learner.id
    join public.tutor_profiles tutor on tutor.user_id = b.tutor_id and tutor.demo_dataset is null
    join public.profiles tutor_account on tutor_account.id = b.tutor_id and tutor_account.demo_dataset is null
    where (b.status = 'completed' and b.starts_at >= now() - interval '90 days' and b.ends_at <= now())
      or (b.status = 'confirmed' and b.starts_at >= now() and b.starts_at < now() + interval '30 days'
        and exists (select 1 from private.lesson_funds f where f.booking_id = b.id and f.state = 'held'))
    group by s.slug
    having count(distinct b.student_id) >= 2
  )
  select array(
    select slug from demand
    order by active_learners desc, learners desc, completed_lessons desc, upcoming_lessons desc, slug
    limit 8
  );
$$;
revoke all on function public.popular_subject_slugs() from public, anon, authenticated;
grant execute on function public.popular_subject_slugs() to anon, authenticated;
