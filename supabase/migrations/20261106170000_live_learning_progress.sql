create table private.learning_clearances (
  student_id uuid primary key references public.profiles(id) on delete cascade,
  basis text not null check (basis in ('adult_declaration','documented_authorisation')),
  recorded_by uuid references public.profiles(id) on delete set null,
  reference text check (length(reference) <= 120),
  recorded_at timestamptz not null default now(),
  revoked_at timestamptz
);

create table private.learning_plans (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.profiles(id) on delete cascade,
  subject_id bigint not null references public.subjects(id),
  title text not null check (length(title) between 1 and 120),
  context text not null default '' check (length(context) <= 180),
  review_date date not null,
  skills jsonb not null check (jsonb_typeof(skills) = 'array'),
  version integer not null default 1,
  updated_at timestamptz not null default now(),
  unique(student_id,subject_id)
);

create table private.learning_access (
  plan_id uuid not null references private.learning_plans(id) on delete cascade,
  tutor_id uuid not null references public.profiles(id) on delete cascade,
  status text not null check (status in ('pending','active','revoked')),
  expires_at timestamptz not null,
  updated_at timestamptz not null default now(),
  primary key(plan_id,tutor_id)
);
create index learning_access_tutor on private.learning_access(tutor_id,plan_id);
create unique index learning_plan_active_tutor on private.learning_access(plan_id) where status='active';

create table private.learning_goals (
  id uuid primary key default gen_random_uuid(),
  plan_id uuid not null references private.learning_plans(id) on delete cascade,
  status text not null default 'proposed' check (status in ('proposed','active','paused','archived')),
  active_revision integer,
  baseline_id uuid,
  achieved_at timestamptz
);
create index learning_goals_plan on private.learning_goals(plan_id,id);
create table private.learning_goal_versions (
  goal_id uuid not null references private.learning_goals(id) on delete cascade,
  version integer not null,
  proposer uuid references public.profiles(id) on delete set null,
  reviewer uuid references public.profiles(id) on delete set null,
  state text not null check (state in ('proposed','accepted','declined')),
  config jsonb not null,
  reason text not null default '',
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  primary key(goal_id,version)
);
create unique index learning_goal_pending on private.learning_goal_versions(goal_id) where state='proposed';

create table private.learning_entries (
  id uuid primary key default gen_random_uuid(),
  plan_id uuid not null references private.learning_plans(id) on delete cascade,
  goal_id uuid references private.learning_goals(id) on delete restrict,
  kind text not null check (kind in ('assessment','work','practice','note')),
  booking_id uuid references public.bookings(id) on delete set null,
  author_id uuid references public.profiles(id) on delete set null,
  recorded_on date not null,
  data jsonb not null,
  created_at timestamptz not null default now()
);
create index learning_entries_plan on private.learning_entries(plan_id,kind,recorded_on desc,created_at desc,id);
create index learning_entries_goal on private.learning_entries(goal_id,kind,recorded_on,created_at,id);

create table private.learning_events (
  id uuid primary key default gen_random_uuid(),
  plan_id uuid not null references private.learning_plans(id) on delete cascade,
  actor_id uuid references public.profiles(id) on delete set null,
  kind text not null,
  summary text not null,
  details jsonb,
  created_at timestamptz not null default clock_timestamp()
);
create index learning_events_plan on private.learning_events(plan_id,created_at desc,id);
create table private.learning_requests (
  actor_id uuid not null references public.profiles(id) on delete cascade,
  id uuid not null,
  intent_hash bytea not null,
  result jsonb,
  primary key(actor_id,id)
);
alter table private.learning_clearances enable row level security;
alter table private.learning_plans enable row level security;
alter table private.learning_access enable row level security;
alter table private.learning_goals enable row level security;
alter table private.learning_goal_versions enable row level security;
alter table private.learning_entries enable row level security;
alter table private.learning_events enable row level security;
alter table private.learning_requests enable row level security;
revoke all on private.learning_clearances,private.learning_plans,private.learning_access,private.learning_goals,
  private.learning_goal_versions,private.learning_entries,private.learning_events,private.learning_requests
  from public,anon,authenticated;

create function private.learning_save_entry(_plan private.learning_plans,_actor uuid,_tutor uuid,_action text,_data jsonb)
returns jsonb language plpgsql set search_path='' as $$
declare
  is_tutor boolean := coalesce(_actor=_tutor,false);
  entry private.learning_entries%rowtype;
  goal private.learning_goals%rowtype;
  config jsonb; previous jsonb; next_data jsonb; notes text; conditions text; level text; mark numeric; max_mark numeric;
  due date; kind text; booking uuid; summary text; recipient uuid;
