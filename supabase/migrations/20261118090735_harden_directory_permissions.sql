-- Retain the public projection while enforcing the caller's underlying RLS.
alter view public.tutor_directory set (security_invoker = true);
notify pgrst, 'reload schema';
