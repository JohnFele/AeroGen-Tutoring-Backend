alter table private.bug_report_screenshots add column created_at timestamptz not null default now();

create index guest_bug_screenshot_created_at on private.bug_report_screenshots(created_at)
  where enquiry_id is not null;

create function private.limit_guest_screenshot_uploads() returns trigger
language plpgsql set search_path = '' as $$
declare used bigint;
begin
  -- The anonymous RPC can also be called directly, outside Express's IP limit.
  perform pg_advisory_xact_lock(hashtextextended('guest bug screenshot quota',0));
  if exists (select 1 from private.bug_report_screenshots where enquiry_id = new.enquiry_id) then
    return new;
  end if;
  select coalesce(sum(octet_length(image)),0) into used
    from private.bug_report_screenshots where enquiry_id is not null
      and created_at > now() - interval '24 hours';
  if used + octet_length(new.image) > 50331648 then
    raise exception 'Guest screenshot uploads are temporarily at capacity. Remove the screenshot to submit the report now.' using errcode = 'PT429';
  end if;
  return new;
end;
$$;

create trigger guest_bug_screenshot_quota before insert on private.bug_report_screenshots
for each row when (new.enquiry_id is not null) execute function private.limit_guest_screenshot_uploads();
revoke all on function private.limit_guest_screenshot_uploads() from public, anon, authenticated;