begin
  if _action='feedback' then
    if not is_tutor then raise exception 'Only the assigned tutor can record a check-in.' using errcode='42501'; end if;
    booking := nullif(_data->>'bookingId','')::uuid;
    if booking is not null and not exists(select 1 from public.bookings where id=booking and status='completed'
      and student_id=_plan.student_id and tutor_id=_actor and subject_id=_plan.subject_id) then
      raise exception 'Choose a completed lesson for this plan.' using errcode='22023';
    end if;
    insert into private.learning_entries(plan_id,kind,author_id,recorded_on,booking_id,data)
      values (_plan.id,'note',_actor,(now() at time zone 'Africa/Johannesburg')::date,booking,jsonb_build_object(
        'title',private.learning_text(_data,'title',1,120),'notes',private.learning_text(_data,'notes',1,2000),
        'nextStep',private.learning_text(_data,'nextStep',1,500),'fromTutor',true));
    perform private.learning_notice(_plan.student_id,_plan.id,'Learning feedback available','Your tutor shared feedback and a next step.');
    return jsonb_build_object('summary','Recorded tutor feedback');
  end if;
  if _action='reflection' then
    if _actor<>_plan.student_id then raise exception 'Only the learner can record a reflection.' using errcode='42501'; end if;
    insert into private.learning_entries(plan_id,kind,author_id,recorded_on,data)
      values (_plan.id,'note',_actor,(now() at time zone 'Africa/Johannesburg')::date,jsonb_build_object(
        'title','Learner reflection','notes',private.learning_text(_data,'notes',1,1000),'fromTutor',false));
    return jsonb_build_object('summary','Recorded learner reflection');
  end if;

  if _action in ('verifyAssessment','correctAssessment','reviewEvidence','toggleActivity') then
    select * into entry from private.learning_entries where id=(_data->>'id')::uuid and plan_id=_plan.id;
    if not found then raise exception 'Learning record unavailable.' using errcode='PT404'; end if;
    if _action='toggleActivity' then
      if _actor<>_plan.student_id or entry.kind<>'practice' or jsonb_typeof(_data->'completed') is distinct from 'boolean' then
        raise exception 'Only the learner can set practice completion.' using errcode='42501';
      end if;
      if (entry.data->>'completed')::boolean=(_data->>'completed')::boolean then
        return jsonb_build_object('summary','Practice status unchanged');
      end if;
      update private.learning_entries set data=data || jsonb_build_object('completed',(_data->>'completed')::boolean,
        'completedAt',case when (_data->>'completed')::boolean then now() end) where id=entry.id;
      return jsonb_build_object('summary','Updated practice completion');
    end if;
    if not is_tutor then raise exception 'Only the assigned tutor can review this record.' using errcode='42501'; end if;
  end if;

  select * into goal from private.learning_goals where id=coalesce(entry.goal_id,(_data->>'goalId')::uuid) and plan_id=_plan.id;
  if not found then raise exception 'Choose a goal in this plan.' using errcode='PT404'; end if;
  select v.config into config from private.learning_goal_versions v where v.goal_id=goal.id and v.version=goal.active_revision;
  if config is null or (goal.status<>'active' and _action not in ('correctAssessment','verifyAssessment','reviewEvidence')) then
    raise exception 'Choose an agreed, active goal.' using errcode='PT409';
  end if;

  if _action='assessment' and config->>'type'='score' then
    mark := private.learning_number(_data,'score',0,1000000);
    max_mark := private.learning_number(_data,'maxScore',0.001,1000000);
    conditions := _data->>'conditions';
    if mark>max_mark or coalesce(conditions,'') not in ('Guided','Independent')
      or coalesce(_data->>'category','') not in ('school_test','school_exam','tutor_checkpoint','course_assessment','rubric')
      or jsonb_typeof(_data->'comparable') is distinct from 'boolean' then
      raise exception 'Check the marks, category and assessment conditions.' using errcode='22023';
    end if;
    insert into private.learning_entries(plan_id,goal_id,kind,author_id,recorded_on,data)
      values (_plan.id,goal.id,'assessment',_actor,private.learning_date(_data,'date',true),
        jsonb_build_object('title',private.learning_text(_data,'title',1,120),'score',mark,'maxScore',max_mark,
          'percentage',round(mark/max_mark*100,1),'conditions',conditions,'category',_data->>'category',
          'questions',private.learning_number(_data,'questions',0,500,true),
          'comparable',(_data->>'comparable')::boolean,'notes',private.learning_text(_data,'notes',1,2000),
          'source',case when is_tutor then private.learning_text(_data,'source',1,40) else 'Student entered' end,
          'verified',is_tutor,'reviewed',is_tutor)) returning * into entry;
    perform private.learning_mark_baseline(goal,entry,config);
    recipient := case when is_tutor then _plan.student_id else _tutor end;
    perform private.learning_notice(recipient,_plan.id,case when is_tutor then 'New assessment recorded' else 'Assessment awaiting verification' end,
      'Open the learning plan to review the update.');
    summary := 'Recorded an assessment';
  elsif _action='verifyAssessment' and entry.kind='assessment' and not (entry.data->>'reviewed')::boolean
    and jsonb_typeof(_data->'accepted')='boolean' then
    previous := entry.data;
    update private.learning_entries set data=data || jsonb_build_object('verified',(_data->>'accepted')::boolean,'reviewed',true,
      'feedback',private.learning_text(_data,'feedback',1,2000),'reviewedAt',now(),'reviewedBy',_actor)
      where id=entry.id returning * into entry;
    perform private.learning_mark_baseline(goal,entry,config);
    perform private.learning_notice(_plan.student_id,_plan.id,'Assessment reviewed','Open the learning plan to see your tutor’s assessment review.');
    summary := 'Reviewed an assessment';
  elsif _action='correctAssessment' and entry.kind='assessment' and (entry.data->>'verified')::boolean then
    mark := private.learning_number(_data,'score',0,1000000);
    max_mark := private.learning_number(_data,'maxScore',0.001,1000000);
    if mark>max_mark then raise exception 'The mark cannot exceed the maximum.' using errcode='22023'; end if;
    notes := private.learning_text(_data,'reason',5,500);
    previous := entry.data;
    update private.learning_entries set data=data || jsonb_build_object('score',mark,'maxScore',max_mark,
      'percentage',round(mark/max_mark*100,1),'correctedAt',now())
      where id=entry.id returning * into entry;
    perform private.learning_notice(_plan.student_id,_plan.id,'Assessment correction','An assessment was corrected. Open your plan to see its history.');
    summary := 'Corrected an assessment: ' || notes;
  elsif _action in ('submitEvidence','checkIn') and config->>'type'='skill' and (_action='submitEvidence' or is_tutor) then
    conditions := _data->>'conditions';
    if coalesce(conditions,'') not in ('Guided','Independent') then raise exception 'Choose the work conditions.' using errcode='22023'; end if;
    due := private.learning_date(_data,'date',true);
    next_data := jsonb_build_object('title',private.learning_text(_data,'title',1,120),'notes',private.learning_text(_data,'notes',1,5000),
      'conditions',conditions,'skillId',config->>'skillId','status','pending','confidence',private.learning_text(_data,'confidence',0,30));
    insert into private.learning_entries(plan_id,goal_id,kind,author_id,recorded_on,data)
      values (_plan.id,goal.id,'work',_actor,due,next_data) returning * into entry;
    if _action='checkIn' then
      return private.learning_save_entry(_plan,_actor,_tutor,'reviewEvidence',_data || jsonb_build_object('id',entry.id));
    end if;
    perform private.learning_notice(_tutor,_plan.id,'Skill evidence awaiting review','A learner submitted a demonstration for review.');
    summary := 'Submitted skill evidence';
  elsif _action='reviewEvidence' and entry.kind='work' and entry.data->>'status'='pending' then
    conditions := _data->>'conditions'; level := _data->>'level';
    if coalesce(conditions,'') not in ('Guided','Independent') or coalesce(level,'') not in ('Needs support','Developing','Independent','Secure')
      or jsonb_typeof(_data->'revision') is distinct from 'boolean' then raise exception 'Choose the reviewed skill level and outcome.' using errcode='22023'; end if;
    previous := entry.data;
    update private.learning_entries set data=data || jsonb_build_object('status',case when (_data->>'revision')::boolean then 'revision' else 'reviewed' end,
      'conditions',conditions,'level',level,'skillLevel',case when (conditions='Guided' or (_data->>'revision')::boolean)
        and level in ('Independent','Secure') then 'Developing' else level end,
      'feedback',private.learning_text(_data,'feedback',1,2000),'reviewedAt',now(),'reviewedBy',_actor)
      where id=entry.id returning * into entry;
    perform private.learning_notice(_plan.student_id,_plan.id,'Skill feedback available','Your tutor reviewed a demonstration and shared feedback.');
    summary := 'Reviewed skill evidence';
  elsif _action='addActivity' and is_tutor and config->>'type'='habit' then
    insert into private.learning_entries(plan_id,goal_id,kind,author_id,recorded_on,data)
      values (_plan.id,goal.id,'practice',_actor,private.learning_date(_data,'dueDate'),jsonb_build_object(
        'title',private.learning_text(_data,'title',1,160),'completed',false));
    perform private.learning_notice(_plan.student_id,_plan.id,'Practice activity assigned','A new activity is available in your learning plan.');
    summary := 'Assigned a practice activity';
  else
    raise exception 'This action is unavailable for this goal or record.' using errcode='PT409';
  end if;
  if _action in ('assessment','verifyAssessment','correctAssessment','reviewEvidence') then
    select * into goal from private.learning_goals where id=goal.id;
    if goal.achieved_at is not null and not (private.learning_goal_result(goal,config)->>'eligible')::boolean then
      update private.learning_goals set achieved_at=null where id=goal.id;
      summary := summary || ' · achievement requires a new review';
    end if;
  end if;
  return jsonb_build_object('summary',summary,'details',case when previous is not null or entry.kind='assessment'
    then jsonb_build_object('entryId',entry.id,'before',previous,'after',entry.data,'recordedOn',entry.recorded_on) end);
