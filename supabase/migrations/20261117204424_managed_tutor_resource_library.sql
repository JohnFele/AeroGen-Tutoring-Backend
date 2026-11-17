create table private.tutor_library_items (
  id text primary key check(id ~ '^[a-z0-9][a-z0-9-]{2,79}$'),
  kind text not null check(kind in ('resource','course')),
  title text not null check(char_length(btrim(title)) between 2 and 160),
  description text not null check(char_length(btrim(description)) between 10 and 2000),
  category text not null default 'Teaching practice' check(char_length(btrim(category)) between 2 and 80),
  format text not null default 'Guide' check(char_length(btrim(format)) between 2 and 50),
  minutes integer not null default 5 check(minutes between 1 and 1440),
  sections jsonb not null default '[]' check(jsonb_typeof(sections)='array'),
  lessons jsonb not null default '[]' check(jsonb_typeof(lessons)='array'),
  supporting_resource_id text references private.tutor_library_items(id),
  source_url text check(source_url is null or source_url ~ '^https://[^[:space:]]+$'),
  status text not null default 'draft' check(status in ('draft','published','archived')),
  version integer not null default 1,
  content_version integer not null default 1,
  updated_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table private.tutor_library_saves (
  owner uuid not null references public.profiles(id) on delete cascade,
  item_id text not null references private.tutor_library_items(id),
  primary key(owner,item_id)
);
create table private.tutor_course_progress (
  owner uuid not null references public.profiles(id) on delete cascade,
  item_id text not null references private.tutor_library_items(id),
  content_version integer not null,
  lesson_id text not null,
  completed_at timestamptz not null default now(),
  source text not null default 'quiz' check(source in ('quiz','browser_import')),
  primary key(owner,item_id,content_version,lesson_id)
);
create table private.tutor_library_imports (
  owner uuid primary key references public.profiles(id) on delete cascade,
  imported_at timestamptz not null default now()
);
alter table private.tutor_library_items enable row level security;
alter table private.tutor_library_saves enable row level security;
alter table private.tutor_course_progress enable row level security;
alter table private.tutor_library_imports enable row level security;
revoke all on private.tutor_library_items,private.tutor_library_saves,private.tutor_course_progress,private.tutor_library_imports from public,anon,authenticated;

create function private.tutor_library_account() returns uuid language plpgsql stable set search_path='' as $$
declare actor uuid := (select auth.uid());
begin
  if actor is null or not exists(select 1 from public.profiles p where p.id=actor and
    (p.role in ('admin','superUser') or (p.role='tutor' and exists(select 1 from public.tutor_profiles t where t.user_id=actor and t.is_approved)))) then
    raise exception 'Approved tutor or administrator access required.' using errcode='42501';
  end if;
  perform private.assert_platform_available();
  return actor;
end; $$;

create function public.my_tutor_resource_library() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare actor uuid:=private.tutor_library_account(); result jsonb;
begin
  select jsonb_build_object(
    'resources',coalesce((select jsonb_agg(jsonb_build_object('id',id,'title',title,'description',description,'category',category,
      'type',format,'minutes',minutes,'sections',sections,'sourceUrl',source_url,'updatedAt',updated_at,'version',version) order by title)
      from private.tutor_library_items where kind='resource' and status='published'),'[]'::jsonb),
    'courses',coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'title',i.title,'description',i.description,'contentVersion',i.content_version,
      'resourceId',(select r.id from private.tutor_library_items r where r.id=i.supporting_resource_id and r.status='published'),
      'lessons',(select coalesce(jsonb_agg(lesson-'answer'-'explanation' order by position),'[]'::jsonb)
        from jsonb_array_elements(i.lessons) with ordinality as items(lesson,position))) order by i.title)
      from private.tutor_library_items i where i.kind='course' and i.status='published'),'[]'::jsonb),
    'saved',coalesce((select jsonb_agg(s.item_id) from private.tutor_library_saves s join private.tutor_library_items i on i.id=s.item_id
      where s.owner=actor and i.status='published'),'[]'::jsonb),
    'completedLessons',coalesce((select jsonb_agg(p.item_id||':'||p.content_version||':'||p.lesson_id)
      from private.tutor_course_progress p join private.tutor_library_items i on i.id=p.item_id and i.content_version=p.content_version
      where p.owner=actor and i.status='published' and exists(select 1 from jsonb_array_elements(i.lessons) lesson where lesson->>'id'=p.lesson_id)),'[]'::jsonb)
  ) into result;
  return result;
