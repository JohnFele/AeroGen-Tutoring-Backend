grant update (first_name, last_name, phone, location, bio) on public.profiles to authenticated;

drop policy if exists "Users can update their own editable profile" on public.profiles;
create policy "Users can update their own editable profile"
on public.profiles
for update
to authenticated
using ((select auth.uid()) = id)
with check ((select auth.uid()) = id);