end;
$$;
revoke all on function private.learning_save_entry(private.learning_plans,uuid,uuid,text,jsonb) from public,anon,authenticated;

create function private.learning_text(_value jsonb,_field text,_min integer,_max integer) returns text
language plpgsql immutable set search_path='' as $$
declare val text := coalesce(btrim(_value->>_field),'');
begin
  if char_length(val) not between _min and _max then
    raise exception 'Enter a valid % (% to % characters).',replace(_field,'_',' '),_min,_max using errcode='22023';
  end if;
  return val;
end;
$$;

create function private.learning_date(_value jsonb,_field text,_historical boolean default false) returns date
language plpgsql stable set search_path='' as $$
declare val text := _value->>_field; result date;
begin
  if val is null or val !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then raise exception 'Choose a valid date.' using errcode='22023'; end if;
  result := val::date;
  if result < date '1900-01-01' or (_historical and result > (now() at time zone 'Africa/Johannesburg')::date) then
    raise exception 'Choose a valid date for this record.' using errcode='22023';
  end if;
  return result;
end;
$$;

create function private.learning_tutor_approved(_tutor uuid) returns boolean
language sql stable set search_path='' as $$
  select exists(select 1 from public.profiles p join public.tutor_profiles t on t.user_id=p.id
    where p.id=_tutor and p.role='tutor' and t.is_approved);
$$;

create function private.learning_current_tutor(_plan uuid) returns uuid
language sql stable set search_path='' as $$
  select tutor_id from private.learning_access where plan_id=_plan and status='active'
    and expires_at>now() and private.learning_tutor_approved(tutor_id);
$$;

create function private.learning_notice(_recipient uuid,_plan uuid,_title text,_body text) returns void
language sql set search_path='' as $$
  insert into public.notifications(user_id,kind,title,body,data)
  select _recipient,'system',_title,_body,jsonb_build_object('tab','progress','planId',_plan)
  where _recipient is not null;
$$;

create function private.learning_eligible_booking(_actor uuid,_booking uuid) returns public.bookings
language plpgsql stable set search_path='' as $$
declare item public.bookings%rowtype;
begin
  select * into item from public.bookings b where b.id=_booking and _actor in (b.tutor_id,b.student_id)
    and b.status in ('confirmed','completed') and b.subject_id is not null
    and b.starts_at>=now()-interval '90 days' and private.learning_tutor_approved(b.tutor_id);
  if not found then raise exception 'Choose a recent completed or confirmed lesson for this subject.' using errcode='PT404'; end if;
  return item;
end;
$$;

revoke all on function private.learning_text(jsonb,text,integer,integer), private.learning_date(jsonb,text,boolean),
  private.learning_tutor_approved(uuid), private.learning_current_tutor(uuid), private.learning_notice(uuid,uuid,text,text),
  private.learning_eligible_booking(uuid,uuid) from public,anon,authenticated;

create function private.learning_assessment_qualifies(_data jsonb,_config jsonb) returns boolean
language sql immutable set search_path='' as $$
  select coalesce((_data->>'verified')::boolean and (_data->>'comparable')::boolean
    and _data->>'conditions'='Independent' and _data->>'category'=_config->>'assessmentType'
    and coalesce((_data->>'questions')::integer,0)>=coalesce((_config->>'minQuestions')::integer,0),false);
$$;

create function private.learning_goal_result(_goal private.learning_goals,_config jsonb) returns jsonb
language plpgsql stable set search_path='' as $$
declare
  baseline numeric; baseline_date date; current_score numeric; previous_score numeric; target numeric := (_config->>'target')::numeric;
  n integer := 0; required_checks integer; last_success date; gap integer := coalesce((_config->>'minGapDays')::integer,0);
  entry record; progress numeric; detail text; eligible boolean := false; status text := _goal.status;
