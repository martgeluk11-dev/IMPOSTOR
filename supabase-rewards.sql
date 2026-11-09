-- IMPOSTOR coins + XP progression
-- Run once in Supabase SQL Editor after supabase-schema.sql.

alter table public.impostor_players
  add column if not exists coins integer not null default 0,
  add column if not exists xp integer not null default 0,
  add column if not exists level integer not null default 1;

alter table public.impostor_rooms
  add column if not exists rewards_paid boolean not null default false;

-- Account-level profile: progression survives leaving rooms and joining new ones.
create table if not exists public.impostor_profiles (
  user_id uuid primary key,
  coins integer not null default 0,
  xp integer not null default 0,
  level integer not null default 1,
  updated_at timestamptz not null default now()
);
alter table public.impostor_profiles enable row level security;

create or replace function public.impostor_my_profile()
returns jsonb
language plpgsql
security definer
set search_path=public
as $
declare uid uuid := auth.uid(); profile_row public.impostor_profiles;
begin
  if uid is null then raise exception 'Sign in required'; end if;
  insert into public.impostor_profiles(user_id) values(uid)
  on conflict(user_id) do nothing;
  select * into profile_row from public.impostor_profiles where user_id=uid;
  return jsonb_build_object('coins',profile_row.coins,'xp',profile_row.xp,'level',profile_row.level);
end;
$;
grant execute on function public.impostor_my_profile() to authenticated;

create or replace function public.impostor_pay_match_rewards()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  winner text;
  impostor_id text;
begin
  if NEW.game_state is null
     or NEW.game_state->>'phase' <> 'results'
     or OLD.rewards_paid = true
     or NEW.rewards_paid = true then
    return NEW;
  end if;

  winner := NEW.game_state->'result'->>'winner';
  impostor_id := NEW.game_state->'result'->>'impostor';

  if winner not in ('crew', 'impostor') or impostor_id is null then
    return NEW;
  end if;

  insert into public.impostor_profiles(user_id)
  select user_id from public.impostor_players where room_id=NEW.id
  on conflict(user_id) do nothing;

  update public.impostor_profiles profile
  set
    coins = profile.coins + case
      when winner = 'impostor' and player.user_id::text = impostor_id then 60
      when winner = 'crew' and player.user_id::text <> impostor_id then 25
      else 0
    end,
    xp = profile.xp + case
      when winner = 'impostor' and player.user_id::text = impostor_id then 160
      when winner = 'crew' and player.user_id::text <> impostor_id then 100
      else 15
    end,
    updated_at = now()
  from public.impostor_players player
  where player.room_id=NEW.id and player.user_id=profile.user_id;

  update public.impostor_profiles
  set level = floor(sqrt(xp / 100.0))::integer + 1
  where user_id in (select user_id from public.impostor_players where room_id=NEW.id);

  NEW.rewards_paid := true;
  return NEW;
end;
$$;

drop trigger if exists impostor_match_rewards on public.impostor_rooms;
create trigger impostor_match_rewards
before update of game_state on public.impostor_rooms
for each row
execute function public.impostor_pay_match_rewards();

