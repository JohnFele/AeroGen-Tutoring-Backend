-- Foreign-key inserts already hold KEY SHARE locks on tutor profiles.
-- NO KEY UPDATE serializes aggregate recalculation without conflicting with them.
create or replace function private.on_tutor_stats_change() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if TG_OP='INSERT' then
    perform 1 from public.tutor_profiles where user_id=new.tutor_id for no key update;
  elsif TG_OP='DELETE' then
    perform 1 from public.tutor_profiles where user_id=old.tutor_id for no key update;
  else
    perform 1 from public.tutor_profiles where user_id=any(array[old.tutor_id,new.tutor_id])
      order by user_id for no key update;
  end if;
  if TG_OP<>'DELETE' then perform private.refresh_tutor_public_stats(new.tutor_id); end if;
  if TG_OP<>'INSERT' then
    if TG_OP='DELETE' or old.tutor_id is distinct from new.tutor_id then
      perform private.refresh_tutor_public_stats(old.tutor_id);
    end if;
  end if;
  return null;
end; $$;