begin
  case _config->>'type'
  when 'score' then
    required_checks := (_config->>'requiredChecks')::integer;
    select (data->>'percentage')::numeric,recorded_on into baseline,baseline_date from private.learning_entries where id=_goal.baseline_id;
    for entry in select recorded_on,(data->>'percentage')::numeric as score
      from private.learning_entries
      where goal_id=_goal.id and kind='assessment' and recorded_on>=baseline_date and private.learning_assessment_qualifies(data,_config)
      order by recorded_on,created_at,id
    loop
      previous_score := current_score; current_score := entry.score;
      if entry.score>=target and (last_success is null or entry.recorded_on-last_success>=gap) then
        n := n+1; last_success := entry.recorded_on;
      end if;
    end loop;
    if baseline is null or current_score is null then
      detail := 'Starting assessment needed';
    elsif target<=baseline then
      detail := 'Agree a target above the baseline to measure improvement';
    else
      progress := least(100,greatest(0,round((current_score-baseline)/(target-baseline)*100)));
      eligible := current_score>=target and n>=required_checks;
      detail := format('%s%% → %s%% · target %s%%',baseline,current_score,target);
      if required_checks>1 then detail := detail || format(' · %s/%s qualifying checks',least(n,required_checks),required_checks); end if;
    end if;
  when 'skill' then
    required_checks := (_config->>'requiredDemonstrations')::integer;
    for entry in select recorded_on from private.learning_entries where goal_id=_goal.id and kind='work'
      and data->>'status'='reviewed' and data->>'conditions'='Independent' and data->>'level' in ('Independent','Secure')
      order by recorded_on,created_at,id
    loop
      if last_success is null or entry.recorded_on-last_success>=gap then
        n := n+1; last_success := entry.recorded_on;
      end if;
    end loop;
    progress := least(100,round(n::numeric/required_checks*100));
    eligible := n>=required_checks;
    detail := format('%s / %s independent demonstrations',n,required_checks);
  when 'habit' then
    select count(*) into n from private.learning_entries where goal_id=_goal.id and kind='practice'
      and (data->>'completed')::boolean;
    progress := least(100,round(n/target*100));
    eligible := n>=target;
    detail := format('%s / %s practice activities completed',n,target);
  end case;
  if _goal.status='active' and eligible and (_goal.achieved_at is not null or _config->>'type'='habit') then status := 'achieved'; end if;
  return jsonb_build_object('baseline',baseline,'current',current_score,'progress',progress,'detail',detail,'status',status,
    'change',case when baseline is not null then round(current_score-baseline,1) end,
    'previousChange',round(current_score-previous_score,1),'eligible',eligible);
end;
$$;

create function private.learning_plan_detail(_plan private.learning_plans,_actor uuid,_tutor uuid) returns jsonb
language sql stable set search_path='' as $$
  select jsonb_build_object(
    'skills',coalesce((select jsonb_agg(s || jsonb_build_object('level',coalesce(obs.data->>'skillLevel','Not assessed'),
      'lastAssessed',obs.recorded_on) order by seq)
      from jsonb_array_elements(_plan.skills) with ordinality as skill(s,seq)
      left join lateral (select e.data,e.recorded_on from private.learning_entries e where e.plan_id=_plan.id
        and e.kind='work' and e.data->>'skillId'=s->>'id' and e.data ? 'skillLevel'
        order by (e.data->>'reviewedAt') desc,e.id limit 1) obs on true),'[]'::jsonb),
    'goals',coalesce((select jsonb_agg(cfg.config || jsonb_build_object('id',g.id,'status',g.status,
      'result',private.learning_goal_result(g,cfg.config),'pendingRevision',
      case when pending.version is not null then jsonb_build_object('version',pending.version,'config',pending.config,'reason',pending.reason,
        'canApprove',pending.proposer<>_actor and pending.proposer in (_plan.student_id,_tutor) and _tutor is not null) end,
      'chart',coalesce((select jsonb_agg(a.data || jsonb_build_object('id',a.id,'date',a.recorded_on,'createdAt',a.created_at)
        order by a.recorded_on,a.created_at,a.id) from (
          (select e.* from private.learning_entries e where e.goal_id=g.id and e.kind='assessment' and e.id is distinct from g.baseline_id
            and e.recorded_on >= (select recorded_on from private.learning_entries where id=g.baseline_id)
            and private.learning_assessment_qualifies(e.data,cfg.config)
            order by e.recorded_on desc,e.created_at desc,e.id desc limit 99)
          union all
          (select e.* from private.learning_entries e where e.id=g.baseline_id and private.learning_assessment_qualifies(e.data,cfg.config))
        ) a),'[]'::jsonb)) order by cfg.created_at,g.id)
      from private.learning_goals g
      left join private.learning_goal_versions pending on pending.goal_id=g.id and pending.state='proposed'
      join lateral (select v.config,v.created_at from private.learning_goal_versions v where v.goal_id=g.id
        and (v.version=g.active_revision or g.active_revision is null) order by v.version desc limit 1) cfg on true
      where g.plan_id=_plan.id),'[]'::jsonb),
    'assessments',coalesce((select jsonb_agg(e.data || jsonb_build_object('id',e.id,'goalId',e.goal_id,'date',e.recorded_on,'createdAt',e.created_at))
      from (select * from private.learning_entries where plan_id=_plan.id and kind='assessment' order by recorded_on desc,created_at desc,id limit 100) e),'[]'::jsonb),
    'evidence',coalesce((select jsonb_agg(e.data || jsonb_build_object('id',e.id,'goalId',e.goal_id,'date',e.recorded_on,'createdAt',e.created_at))
      from (select * from private.learning_entries where plan_id=_plan.id and kind='work' order by recorded_on desc,created_at desc,id limit 100) e),'[]'::jsonb),
    'activities',coalesce((select jsonb_agg(e.data || jsonb_build_object('id',e.id,'goalId',e.goal_id,'dueDate',e.recorded_on))
      from (select * from private.learning_entries where plan_id=_plan.id and kind='practice' order by recorded_on desc,id limit 100) e),'[]'::jsonb),
    'notes',coalesce((select jsonb_agg(e.data || jsonb_build_object('id',e.id,'date',e.recorded_on))
      from (select * from private.learning_entries where plan_id=_plan.id and kind='note' order by recorded_on desc,created_at desc,id limit 30) e),'[]'::jsonb),
    'pendingCount',(select count(*) from private.learning_entries where plan_id=_plan.id
      and (kind='work' and data->>'status'='pending' or kind='assessment' and not (data->>'reviewed')::boolean)),
    'completedLessons',coalesce((select jsonb_agg(jsonb_build_object('id',b.id,'date',(b.starts_at at time zone 'Africa/Johannesburg')::date))
      from (select id,starts_at from public.bookings where student_id=_plan.student_id and tutor_id=_tutor
        and subject_id=_plan.subject_id and status='completed' order by starts_at desc limit 30) b),'[]'::jsonb)
  );
$$;