-- Include persistent player progression in each private, member-filtered snapshot.
create or replace function public.impostor_snapshot(p_room_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=public
as $$
declare
  r public.impostor_rooms;
  uid uuid := auth.uid();
  player_json jsonb;
  gs jsonb;
  hints_json jsonb := '{}'::jsonb;
  submitted_json jsonb := '[]'::jsonb;
  votes_json jsonb := '[]'::jsonb;
  private_json jsonb;
begin
  select * into r from public.impostor_rooms where id=p_room_id;
  if not found or not public.impostor_is_member(p_room_id) then
    raise exception 'Room not found';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',p.user_id,'name',p.player_name,'ready',p.is_ready,'emoji',p.emoji,
    'coins',coalesce(a.coins,0),'xp',coalesce(a.xp,0),'level',coalesce(a.level,1)
  ) order by p.joined_at),'[]'::jsonb)
  into player_json
  from public.impostor_players p
  left join public.impostor_profiles a on a.user_id=p.user_id
  where p.room_id=p_room_id;

  gs := r.game_state;
  if gs is null then
    return jsonb_build_object(
      'roomId',r.id,'roomCode',r.code,'isHost',r.host_id=uid,
      'state',jsonb_build_object(
        'phase','lobby','visibility',r.visibility,'maxPlayers',r.max_players,
        'totalRounds',r.total_rounds,'players',player_json,'hints','{}'::jsonb,
        'submitted','[]'::jsonb,'votesSubmitted','[]'::jsonb,'voteCount',0,
        'judgeId',null,'tied','[]'::jsonb,'result',null
      ),'privateInfo',null
    );
  end if;

  if gs->>'phase'='hints' then
    select coalesce(jsonb_agg(to_jsonb(p.user_id::text)),'[]'::jsonb)
    into submitted_json
    from public.impostor_players p
    where p.room_id=p_room_id
      and coalesce(gs->'hints'->(p.user_id::text)->((gs->>'round')::int-1),'null'::jsonb)<>'null'::jsonb;
  else
    select coalesce(jsonb_agg(to_jsonb(k)),'[]'::jsonb)
    into submitted_json
    from jsonb_object_keys(coalesce(gs->'hints','{}'::jsonb)) k
    where jsonb_typeof(gs->'hints'->k)='array';
  end if;

  if gs->>'phase'='hints' then
    if coalesce(gs->'hints'->(uid::text)->((gs->>'round')::int-1),'null'::jsonb)<>'null'::jsonb then
      select coalesce(jsonb_object_agg(k,coalesce((
        select jsonb_agg(jsonb_build_object('round',idx+1,'text',v))
        from jsonb_array_elements(gs->'hints'->k) with ordinality a(v,idx)
        where v<>'null'::jsonb
      ),'[]'::jsonb)),'{}'::jsonb)
      into hints_json from jsonb_object_keys(gs->'hints') k;
    else
      hints_json := jsonb_build_object(uid::text,coalesce((
        select jsonb_agg(jsonb_build_object('round',idx+1,'text',v))
        from jsonb_array_elements(gs->'hints'->(uid::text)) with ordinality a(v,idx)
        where v<>'null'::jsonb
      ),'[]'::jsonb));
    end if;
  else
    select coalesce(jsonb_object_agg(k,coalesce((
      select jsonb_agg(jsonb_build_object('round',idx+1,'text',v))
      from jsonb_array_elements(gs->'hints'->k) with ordinality a(v,idx)
      where v<>'null'::jsonb
    ),'[]'::jsonb)),'{}'::jsonb)
    into hints_json from jsonb_object_keys(coalesce(gs->'hints','{}'::jsonb)) k;
  end if;

  select coalesce(jsonb_agg(to_jsonb(k)),'[]'::jsonb)
  into votes_json from jsonb_object_keys(coalesce(gs->'votes','{}'::jsonb)) k;

  private_json := jsonb_build_object(
    'role',case when uid::text=gs->>'impostor' then 'impostor' else 'crew' end,
    'word',case when uid::text=gs->>'impostor' then null else gs->>'word' end,
    'category',gs->>'category',
    'hasSubmitted',coalesce(gs->'hints'->(uid::text)->((gs->>'round')::int-1),'null'::jsonb)<>'null'::jsonb,
    'hasVoted',coalesce(gs->'votes'->(uid::text),'null'::jsonb)<>'null'::jsonb
  );

  return jsonb_build_object(
    'roomId',r.id,'roomCode',r.code,'isHost',r.host_id=uid,
    'state',jsonb_build_object(
      'phase',gs->>'phase','round',coalesce((gs->>'round')::int,1),
      'totalRounds',r.total_rounds,'visibility',r.visibility,'maxPlayers',r.max_players,
      'deadline',gs->>'deadline','players',player_json,'hints',hints_json,
      'submitted',submitted_json,'votesSubmitted',votes_json,
      'voteCount',jsonb_object_length(coalesce(gs->'votes','{}'::jsonb)),
      'judgeId',gs->'judgeId','tied',coalesce(gs->'tied','[]'::jsonb),
      'result',gs->'result'
    ),
    'privateInfo',private_json
  );
end;
$$;

-- A rematch is a new match, so it can award rewards again.
create or replace function public.impostor_reset_room(p_room_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
begin
  if not exists(
    select 1 from public.impostor_rooms
    where id=p_room_id and host_id=auth.uid()
  ) then
    raise exception 'Only the host can restart';
  end if;

  update public.impostor_rooms
  set game_state=null,status='waiting',rewards_paid=false,updated_at=now()
  where id=p_room_id;

  update public.impostor_players
  set is_ready=(user_id=auth.uid())
  where room_id=p_room_id;

  return public.impostor_snapshot(p_room_id);
end;
$$;
