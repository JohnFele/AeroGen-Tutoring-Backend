-- Authentication methods are signed by Supabase, not editable user metadata.
create function private.admin_mfa_verified_until() returns timestamptz
language sql stable set search_path='' as $$
  select max(case when entry->>'method'='totp' and entry->>'timestamp' ~ '^[0-9]{1,12}$'
    then to_timestamp((entry->>'timestamp')::double precision) end) + interval '7 days'
  from jsonb_array_elements(case when jsonb_typeof(auth.jwt()->'amr')='array'
    then auth.jwt()->'amr' else '[]'::jsonb end) entry
  where case when entry->>'timestamp' ~ '^[0-9]{1,12}$'
    then to_timestamp((entry->>'timestamp')::double precision) <= now()+interval '60 seconds' else false end;
$$;
revoke all on function private.admin_mfa_verified_until() from public,anon;
grant execute on function private.admin_mfa_verified_until() to authenticated;

create function public.my_session_security() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare actor uuid := (select auth.uid()); session_id text := auth.jwt()->>'session_id';
  current_session auth.sessions%rowtype; expires_at timestamptz; mfa_until timestamptz; account_role text;
begin
  if actor is null or session_id is null or session_id !~ '^[0-9a-fA-F-]{36}$' then
    return jsonb_build_object('valid',false,'admin_verified',false);
  end if;
  begin
    select * into current_session from auth.sessions where id=session_id::uuid and user_id=actor;
  exception when invalid_text_representation then
    return jsonb_build_object('valid',false,'admin_verified',false);
  end;
  if current_session.id is null then return jsonb_build_object('valid',false,'admin_verified',false); end if;
  expires_at := least(current_session.created_at+interval '30 days',current_session.not_after);
  mfa_until := private.admin_mfa_verified_until();
  select role into account_role from public.profiles where id=actor;
  return jsonb_build_object('valid',expires_at>now(),'expires_at',expires_at,'role',account_role,
    'mfa_expires_at',mfa_until,'admin_verified',coalesce(expires_at>now() and auth.jwt()->>'aal'='aal2'
      and mfa_until>now() and account_role in ('admin','superUser'),false));
end;
$$;
revoke all on function public.my_session_security() from public,anon,authenticated;
grant execute on function public.my_session_security() to authenticated;

create or replace function private.is_platform_admin() returns boolean
language sql stable security definer set search_path='' as $$
  select coalesce((select auth.jwt()->>'aal')='aal2' and private.admin_mfa_verified_until()>now(),false)
    and (select auth.uid()) is not null and exists(
      select 1 from public.profiles where id=(select auth.uid()) and role in ('admin','superUser'));
$$;

-- Test identities remain available for historical audit, but are no longer public listings.
alter policy "Approved tutors are discoverable" on public.tutor_profiles
  using (is_approved and is_accepting_students and demo_dataset is null);

create or replace view public.tutor_directory with(security_invoker=true,security_barrier=true) as
select listing.*, prices.online_hourly_rate, prices.in_person_hourly_rate from (
SELECT tp.user_id AS id,
    tp.public_name,
    tp.bio,
    tp.city,
    tp.province,
    tp.qualification,
    tp.institution,
    tp.year_completed,
    tp.certifications,
    tp.years_experience,
    tp.teaching_style,
    tp.student_age_groups,
    tp.availability_slots,
    tp.teaching_modes,
    tp.hourly_rate,
    tp.students_per_session,
    tp.is_featured,
    tp.avatar_url,
    tp.demo_dataset,
    tp.updated_at,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'slug', s.slug, 'aliases', s.aliases, 'curriculum_codes', ts.curriculum_codes) ORDER BY s.name) AS jsonb_agg
           FROM public.tutor_subjects ts
             JOIN public.subjects s ON s.id = ts.subject_id AND s.is_active
          WHERE ts.tutor_id = tp.user_id AND (cardinality(ts.curriculum_codes) > 0 OR cardinality(private.directory_tutor_curricula(tp.user_id)) = 0)), '[]'::jsonb) AS subjects,
    COALESCE(stats.review_count, 0) AS review_count,
    round(stats.average_rating, 1) AS rating,
    COALESCE(stats.completed_sessions, 0) AS completed_sessions,
    COALESCE(stats.reviewed_students, 0) AS reviewed_students,
    tp.first_approved_at,
    COALESCE(stats.average_rating >= 4.8 AND stats.reviewed_students >= 5 AND stats.completed_sessions >= 10 AND tp.first_approved_at <= (now() - '30 days'::interval), false) AS is_top_rated,
    COALESCE(tp.first_approved_at > (now() - '90 days'::interval) AND COALESCE(stats.completed_sessions, 0) < 10, false) AS is_new,
    private.directory_tutor_curricula(tp.user_id) AS curriculum_codes
   FROM public.tutor_profiles tp
     LEFT JOIN public.tutor_public_stats stats ON stats.tutor_id = tp.user_id
  WHERE tp.is_approved AND tp.is_accepting_students
) listing join public.tutor_profiles prices on prices.user_id=listing.id where listing.demo_dataset is null;



create or replace function public.search_bookable_students(_query text)
returns table(id uuid,name text) language plpgsql stable security definer set search_path='' as $$
declare actor uuid := (select auth.uid()); term text := lower(btrim(coalesce(_query,'')));
begin
  perform private.assert_platform_available();
  if actor is null or not private.booking_tutor_visible(actor,actor) then
    raise exception 'Only approved tutors can search for students.' using errcode='42501';
  end if;
  if char_length(term) not between 2 and 80 then raise exception 'Enter a name or a booking code.' using errcode='22023';end if;
  return query select p.id,coalesce(nullif(btrim(p.first_name),''),'Student') ||
    case when nullif(btrim(p.last_name),'') is null then '' else ' '||left(p.last_name,1)||'.' end
  from public.profiles p left join private.student_booking_preferences pref on pref.student_id=p.id
  where p.role='student' and p.demo_dataset is null and private.booking_pair_allowed(actor,p.id)
    and (p.id::text=term or (pref.discoverable and private.has_open_booking_hours(p.id,false)
      and strpos(lower(concat_ws(' ',p.first_name,p.last_name)),term)>0))
  order by 2,1 limit 20;
end;
$$;
notify pgrst, 'reload schema';