create function public.my_learning_progress(_plan uuid default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare actor uuid := (select auth.uid()); role_name text; summary jsonb; detail jsonb; candidates jsonb;
begin
  perform private.assert_platform_available();
  select role into role_name from public.profiles where id=actor;
  if role_name is null or role_name not in ('student','tutor') or (role_name='tutor' and not private.learning_tutor_approved(actor)) then
    raise exception 'An approved tutor or learner account is required.' using errcode='42501';
  end if;
  if role_name='student' and not exists(select 1 from private.learning_clearances where student_id=actor and revoked_at is null) then
    return jsonb_build_object('enabled',false,'plans','[]'::jsonb,'candidates','[]'::jsonb);
  end if;
  with visible as (
    select p.*,s.name as subject, concat_ws(' ',learner.first_name,learner.last_name) as student_name,
      coalesce('Grade ' || learner.study_grade::text,phase.name,'Learning plan') as level,
      private.learning_current_tutor(p.id) as current_tutor, a.status as own_access, a.expires_at
    from private.learning_plans p join private.learning_clearances c on c.student_id=p.student_id and c.revoked_at is null
    join public.profiles learner on learner.id=p.student_id
    join public.subjects s on s.id=p.subject_id
    left join public.education_levels phase on phase.code=learner.study_level_code
    left join private.learning_access a on a.plan_id=p.id and a.tutor_id=actor
    where (_plan is null or p.id=_plan) and (p.student_id=actor
      or (a.expires_at>now() and a.status in ('pending','active')))
    order by p.updated_at desc,p.id limit 100
  ), formatted as (
    select v.id,v.updated_at,v.current_tutor, jsonb_build_object('id',v.id,'subject',v.subject,'studentId',v.student_id,
      'studentName',v.student_name,'title',case when actor=v.student_id or actor=v.current_tutor then v.title else v.subject end,
      'level',v.level,'version',v.version,'canRead',actor=v.student_id or coalesce(actor=v.current_tutor,false),
      'access',case when actor=v.student_id then 'owner' when actor=v.current_tutor then 'active' else 'pending' end) as plan_json
    from visible v
  )
  select coalesce(jsonb_agg(plan_json order by updated_at desc,id),'[]'::jsonb) into summary from formatted;

  if _plan is not null then
    if jsonb_array_length(summary)=0 then raise exception 'Learning plan not found.' using errcode='PT404'; end if;
    if (summary->0->>'canRead')::boolean then
      select summary->0 || jsonb_build_object('context',p.context,'reviewDate',p.review_date,
        'tutorId',tutor.id,'tutorName',concat_ws(' ',tutor.first_name,tutor.last_name),
        'requests',case when actor=p.student_id then coalesce((
          select jsonb_agg(jsonb_build_object('id',a.tutor_id,'name',concat_ws(' ',profile.first_name,profile.last_name),'expiresAt',a.expires_at))
          from private.learning_access a join public.profiles profile on profile.id=a.tutor_id where a.plan_id=p.id
          and a.status='pending' and a.expires_at>now() and private.learning_tutor_approved(a.tutor_id)
        ),'[]'::jsonb) else '[]'::jsonb end) || private.learning_plan_detail(p,actor,tutor.id)
      into detail from private.learning_plans p
      left join public.profiles tutor on tutor.id=private.learning_current_tutor(p.id) where p.id=_plan;
    else detail := summary->0; end if;
    return jsonb_build_object('plan',detail);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'subject',s.name,'studentId',r.student_id,'tutorId',r.tutor_id,
    'name',concat_ws(' ',p.first_name,p.last_name),'ready',c.student_id is not null) order by r.starts_at desc),'[]'::jsonb)
  into candidates
  from (select distinct on (b.student_id,b.tutor_id,b.subject_id) b.id,b.student_id,b.tutor_id,b.subject_id,b.starts_at
    from public.bookings b where actor in (b.tutor_id,b.student_id)
      and b.status in ('confirmed','completed') and b.subject_id is not null
      and b.starts_at>=now()-interval '90 days' and private.learning_tutor_approved(b.tutor_id)
    order by b.student_id,b.tutor_id,b.subject_id,b.starts_at desc,b.id limit 100) r
  join public.subjects s on s.id=r.subject_id
  join public.profiles p on p.id=case when role_name='tutor' then r.student_id else r.tutor_id end
  left join private.learning_clearances c on c.student_id=r.student_id and c.revoked_at is null;
  return jsonb_build_object('enabled',true,'plans',summary,'candidates',candidates);
end;
$$;

revoke all on function private.learning_assessment_qualifies(jsonb,jsonb),
  private.learning_goal_result(private.learning_goals,jsonb),private.learning_plan_detail(private.learning_plans,uuid,uuid)
  from public,anon,authenticated;
revoke all on function public.my_learning_progress(uuid) from public,anon,authenticated;
grant execute on function public.my_learning_progress(uuid) to authenticated;

create function private.learning_number(_value jsonb,_field text,_min numeric,_max numeric,_whole boolean default false)
returns numeric language plpgsql immutable set search_path='' as $$
declare raw text := _value->>_field; val numeric;
begin
  if raw is null or raw !~ '^[0-9]{1,7}(\.[0-9]{1,3})?$' then raise exception 'Enter a valid %.',_field using errcode='22023'; end if;
  val := raw::numeric;
  if val<_min or val>_max or (_whole and val<>trunc(val)) then raise exception 'Enter a valid %.',_field using errcode='22023'; end if;
  return val;
end;
$$;

create function private.learning_goal_config(_data jsonb,_plan private.learning_plans) returns jsonb
language plpgsql stable set search_path='' as $$
declare kind text := _data->>'type'; common jsonb; target numeric;
begin
  common := jsonb_build_object('type',kind,'title',private.learning_text(_data,'title',1,160),
    'criteria',private.learning_text(_data,'criteria',1,1500),'dueDate',private.learning_date(_data,'dueDate'));
  if kind='score' then
    if coalesce(_data->>'assessmentType','') not in ('school_test','school_exam','tutor_checkpoint','course_assessment','rubric') then
      raise exception 'Choose an assessment category.' using errcode='22023';
    end if;
    target := private.learning_number(_data,'target',0.1,100);
    return common || jsonb_build_object('target',target,'assessmentType',_data->>'assessmentType',
      'requiredChecks',private.learning_number(_data,'requiredChecks',1,20,true),
      'minGapDays',private.learning_number(_data,'minGapDays',1,90,true),
      'minQuestions',private.learning_number(_data,'minQuestions',0,500,true));
  elsif kind='skill' then
    if not exists(select 1 from jsonb_array_elements(_plan.skills) s where s->>'id'=_data->>'skillId') then
      raise exception 'Choose a skill in this plan.' using errcode='22023';
    end if;
    return common || jsonb_build_object('skillId',_data->>'skillId','requiredDemonstrations',
      private.learning_number(_data,'requiredDemonstrations',1,20,true),
      'minGapDays',private.learning_number(_data,'minGapDays',1,90,true));
  elsif kind='habit' then
    return common || jsonb_build_object('target',private.learning_number(_data,'target',1,1000,true));
  end if;
  raise exception 'Choose a goal type.' using errcode='22023';
