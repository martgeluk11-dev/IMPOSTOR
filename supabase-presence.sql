-- IMPOSTOR inactive-player cleanup
-- Run once in Supabase SQL Editor after the original supabase-schema.sql.

alter table public.impostor_players
  add column if not exists last_seen timestamptz not null default now();

create index if not exists impostor_players_last_seen_idx
  on public.impostor_players(last_seen);

create or replace function public.impostor_sweep_inactive()
returns integer
language plpgsql
security definer
set search_path=public
as $$
declare
  r record;
  removed_count integer := 0;
  remaining_count integer;
  next_host uuid;
  gs jsonb;
  stale_impostor boolean;
begin
  for r in
    select id, host_id, game_state
    from public.impostor_rooms
    where exists (
      select 1 from public.impostor_players p
      where p.room_id = impostor_rooms.id
        and p.last_seen < now() - interval '2 minutes'
    )
    for update
  loop
    gs := r.game_state;
    stale_impostor := false;

    if gs is not null and gs->>'phase' <> 'results' then
      select exists (
        select 1 from public.impostor_players p
        where p.room_id = r.id
          and p.user_id::text = gs->>'impostor'
          and p.last_seen < now() - interval '2 minutes'
      ) into stale_impostor;
    end if;

    delete from public.impostor_players
    where room_id = r.id
      and last_seen < now() - interval '2 minutes';
    get diagnostics removed_count = removed_count + row_count;

    select count(*) into remaining_count
    from public.impostor_players where room_id = r.id;

    if remaining_count = 0 then
      delete from public.impostor_rooms where id = r.id;
      continue;
    end if;

    if not exists (
      select 1 from public.impostor_players
      where room_id = r.id and user_id = r.host_id
    ) then
      select user_id into next_host
      from public.impostor_players
      where room_id = r.id
      order by joined_at asc
      limit 1;

      update public.impostor_rooms
      set host_id = next_host, updated_at = now()
      where id = r.id;
    end if;

    if gs is not null and gs->>'phase' <> 'results'
       and (stale_impostor or remaining_count < 2) then
      gs := jsonb_set(gs, '{phase}', '"results"'::jsonb, true);
      gs := jsonb_set(
        gs, '{result}',
        jsonb_build_object(
          'winner', case when stale_impostor then 'crew' else 'impostor' end,
          'detail', case
            when stale_impostor then 'The impostor was inactive and left the game.'
            else 'Not enough active players remained.'
          end,
          'word', gs->>'word',
          'impostor', gs->>'impostor'
        ),
        true
      );
      update public.impostor_rooms
      set game_state = gs, status = 'finished', updated_at = now()
      where id = r.id;
    end if;
  end loop;

  return removed_count;
end;
$$;

create or replace function public.impostor_heartbeat(p_room_id uuid)
returns integer
language plpgsql
security definer
set search_path=public
as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Sign in required'; end if;

  update public.impostor_players
  set last_seen = now()
  where room_id = p_room_id and user_id = uid;

  if not found then raise exception 'You are no longer in this room'; end if;

  return public.impostor_sweep_inactive();
end;
$$;

grant execute on function public.impostor_heartbeat(uuid) to authenticated;

-- Supabase pg_cron runs independently, so empty rooms are cleaned up
-- even when every browser tab has been closed.
create extension if not exists pg_cron with schema pg_catalog;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'impostor-inactive-cleanup') then
    perform cron.unschedule('impostor-inactive-cleanup');
  end if;
  perform cron.schedule(
    'impostor-inactive-cleanup',
    '* * * * *',
    'select public.impostor_sweep_inactive();'
  );
end
$$;