end; $$;

create function public.save_tutor_library_item(_id text,_saved boolean) returns void
language plpgsql security definer set search_path='' as $$
declare actor uuid:=private.tutor_library_account();
begin
  if _saved is null or not exists(select 1 from private.tutor_library_items where id=_id and status='published') then
    raise exception 'This library item is unavailable.' using errcode='PT404';
  end if;
  if _saved then insert into private.tutor_library_saves(owner,item_id) values(actor,_id) on conflict do nothing;
  else delete from private.tutor_library_saves where owner=actor and item_id=_id; end if;
end; $$;

create function public.answer_tutor_course_lesson(_id text,_lesson text,_answer integer,_version integer) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=private.tutor_library_account(); course private.tutor_library_items; lesson jsonb; correct boolean;
begin
  select * into course from private.tutor_library_items where id=_id and kind='course' and status='published' for share;
  if not found then raise exception 'This course is unavailable.' using errcode='PT404'; end if;
  if _version is distinct from course.content_version then raise exception 'This course was updated. Reload the library to continue with the current version.' using errcode='PT409'; end if;
  select value into lesson from jsonb_array_elements(course.lessons) where value->>'id'=_lesson;
  if lesson is null or _answer is null or _answer<0 or _answer>=jsonb_array_length(lesson->'options') then
    raise exception 'Choose an answer for this lesson.' using errcode='22023';
  end if;
  correct:=_answer=(lesson->>'answer')::integer;
  if correct then
    insert into private.tutor_course_progress(owner,item_id,content_version,lesson_id)
      values(actor,_id,course.content_version,_lesson) on conflict do nothing;
  end if;
  return jsonb_build_object('correct',correct,'explanation',case when correct then lesson->>'explanation' else 'Review the lesson and try another answer.' end);
end; $$;

create function public.import_tutor_library_progress(_saved text[],_completed text[]) returns void
language plpgsql security definer set search_path='' as $$
declare actor uuid:=private.tutor_library_account();
begin
  if coalesce(cardinality(_saved),0)>200 or coalesce(cardinality(_completed),0)>500 then
    raise exception 'There are too many browser records to import.' using errcode='22023';
  end if;
  insert into private.tutor_library_imports(owner) values(actor) on conflict do nothing;
  if not found then return; end if;
  insert into private.tutor_library_saves(owner,item_id)
    select actor,id from private.tutor_library_items where status='published' and id=any(_saved) on conflict do nothing;
  insert into private.tutor_course_progress(owner,item_id,content_version,lesson_id,source)
    select actor,i.id,i.content_version,lesson->>'id','browser_import'
    from private.tutor_library_items i cross join jsonb_array_elements(i.lessons) lesson
    where i.kind='course' and i.status='published' and i.content_version=1 and i.id in ('effective-lessons','online-teaching','platform-practice') and lesson->>'id' in ('clear-outcomes','independent-check','access','participation','baseline','next-step') and lesson->>'id'=any(_completed)
    on conflict do nothing;
end; $$;

create function public.admin_tutor_library() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
  if not private.is_platform_admin() then raise exception 'Administrator access required.' using errcode='42501'; end if;
  return coalesce((select jsonb_agg(to_jsonb(i) order by kind,title) from private.tutor_library_items i),'[]'::jsonb);
end; $$;