end;
$$;

create function private.learning_grant(_plan private.learning_plans,_tutor uuid) returns void
language plpgsql set search_path='' as $$
declare old_tutor uuid;
begin
  select tutor_id into old_tutor from private.learning_access where plan_id=_plan.id and status='active';
  update private.learning_access set status='revoked',updated_at=now() where plan_id=_plan.id
    and tutor_id<>_tutor and status='active';
  if old_tutor is not null and old_tutor<>_tutor then
    update private.learning_goal_versions v set state='declined',reviewed_at=now() from private.learning_goals g
      where g.id=v.goal_id and g.plan_id=_plan.id and v.proposer=old_tutor and v.state='proposed';
    perform private.bump_workspace(old_tutor);
  end if;
  insert into private.learning_access(plan_id,tutor_id,status,expires_at)
  values (_plan.id,_tutor,'active',now()+interval '90 days')
  on conflict (plan_id,tutor_id) do update set status='active',expires_at=excluded.expires_at,updated_at=now();
  perform private.learning_notice(_tutor,_plan.id,'Learning plan access granted','The learner approved access for this subject.');
end;
$$;

create function private.learning_edit_goal(_plan private.learning_plans,_actor uuid,_tutor uuid,_action text,_data jsonb)
returns jsonb language plpgsql set search_path='' as $$
declare
  goal private.learning_goals%rowtype;
  revision private.learning_goal_versions%rowtype;
  config jsonb; version_no integer; baseline numeric; summary text;
  recipient uuid := case when _actor=_plan.student_id then _tutor else _plan.student_id end;
begin
  if _action='saveGoal' then
    config := private.learning_goal_config(_data,_plan);
    if _data->>'id' is null then
      insert into private.learning_goals(plan_id) values (_plan.id) returning * into goal;
      version_no := 1;
    else
      select * into goal from private.learning_goals where id=(_data->>'id')::uuid and plan_id=_plan.id;
      if not found or goal.status='archived' then raise exception 'Goal unavailable.' using errcode='PT404'; end if;
      if exists(select 1 from private.learning_goal_versions where goal_id=goal.id and state='proposed') then
        raise exception 'Review the pending proposal before making another.' using errcode='PT409';
      end if;
      if goal.active_revision is not null then
        select * into revision from private.learning_goal_versions where goal_id=goal.id and version=goal.active_revision;
        if config->>'type' is distinct from revision.config->>'type' or config->>'skillId' is distinct from revision.config->>'skillId'
          or config->>'assessmentType' is distinct from revision.config->>'assessmentType'
          or (config->>'criteria' is distinct from revision.config->>'criteria' and exists(
            select 1 from private.learning_entries where goal_id=goal.id
          )) then raise exception 'Create a new goal for a different measure or criteria once evidence exists.' using errcode='22023'; end if;
        select (data->>'percentage')::numeric into baseline from private.learning_entries where id=goal.baseline_id;
        if baseline is not null and (config->>'target')::numeric<=baseline then
          raise exception 'Choose a target above the recorded baseline.' using errcode='22023';
        end if;
        if goal.baseline_id is not null and not exists(select 1 from private.learning_entries
          where id=goal.baseline_id and private.learning_assessment_qualifies(data,config)) then
          raise exception 'The revised evidence requirements must still qualify the baseline.' using errcode='22023';
        end if;
      end if;
      select coalesce(max(version),0)+1 into version_no from private.learning_goal_versions where goal_id=goal.id;
    end if;
    insert into private.learning_goal_versions(goal_id,version,proposer,state,config,reason)
      values (goal.id,version_no,_actor,'proposed',config,private.learning_text(_data,'reason',case when goal.active_revision is null then 0 else 5 end,500));
    perform private.learning_notice(recipient,_plan.id,'Learning goal proposal','A learning goal is ready for your review.');
    return jsonb_build_object('summary','Proposed a goal or revision: ' || (config->>'title'),
      'details',jsonb_build_object('version',version_no,'state','proposed','config',config));
  end if;

  select * into goal from private.learning_goals where id=(_data->>'id')::uuid and plan_id=_plan.id;
  if not found then raise exception 'Goal unavailable.' using errcode='PT404'; end if;
  if _action='approveGoal' then
    select * into revision from private.learning_goal_versions where goal_id=goal.id
      and version=(_data->>'version')::integer and state='proposed';
    if not found or goal.status='archived' then raise exception 'This proposal is no longer available.' using errcode='PT409'; end if;
    if revision.proposer is distinct from recipient or revision.proposer is null or recipient is null then
      raise exception 'Only the other participant can review this proposal.' using errcode='42501';
    end if;
    if _data->>'decision'='accept' then
      update private.learning_goal_versions set state='accepted',reviewer=_actor,reviewed_at=now() where goal_id=goal.id and version=revision.version;
      update private.learning_goals set status='active',active_revision=revision.version,achieved_at=null where id=goal.id;
      summary := 'Agreed goal version: ' || (revision.config->>'title');
    elsif _data->>'decision'='decline' then
      update private.learning_goal_versions set state='declined',reviewer=_actor,reviewed_at=now() where goal_id=goal.id and version=revision.version;
      summary := 'Requested goal changes: ' || private.learning_text(_data,'feedback',1,500);
    else raise exception 'Choose a proposal decision.' using errcode='22023';
    end if;
    perform private.learning_notice(recipient,_plan.id,'Learning goal reviewed','Open the plan to see the decision on your proposal.');
    return jsonb_build_object('summary',summary,'details',jsonb_build_object('version',revision.version,
      'state',case when _data->>'decision'='accept' then 'accepted' else 'declined' end,'config',revision.config));
  end if;

  if _actor is distinct from _tutor then raise exception 'Only the assigned tutor can perform this action.' using errcode='42501'; end if;
  select v.config into config from private.learning_goal_versions v where v.goal_id=goal.id and v.version=goal.active_revision;
  if _action='confirmGoal' then
    if goal.status<>'active' or goal.achieved_at is not null or config->>'type'='habit'
      or not coalesce((private.learning_goal_result(goal,config)->>'eligible')::boolean,false) then
      raise exception 'This goal has not satisfied its completion requirements.' using errcode='PT409';
    end if;
    update private.learning_goals set achieved_at=now() where id=goal.id;
    perform private.learning_notice(_plan.student_id,_plan.id,'Learning goal achieved','Your tutor confirmed that the agreed requirements were met.');
    return jsonb_build_object('summary','Confirmed goal achievement: ' || (config->>'title'));
  end if;
  if _action='goalStatus' and goal.active_revision is not null and _data->>'status' in ('active','paused','archived') then
    update private.learning_goals set status=_data->>'status' where id=goal.id;
    return jsonb_build_object('summary','Changed goal status to ' || (_data->>'status'));
  end if;
  raise exception 'Choose a valid goal action.' using errcode='22023';
