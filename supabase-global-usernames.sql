-- IMPOSTOR: globally unique usernames (case-insensitive).
-- Run this entire file once in Supabase SQL Editor.

create table if not exists public.impostor_usernames (
  user_id uuid primary key references auth.users(id) on delete cascade,
  username text not null,
  username_key text not null unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint impostor_username_length check (char_length(username) between 3 and 16)
);

alter table public.impostor_usernames enable row level security;
revoke all on public.impostor_usernames from anon, authenticated;

-- Reserve existing registered usernames first. If old accounts have duplicate
-- names, keep the first and give the others a deterministic unique suffix.
do $$
declare u record; base_name text; candidate text; candidate_key text; suffix text;
begin
  for u in
    select id, raw_user_meta_data->>'display_name' as display_name
    from auth.users
    where coalesce(raw_user_meta_data->>'display_name','') <> ''
    order by created_at, id
  loop
    base_name := btrim(regexp_replace(u.display_name, '\s+', ' ', 'g'));
    if char_length(base_name) < 3 or char_length(base_name) > 16 or base_name !~ '^[A-Za-z0-9_ ]+$' then
      continue;
    end if;
    candidate := base_name;
    candidate_key := lower(candidate);
    if exists(select 1 from public.impostor_usernames where username_key=candidate_key and user_id<>u.id) then
      suffix := substr(md5(u.id::text),1,4);
      candidate := left(base_name,12) || suffix;
      candidate_key := lower(candidate);
      while exists(select 1 from public.impostor_usernames where username_key=candidate_key and user_id<>u.id) loop
        suffix := substr(md5(random()::text || u.id::text),1,4);
        candidate := left(base_name,12) || suffix;
        candidate_key := lower(candidate);
      end loop;
      update auth.users
      set raw_user_meta_data=jsonb_set(coalesce(raw_user_meta_data,'{}'::jsonb),'{display_name}',to_jsonb(candidate),true)
      where id=u.id;
    end if;
    insert into public.impostor_usernames(user_id,username,username_key)
    values(u.id,candidate,candidate_key)
    on conflict(user_id) do nothing;
  end loop;
end $$;

create or replace function public.impostor_claim_username(p_username text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare uid uuid := auth.uid(); clean_name text; clean_key text;
begin
  if uid is null then raise exception 'Sign in required'; end if;
  clean_name := btrim(regexp_replace(coalesce(p_username,''), '\s+', ' ', 'g'));
  if char_length(clean_name) < 3 or char_length(clean_name) > 16 or clean_name !~ '^[A-Za-z0-9_ ]+$' then
    raise exception 'Username must be 3–16 characters and use only letters, numbers, spaces or _.';
  end if;
  clean_key := lower(clean_name);
  begin
    insert into public.impostor_usernames(user_id,username,username_key,updated_at)
    values(uid,clean_name,clean_key,now())
    on conflict(user_id) do update
      set username=excluded.username, username_key=excluded.username_key, updated_at=now();
  exception when unique_violation then
    return jsonb_build_object('ok',false,'reason','taken');
  end;
  return jsonb_build_object('ok',true,'username',clean_name);
end;
$$;

revoke all on function public.impostor_claim_username(text) from public;
grant execute on function public.impostor_claim_username(text) to authenticated;
