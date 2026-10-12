-- ART SPEAKS WHERE WORDS END - database setup
-- Paste this whole file into Supabase > SQL Editor > Run.

create extension if not exists pgcrypto;

-- 1. Feedback table -------------------------------------------------
create table if not exists public.feedback (
  id          uuid primary key default gen_random_uuid(),
  created_at  timestamptz not null default now(),
  emotion     text not null
              check (emotion in ('peaceful','emotional','inspired','thoughtful','amazed','happy')),
  rating      smallint not null check (rating between 1 and 5),
  spoke_to    text[] not null default '{}'
              check (spoke_to <@ array['artwork','creativity','concept','display']::text[]),
  comment     text check (comment is null or char_length(comment) <= 1000),
  name        text check (name is null or char_length(name) <= 80),
  contact     text check (contact is null or char_length(contact) <= 120)
);

create index if not exists feedback_created_idx on public.feedback (created_at desc);

-- 2. Admin list -----------------------------------------------------
create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);

alter table public.admins   enable row level security;
alter table public.feedback enable row level security;

-- Nobody can read the admins table directly (no policies, no grants).
revoke all on public.admins from anon, authenticated;

create or replace function public.is_admin()
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;
revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to authenticated;

-- 3. Permissions ----------------------------------------------------
revoke all on public.feedback from anon, authenticated;
grant insert on public.feedback to anon, authenticated;
grant select, delete on public.feedback to authenticated;

drop policy if exists "anyone can submit"   on public.feedback;
drop policy if exists "admin can read"      on public.feedback;
drop policy if exists "admin can delete"    on public.feedback;

create policy "anyone can submit" on public.feedback
  for insert to anon, authenticated
  with check (true);                      -- limits are enforced by the CHECK rules above

create policy "admin can read" on public.feedback
  for select to authenticated
  using (public.is_admin());

create policy "admin can delete" on public.feedback
  for delete to authenticated
  using (public.is_admin());

-- 4. Spam brake: max 30 new submissions per minute across the site ---
create or replace function public.feedback_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if (select count(*) from public.feedback
      where created_at > now() - interval '1 minute') >= 30 then
    raise exception 'Too many submissions, please try again shortly.';
  end if;
  return new;
end;
$$;

drop trigger if exists feedback_rate_limit_trg on public.feedback;
create trigger feedback_rate_limit_trg
  before insert on public.feedback
  for each row execute function public.feedback_rate_limit();