end;
$$;

create function private.learning_mark_baseline(_goal private.learning_goals,_entry private.learning_entries,_config jsonb)
returns void language plpgsql set search_path='' as $$
begin
  if _goal.baseline_id is null and private.learning_assessment_qualifies(_entry.data,_config) then
    update private.learning_goals set baseline_id=_entry.id where id=_goal.id and baseline_id is null;
  end if;
end;
$$;

revoke all on function private.learning_number(jsonb,text,numeric,numeric,boolean),
  private.learning_goal_config(jsonb,private.learning_plans),private.learning_grant(private.learning_plans,uuid),
  private.learning_edit_goal(private.learning_plans,uuid,uuid,text,jsonb),
  private.learning_mark_baseline(private.learning_goals,private.learning_entries,jsonb)
  from public,anon,authenticated;

create function public.apply_learning_action(_action text,_plan uuid,_version integer,_request uuid,_data jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  actor uuid := (select auth.uid()); role_name text; tutor uuid; chosen_tutor uuid;
  fingerprint bytea;
  existing private.learning_requests%rowtype; plan private.learning_plans%rowtype;
  lesson public.bookings%rowtype; skills jsonb; event jsonb; summary text; receipt jsonb;
begin
  perform private.assert_platform_available();
  select role into role_name from public.profiles where id=actor;
  if role_name is null or role_name not in ('student','tutor') or (role_name='tutor' and not private.learning_tutor_approved(actor)) then
    raise exception 'An approved tutor or learner account is required.' using errcode='42501';
  end if;
  if _request is null or _action is null or jsonb_typeof(_data) is distinct from 'object' or octet_length(_data::text)>16000 then
    raise exception 'Check your learning request and try again.' using errcode='22023';
  end if;
  fingerprint := sha256(convert_to(jsonb_build_array(_action,_plan,_version,_data)::text,'UTF8'));
  insert into private.learning_requests(actor_id,id,intent_hash) values (actor,_request,fingerprint) on conflict do nothing;
  if not found then
    select * into existing from private.learning_requests where actor_id=actor and id=_request;
    if existing.intent_hash is distinct from fingerprint then raise exception 'This request key has already been used.' using errcode='PT409'; end if;
    return existing.result;
  end if;

  if _action='enable' then
    if role_name<>'student' or _data->'adult' is distinct from 'true'::jsonb then
      raise exception 'Only learners who confirm they are 18 or older can enable their own records.' using errcode='42501';
    end if;
    insert into private.learning_clearances(student_id,basis,recorded_by) values(actor,'adult_declaration',actor) on conflict do nothing;
    if not exists(select 1 from private.learning_clearances where student_id=actor and revoked_at is null) then
      raise exception 'Contact support to restore access to learning records.' using errcode='42501';
    end if;
    receipt := jsonb_build_object('enabled',true);
  elsif _action='startPlan' then
    lesson := private.learning_eligible_booking(actor,(_data->>'bookingId')::uuid);
    perform 1 from private.learning_clearances where student_id=lesson.student_id and revoked_at is null for share;
    if not found then raise exception 'The learner must enable learning records before creating a plan.' using errcode='42501'; end if;
    if jsonb_typeof(_data->'skills') is distinct from 'array' or jsonb_array_length(_data->'skills') not between 1 and 20 then
      raise exception 'Enter between 1 and 20 skills or topics.' using errcode='22023';
    end if;
    if exists(select 1 from jsonb_array_elements(_data->'skills') skill
      where jsonb_typeof(skill)<>'string' or char_length(btrim(skill #>> '{}')) not between 1 and 120) then
      raise exception 'Keep each skill or topic between 1 and 120 characters.' using errcode='22023';
    end if;
    select jsonb_agg(jsonb_build_object('id',gen_random_uuid(),'title',btrim(skill),'criteria','Meet the agreed goal criteria independently.'))
      into skills from jsonb_array_elements_text(_data->'skills') as skill;
    insert into private.learning_plans(student_id,subject_id,title,context,review_date,skills)
      values (lesson.student_id,lesson.subject_id,private.learning_text(_data,'title',1,120),
        private.learning_text(_data,'context',0,180),private.learning_date(_data,'reviewDate'),skills)
      on conflict (student_id,subject_id) do nothing;
    select * into strict plan from private.learning_plans where student_id=lesson.student_id and subject_id=lesson.subject_id for update;
    if role_name='student' then
      perform private.learning_grant(plan,lesson.tutor_id);
      summary := 'Shared the plan with a tutor';
    elsif private.learning_current_tutor(plan.id) is distinct from actor and not exists(
      select 1 from private.learning_access where plan_id=plan.id and tutor_id=actor and
        (status='pending' and expires_at>now() or status='revoked' and updated_at>now()-interval '24 hours')
    ) then
      insert into private.learning_access(plan_id,tutor_id,status,expires_at) values(plan.id,actor,'pending',now()+interval '14 days')
        on conflict(plan_id,tutor_id) do update set status='pending',expires_at=excluded.expires_at,updated_at=now();
      perform private.learning_notice(lesson.student_id,plan.id,'Tutor requests learning plan access','Review the request before sharing records for this subject.');
      summary := 'Requested tutor access';
    end if;
  else
    perform 1 from private.learning_clearances c join private.learning_plans p on p.student_id=c.student_id
      where p.id=_plan and c.revoked_at is null for share of c;
    if not found then raise exception 'Learning plan unavailable.' using errcode='PT404'; end if;
    select * into strict plan from private.learning_plans where id=_plan for update;
    tutor := private.learning_current_tutor(plan.id);
    if actor<>plan.student_id and actor is distinct from tutor then
      raise exception 'Learning plan unavailable.' using errcode='PT404';
    end if;
    if _version is distinct from plan.version then
      raise exception 'The learning plan changed. Refresh and review the latest version.' using errcode='PT409';
    end if;

    if _action in ('approveAccess','declineAccess','revokeAccess') then
      if actor<>plan.student_id then raise exception 'Only the learner can manage tutor access.' using errcode='42501'; end if;
      chosen_tutor := (_data->>'tutorId')::uuid;
      if _action='approveAccess' then
        if not exists(select 1 from private.learning_access where plan_id=plan.id and tutor_id=chosen_tutor
            and status='pending' and expires_at>now()) or not private.learning_tutor_approved(chosen_tutor)
          or not exists(select 1 from public.bookings where student_id=actor and tutor_id=chosen_tutor and subject_id=plan.subject_id
            and status in ('confirmed','completed') and starts_at>=now()-interval '90 days') then
          raise exception 'This request no longer has an eligible booking.' using errcode='PT409';
        end if;
        perform private.learning_grant(plan,chosen_tutor);
        summary := 'Approved subject access for the tutor';
      else
        update private.learning_access set status='revoked',updated_at=now()
          where plan_id=plan.id and tutor_id=chosen_tutor and expires_at>now()
          and status=case when _action='revokeAccess' then 'active' else 'pending' end;
        if not found then raise exception 'This access request is no longer available.' using errcode='PT409'; end if;
        update private.learning_goal_versions v set state='declined',reviewed_at=now() from private.learning_goals g
          where g.id=v.goal_id and g.plan_id=plan.id and v.proposer=chosen_tutor and v.state='proposed';
        perform private.bump_workspace(chosen_tutor);
        summary := case when _action='revokeAccess' then 'Revoked tutor access' else 'Declined tutor access' end;
      end if;
    elsif _action in ('saveGoal','approveGoal','confirmGoal','goalStatus') then
      if tutor is null then raise exception 'Grant a tutor access before agreeing learning goals.' using errcode='PT409'; end if;
      event := private.learning_edit_goal(plan,actor,tutor,_action,_data);
      summary := event->>'summary';
    elsif _action='scheduleReview' then
      if actor is distinct from tutor then raise exception 'Only the assigned tutor can schedule a review.' using errcode='42501'; end if;
      update private.learning_plans set review_date=private.learning_date(_data,'reviewDate') where id=plan.id;
      summary := 'Scheduled a plan review: ' || private.learning_text(_data,'notes',1,2000);
    elsif _action in ('assessment','verifyAssessment','correctAssessment','submitEvidence','checkIn','reviewEvidence','addActivity','toggleActivity','feedback','reflection') then
      event := private.learning_save_entry(plan,actor,tutor,_action,_data);
      summary := event->>'summary';
    else raise exception 'Choose a valid learning action.' using errcode='22023';
    end if;
  end if;

  if plan.id is not null then
    if summary is not null then
      insert into private.learning_events(plan_id,actor_id,kind,summary,details)
        values (plan.id,actor,_action,summary,event->'details');
      update private.learning_plans set version=version+1,updated_at=now() where id=plan.id;
      perform private.bump_workspace(plan.student_id);
      tutor := private.learning_current_tutor(plan.id);
      if tutor is not null then perform private.bump_workspace(tutor); end if;
    end if;
    receipt := jsonb_build_object('planId',plan.id);
  end if;
  update private.learning_requests set result=receipt where actor_id=actor and id=_request;
  return receipt;
exception when invalid_text_representation or invalid_datetime_format or datetime_field_overflow or numeric_value_out_of_range then
  raise exception 'Check the values entered in the learning form.' using errcode='22023';
end;
$$;

create function public.manage_learning_clearance(_student uuid,_action text,_reference text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid := (select auth.uid()); c private.learning_clearances%rowtype; recipient record;
begin
  if not exists(select 1 from public.profiles where id=actor and role='superUser') then
    raise exception 'Superuser access required.' using errcode='42501';
  end if;
  if not exists(select 1 from public.profiles where id=_student and role='student') then
    raise exception 'Learner unavailable.' using errcode='PT404';
  end if;
  if _action='approve' then
    if char_length(coalesce(btrim(_reference),'')) not between 4 and 120 then
      raise exception 'Enter the reference for the documented authorisation.' using errcode='22023';
    end if;
    insert into private.learning_clearances(student_id,basis,recorded_by,reference) values(_student,'documented_authorisation',actor,btrim(_reference))
      on conflict(student_id) do update set basis=excluded.basis,recorded_by=actor,reference=excluded.reference,recorded_at=now(),revoked_at=null;
  elsif _action='revoke' then
    update private.learning_clearances set revoked_at=now() where student_id=_student and revoked_at is null;
    if not found then raise exception 'There is no active authorisation.' using errcode='PT409'; end if;
    for recipient in update private.learning_access a set status='revoked',updated_at=now() from private.learning_plans p
      where p.id=a.plan_id and p.student_id=_student and a.status in ('pending','active') returning a.tutor_id
    loop
      perform private.bump_workspace(recipient.tutor_id);
    end loop;
  elsif _action is distinct from 'view' then
    raise exception 'Choose a valid authorisation action.' using errcode='22023';
  end if;
  if _action<>'view' then perform private.bump_workspace(_student); end if;
  select * into c from private.learning_clearances where student_id=_student;
  return jsonb_build_object('enabled',c.student_id is not null and c.revoked_at is null,'basis',c.basis,'reference',c.reference);
end;
$$;

revoke all on function public.apply_learning_action(text,uuid,integer,uuid,jsonb), public.manage_learning_clearance(uuid,text,text) from public,anon,authenticated;
grant execute on function public.apply_learning_action(text,uuid,integer,uuid,jsonb), public.manage_learning_clearance(uuid,text,text) to authenticated;

create function public.my_learning_history(_plan uuid,_page integer default 1)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare actor uuid := (select auth.uid()); result jsonb;
begin
  perform private.assert_platform_available();
  if _page is null or _page not between 1 and 10000 then raise exception 'Choose a valid history page.' using errcode='22023'; end if;
  if not exists(select 1 from private.learning_plans p join private.learning_clearances c on c.student_id=p.student_id and c.revoked_at is null
    where p.id=_plan and (actor=p.student_id or actor=private.learning_current_tutor(p.id))) then
    raise exception 'Learning plan unavailable.' using errcode='PT404';
  end if;
  with rows as (
    select e.*,row_number() over (order by created_at desc,id desc) as position from
    (select * from private.learning_events where plan_id=_plan order by created_at desc,id desc
      offset (_page-1)*25 limit 26) e
  )
  select jsonb_build_object('events',coalesce(jsonb_agg(jsonb_build_object('id',id,'date',created_at,'text',summary,'details',details)
    order by position) filter (where position<=25),'[]'::jsonb),'hasMore',count(*)>25) into result from rows;
  return result;
end;
$$;
revoke all on function public.my_learning_history(uuid,integer) from public,anon,authenticated;
grant execute on function public.my_learning_history(uuid,integer) to authenticated;
notify pgrst,'reload schema';