create function public.admin_save_tutor_library_item(_item jsonb,_expected integer) returns jsonb
language plpgsql security definer set search_path='' as $$
declare old_item private.tutor_library_items; edited private.tutor_library_items; section jsonb; lesson jsonb; option jsonb;
begin
  if not private.is_platform_admin() then raise exception 'Administrator access required.' using errcode='42501'; end if;
  perform private.assert_platform_available();
  if jsonb_typeof(_item) is distinct from 'object' or octet_length(_item::text)>180000
    or exists(select 1 from jsonb_object_keys(_item) field where field not in
      ('id','kind','title','description','category','format','minutes','sections','lessons','supporting_resource_id','source_url','status')) then
    raise exception 'Enter valid library content up to 180 KB.' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('tutor-library:'||coalesce(_item->>'id',''),0));
  select * into old_item from private.tutor_library_items where id=_item->>'id' for update;
  if found then
    if _expected is distinct from old_item.version then raise exception 'This item changed. Reload before saving.' using errcode='PT409'; end if;
    if _item->>'kind' is distinct from old_item.kind then raise exception 'The library item type cannot change.' using errcode='22023'; end if;
  elsif _expected is not null then raise exception 'This item is unavailable. Reload the library.' using errcode='PT409'; end if;
  edited:=jsonb_populate_record(old_item,_item);
  edited.sections:=coalesce(edited.sections,'[]'::jsonb); edited.lessons:=coalesce(edited.lessons,'[]'::jsonb);
  if edited.id is null or edited.id !~ '^[a-z0-9][a-z0-9-]{2,79}$' or edited.kind is null or edited.kind not in ('resource','course')
    or char_length(btrim(coalesce(edited.title,''))) not between 2 and 160
    or char_length(btrim(coalesce(edited.description,''))) not between 10 and 2000
    or char_length(btrim(coalesce(edited.category,''))) not between 2 and 80
    or char_length(btrim(coalesce(edited.format,''))) not between 2 and 50
    or edited.minutes is null or edited.minutes not between 1 and 1440
    or edited.status is null or edited.status not in ('draft','published','archived')
    or (edited.source_url is not null and (char_length(edited.source_url)>2048 or edited.source_url !~ '^https://[^[:space:]]+$'))
    or jsonb_typeof(edited.sections)<>'array' or jsonb_typeof(edited.lessons)<>'array' then
    raise exception 'Complete the title, description, category, format, reading time and status.' using errcode='22023';
  end if;
  if edited.kind='resource' then
    if jsonb_array_length(edited.sections) not between 1 and 20 or jsonb_array_length(edited.lessons)<>0 then
      raise exception 'Add between 1 and 20 resource sections.' using errcode='22023';
    end if;
    for section in select value from jsonb_array_elements(edited.sections) loop
      if jsonb_typeof(section)<>'object' or exists(select 1 from jsonb_object_keys(section) key where key not in ('heading','body')) or jsonb_typeof(section->'heading') is distinct from 'string' or jsonb_typeof(section->'body') is distinct from 'string' or char_length(btrim(coalesce(section->>'heading',''))) not between 1 and 160
        or char_length(btrim(coalesce(section->>'body',''))) not between 1 and 12000 then
        raise exception 'Every section needs a heading and content.' using errcode='22023';
      end if;
    end loop;
  else
    if jsonb_array_length(edited.lessons) not between 1 and 20 or jsonb_array_length(edited.sections)<>0 then
      raise exception 'Add between 1 and 20 course lessons.' using errcode='22023';
    end if;
    if (select count(distinct value->>'id') from jsonb_array_elements(edited.lessons))<>jsonb_array_length(edited.lessons) then
      raise exception 'Each course lesson needs its own identifier.' using errcode='22023';
    end if;
    for lesson in select value from jsonb_array_elements(edited.lessons) loop
      if jsonb_typeof(lesson)<>'object' or exists(select 1 from jsonb_object_keys(lesson) key where key not in ('id','title','body','question','options','answer','explanation')) or jsonb_typeof(lesson->'title') is distinct from 'string' or jsonb_typeof(lesson->'body') is distinct from 'string' or jsonb_typeof(lesson->'question') is distinct from 'string' or jsonb_typeof(lesson->'explanation') is distinct from 'string' or jsonb_typeof(lesson->'answer') is distinct from 'number' or coalesce(lesson->>'id','') !~ '^[a-z0-9][a-z0-9-]{2,79}$'
        or char_length(btrim(coalesce(lesson->>'title',''))) not between 1 and 160
        or char_length(btrim(coalesce(lesson->>'body',''))) not between 1 and 12000
        or char_length(btrim(coalesce(lesson->>'question',''))) not between 1 and 500
        or char_length(btrim(coalesce(lesson->>'explanation',''))) not between 1 and 2000
        or jsonb_typeof(lesson->'options') is distinct from 'array'
        or jsonb_array_length(lesson->'options') not between 2 and 6
        or coalesce(lesson->>'answer','') !~ '^[0-5]$'
        or (lesson->>'answer')::integer>=jsonb_array_length(lesson->'options') then
        raise exception 'Complete each lesson, question, 2 to 6 answers, correct answer and explanation.' using errcode='22023';
      end if;
      if (select count(distinct btrim(value#>>'{}')) from jsonb_array_elements(lesson->'options'))<>jsonb_array_length(lesson->'options') then raise exception 'Use a different answer for each option.' using errcode='22023'; end if;
      for option in select value from jsonb_array_elements(lesson->'options') loop
        if jsonb_typeof(option)<>'string' or char_length(btrim(option#>>'{}')) not between 1 and 300 then
          raise exception 'Every answer must contain 1 to 300 characters.' using errcode='22023';
        end if;
      end loop;
    end loop;
  end if;
  if edited.supporting_resource_id is not null and (edited.kind<>'course' or not exists(
    select 1 from private.tutor_library_items where id=edited.supporting_resource_id and kind='resource' and status='published')) then
    raise exception 'Choose a published supporting resource.' using errcode='22023';
  end if;
  edited.version:=coalesce(old_item.version,0)+1;
  edited.content_version:=coalesce(old_item.content_version,1)+case when old_item.id is not null and old_item.lessons is distinct from edited.lessons then 1 else 0 end;
  insert into private.tutor_library_items(id,kind,title,description,category,format,minutes,sections,lessons,supporting_resource_id,source_url,status,version,content_version,updated_by)
  values(edited.id,edited.kind,btrim(edited.title),btrim(edited.description),btrim(edited.category),btrim(edited.format),edited.minutes,
    edited.sections,edited.lessons,edited.supporting_resource_id,edited.source_url,edited.status,edited.version,edited.content_version,(select auth.uid()))
  on conflict(id) do update set title=excluded.title,description=excluded.description,category=excluded.category,format=excluded.format,
    minutes=excluded.minutes,sections=excluded.sections,lessons=excluded.lessons,supporting_resource_id=excluded.supporting_resource_id,
    source_url=excluded.source_url,status=excluded.status,version=excluded.version,content_version=excluded.content_version,
    updated_by=excluded.updated_by,updated_at=now()
  returning * into edited;
  return to_jsonb(edited);
exception when data_exception or check_violation then
  if sqlstate='22023' then raise; end if;
  raise exception 'Check the library fields and content sizes.' using errcode='22023';
end; $$;

create function public.admin_archive_tutor_library_item(_id text,_expected integer) returns jsonb
language plpgsql security definer set search_path='' as $$
declare item private.tutor_library_items;
begin
  if not private.is_platform_admin() then raise exception 'Administrator access required.' using errcode='42501'; end if;
  perform private.assert_platform_available();
  update private.tutor_library_items set status='archived',version=version+1,updated_by=(select auth.uid()),updated_at=now()
  where id=_id and version=_expected returning * into item;
  if not found then raise exception 'This item changed or is unavailable. Reload before archiving.' using errcode='PT409'; end if;
  return to_jsonb(item);
end; $$;

revoke all on function private.tutor_library_account() from public,anon,authenticated;
revoke all on function public.my_tutor_resource_library(),public.save_tutor_library_item(text,boolean),
  public.answer_tutor_course_lesson(text,text,integer,integer),public.import_tutor_library_progress(text[],text[]),
  public.admin_tutor_library(),public.admin_save_tutor_library_item(jsonb,integer),public.admin_archive_tutor_library_item(text,integer)
  from public,anon;
grant execute on function public.my_tutor_resource_library(),public.save_tutor_library_item(text,boolean),
  public.answer_tutor_course_lesson(text,text,integer,integer),public.import_tutor_library_progress(text[],text[]),
  public.admin_tutor_library(),public.admin_save_tutor_library_item(jsonb,integer),public.admin_archive_tutor_library_item(text,integer)
  to authenticated;


insert into private.tutor_library_items(id,kind,title,description,category,format,minutes,sections,lessons,supporting_resource_id,status)
select item->>'id',item->>'kind',item->>'title',item->>'description',item->>'category',item->>'format',(item->>'minutes')::integer,
  item->'sections',item->'lessons',item->>'supporting_resource_id','published' from jsonb_array_elements('[{"id":"lesson-planning","kind":"resource","title":"Lesson planning template","description":"Turn a learning goal into a focused lesson, an independent check, and a clear next step.","category":"Teaching guides","format":"Template","minutes":4,"sections":[{"heading":"Before the lesson","body":"Student / course: __________\nTopic and date: __________\nWhat can the learner already do? __________\nBy the end, the learner should be able to: __________\nEvidence that will show success: __________"},{"heading":"A purposeful lesson structure","body":"1. Retrieve: ask the learner to explain or try a prerequisite task.\n2. Model: demonstrate the method and explain your choices.\n3. Practise together: offer prompts, then reduce support.\n4. Apply independently: use a new task to check understanding.\n5. Reflect: ask what changed and what still needs practice."},{"heading":"After the lesson","body":"What was demonstrated independently? __________\nWhat still required guidance? __________\nEvidence and feedback to record: __________\nPractice before the next session: __________\nNext review date: __________"}],"lessons":[],"supporting_resource_id":null},{"id":"engagement","kind":"resource","title":"Student engagement strategies","description":"Practical prompts for discussion, active practice, and checking understanding at any study level.","category":"Teaching guides","format":"Guide","minutes":5,"sections":[{"heading":"Ask for thinking, not just answers","body":"Ask “What would you try first, and why?” Give time to think before offering help. Invite the learner to compare two possible approaches and explain their choice."},{"heading":"Make the learner do the work","body":"Alternate short explanations with student attempts. Use a new example, an error to diagnose, or a claim to justify. For an essay or project, ask the learner to explain the evidence behind a decision."},{"heading":"Respond to the learning environment","body":"Check whether the learner can access the materials. Offer a text version of instructions and a task that can be attempted offline. Agree a manageable next step rather than increasing work automatically."}],"lessons":[],"supporting_resource_id":null},{"id":"assessment-pack","kind":"resource","title":"Assessment & feedback toolkit","description":"Diagnostic prompts, an adaptable skill rubric, and feedback structures linked to learning plans.","category":"Assessment & progress","format":"Toolkit","minutes":6,"sections":[{"heading":"Starting diagnostic","body":"Choose a few tasks covering the intended skill and its prerequisites. Record the task, date, original mark / maximum, scope, difficulty, and whether support was provided. Keep this context for later comparisons."},{"heading":"Adaptable skill rubric","body":"Needs support: substantial guidance is needed.\nDeveloping: some parts are completed with help.\nIndependent: agreed criteria are met without prompts.\nSecure: the skill is demonstrated consistently across suitable tasks.\nDefine the specific criteria for your subject before using these levels."},{"heading":"Feedback that leads to action","body":"Evidence: “You demonstrated…”\nGap: “The next part to improve is…”\nAction: “Before our next lesson, try…”\nReview: “We will check this by…”\nRecord confidence separately from assessed ability. Completing practice is not evidence of mastery on its own."}],"lessons":[],"supporting_resource_id":null},{"id":"review-template","kind":"resource","title":"Learner review conversation","description":"A structured conversation to review evidence, update a target, and agree the next milestone.","category":"Assessment & progress","format":"Template","minutes":3,"sections":[{"heading":"Review the evidence together","body":"Original goal: __________\nStarting evidence: __________\nLatest comparable evidence: __________\nWhat can the learner now do independently? __________\nWhat remains uncertain or unassessed? __________"},{"heading":"Agree the next step","body":"Student reflection: __________\nTutor feedback: __________\nKeep, revise, pause, or replace this goal? __________\nReason for any change: __________\nNext task and review date: __________\nUse the learning plan history to preserve target changes."}],"lessons":[],"supporting_resource_id":null},{"id":"session-agreement","kind":"resource","title":"Session expectations checklist","description":"Prepare a clear conversation about lesson format, communication, fees, and expectations.","category":"Business tools","format":"Checklist","minutes":3,"sections":[{"heading":"Agree practical expectations","body":"Subject, course, and learning priorities: __________\nLesson format, location, and accessibility needs: __________\nSession duration and scheduling: __________\nFees and payment arrangements: __________\nHow changes or cancellations will be communicated: __________"},{"heading":"Keep communication clear","body":"Preferred communication channel: __________\nExpected response times: __________\nMaterials each person will prepare: __________\nHow progress and feedback will be shared: __________\nThis is a preparation checklist, not a contract. Confirm your arrangements separately with your client."}],"lessons":[],"supporting_resource_id":null},{"id":"marketing-kit","kind":"resource","title":"Tutor profile & marketing workbook","description":"Write a clear tutor introduction and describe your teaching approach without unsupported claims.","category":"Business tools","format":"Workbook","minutes":5,"sections":[{"heading":"Build your introduction","body":"I help [learner group] with [subjects / skills].\nMy relevant qualifications and experience are [verified details].\nIn a lesson, we [describe your approach].\nWe track progress through [examples of evidence and review].\nI offer [online / in-person] sessions in [area / availability]."},{"heading":"Before publishing","body":"Check qualifications and experience for accuracy. Use your own materials or content you have permission to use. Avoid guaranteed grade improvements. Ask permission before sharing student work, names, or testimonials. Make the next booking step clear."}],"lessons":[],"supporting_resource_id":null},{"id":"effective-lessons","kind":"course","title":"Plan lessons around learning","description":"Practise setting outcomes and checking understanding with evidence.","category":"Teaching practice","format":"Self-study course","minutes":15,"sections":[],"lessons":[{"id":"clear-outcomes","title":"Set an observable outcome","body":"Start with something the learner should be able to do. “Understand algebra” is difficult to check. “Solve a pair of linear equations independently and explain the method” gives you an action and evidence. Choose a task that matches the learner’s course and starting point.","question":"Which outcome gives the clearest evidence of learning?","options":["Study algebra for an hour","Solve a new equation independently and explain each step","Finish all the slides"],"answer":1,"explanation":"An independent task and explanation show what the learner can actually do."},{"id":"independent-check","title":"Check independence","body":"A learner may succeed while following your worked example. Before raising a skill level, remove the prompts and use a new task covering the same skill. Record whether the work was independent or guided. Use the result to choose the next activity.","question":"A learner completes a task only after several prompts. How should you record it?","options":["Independent mastery","No learning occurred","Guided work, with feedback on the next independent attempt"],"answer":2,"explanation":"Guided success is useful evidence, but it should not be labelled independent mastery."}],"supporting_resource_id":"lesson-planning"},{"id":"online-teaching","kind":"course","title":"Teach effectively online","description":"Prepare accessible instructions and keep the learner actively involved.","category":"Teaching practice","format":"Self-study course","minutes":15,"sections":[],"lessons":[{"id":"access","title":"Prepare for different environments","body":"Ask how the learner will join and access materials. Send concise instructions in text, use readable documents, and provide an offline task where practical. Agree what happens if the connection drops. Avoid assuming every learner has a laptop, fast internet, or a quiet room.","question":"What is a useful preparation step for a learner with an unreliable connection?","options":["Provide a text task and agree a reconnection plan","Require continuous video","Cancel all independent practice"],"answer":0,"explanation":"A task they can access and a clear fallback help the lesson continue."},{"id":"participation","title":"Make thinking visible","body":"Use a short explanation, then ask the learner to attempt a task, annotate a solution, or describe a decision. Ask follow-up questions about their reasoning. Let the learner show uncertainty so you can adapt your support.","question":"Which check gives you more information than asking “Do you understand?”","options":["Ask the learner to nod","Explain the same example again","Ask the learner to solve a new example and explain the approach"],"answer":2,"explanation":"An attempt and explanation make the learner’s reasoning visible."}],"supporting_resource_id":"engagement"},{"id":"platform-practice","kind":"course","title":"Use AeroGen learning plans","description":"Connect goals, submissions, and reviews to the progress dashboard.","category":"Teaching practice","format":"Self-study course","minutes":15,"sections":[],"lessons":[{"id":"baseline","title":"Measure improvement fairly","body":"Create an assessment goal, then record a starting diagnostic with its original mark and maximum. Later results should cover comparable scope and difficulty. Only verified, independent, comparable results enter the goal comparison. A change from 40% to 58% is an increase of 18 percentage points.","question":"Which result should contribute to the same goal’s assessment trend?","options":["An unverified mark from an unrelated module","A verified independent assessment of comparable scope and difficulty","Hours spent practising"],"answer":1,"explanation":"The comparison needs relevant evidence under comparable conditions."},{"id":"next-step","title":"Close the feedback loop","body":"Review submitted work, record the demonstrated skill level and conditions, and leave a specific next step. Ask for another attempt where needed. Assign practice separately and schedule a plan review. Keep student confidence separate from assessed ability.","question":"A learner completes three practice activities. What should change automatically?","options":["The practice habit goal","Every skill becomes Secure","Their school mark"],"answer":0,"explanation":"Activity completion updates the habit goal; academic improvement needs assessment evidence."}],"supporting_resource_id":"assessment-pack"}]'::jsonb) item;
