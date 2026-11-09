-- IMPOSTOR Supabase setup
-- Run this entire file in Supabase Dashboard > SQL Editor.
create extension if not exists pgcrypto;

create table if not exists public.impostor_rooms (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  host_id uuid not null,
  visibility text not null check (visibility in ('public','private')),
  max_players int not null check (max_players between 2 and 8),
  total_rounds int not null check (total_rounds between 3 and 10),
  status text not null default 'waiting' check (status in ('waiting','playing','finished')),
  game_state jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.impostor_players (
  room_id uuid not null references public.impostor_rooms(id) on delete cascade,
  user_id uuid not null,
  player_name text not null check (char_length(player_name) between 1 and 16),
  emoji text not null default '🦊',
  is_ready boolean not null default false,
  joined_at timestamptz not null default now(),
  primary key (room_id,user_id)
);

create index if not exists impostor_rooms_directory_idx on public.impostor_rooms(status,visibility,created_at desc);
create index if not exists impostor_players_room_idx on public.impostor_players(room_id,joined_at);

alter table public.impostor_rooms enable row level security;
alter table public.impostor_players enable row level security;

create or replace function public.impostor_is_member(p_room_id uuid)
returns boolean language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.impostor_players where room_id=p_room_id and user_id=auth.uid()) $$;

drop policy if exists "Room members can read their room" on public.impostor_rooms;
create policy "Room members can read their room" on public.impostor_rooms for select to authenticated using (public.impostor_is_member(id));
drop policy if exists "Room members can read players" on public.impostor_players;
create policy "Room members can read players" on public.impostor_players for select to authenticated using (public.impostor_is_member(room_id));

create or replace function public.impostor_snapshot(p_room_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public
as $$
declare r public.impostor_rooms; uid uuid:=auth.uid(); member_count int; player_json jsonb; gs jsonb; hints_json jsonb:='{}'::jsonb; submitted_json jsonb:='[]'::jsonb; votes_json jsonb:='[]'::jsonb; private_json jsonb;
begin
 select * into r from public.impostor_rooms where id=p_room_id;
 if not found or not public.impostor_is_member(p_room_id) then raise exception 'Room not found'; end if;
 select count(*) into member_count from public.impostor_players where room_id=p_room_id;
 select coalesce(jsonb_agg(jsonb_build_object('id',user_id,'name',player_name,'ready',is_ready,'emoji',emoji) order by joined_at),'[]'::jsonb)
 into player_json from public.impostor_players where room_id=p_room_id;
 gs:=r.game_state;
 if gs is null then
   return jsonb_build_object('roomId',r.id,'roomCode',r.code,'isHost',r.host_id=uid,'state',jsonb_build_object('phase','lobby','visibility',r.visibility,'maxPlayers',r.max_players,'totalRounds',r.total_rounds,'players',player_json,'hints','{}'::jsonb,'submitted','[]'::jsonb,'votesSubmitted','[]'::jsonb,'voteCount',0,'judgeId',null,'tied','[]'::jsonb,'result',null),'privateInfo',null);
 end if;
 if gs->>'phase'='hints' then
   select coalesce(jsonb_agg(to_jsonb(p.user_id::text)),'[]'::jsonb) into submitted_json
   from public.impostor_players p
   where p.room_id=p_room_id and coalesce(gs->'hints'->(p.user_id::text)->((gs->>'round')::int-1),'null'::jsonb)<>'null'::jsonb;
 else
   select coalesce(jsonb_agg(to_jsonb(k)),'[]'::jsonb) into submitted_json from jsonb_object_keys(coalesce(gs->'hints','{}'::jsonb)) k
   where jsonb_typeof(gs->'hints'->k)='array';
 end if;
 if gs->>'phase'='hints' then
   if coalesce(gs->'hints'->(uid::text)->((gs->>'round')::int-1),'null'::jsonb)<>'null'::jsonb then
     select coalesce(jsonb_object_agg(k,coalesce((select jsonb_agg(jsonb_build_object('round',idx+1,'text',v)) from jsonb_array_elements(gs->'hints'->k) with ordinality a(v,idx) where v<>'null'::jsonb),'[]'::jsonb)),'{}'::jsonb)
     into hints_json from jsonb_object_keys(gs->'hints') k;
   else
     hints_json:=jsonb_build_object(uid::text,coalesce((select jsonb_agg(jsonb_build_object('round',idx+1,'text',v)) from jsonb_array_elements(gs->'hints'->(uid::text)) with ordinality a(v,idx) where v<>'null'::jsonb),'[]'::jsonb));
   end if;
 else
   select coalesce(jsonb_object_agg(k,coalesce((select jsonb_agg(jsonb_build_object('round',idx+1,'text',v)) from jsonb_array_elements(gs->'hints'->k) with ordinality a(v,idx) where v<>'null'::jsonb),'[]'::jsonb)),'{}'::jsonb)
   into hints_json from jsonb_object_keys(coalesce(gs->'hints','{}'::jsonb)) k;
 end if;
 select coalesce(jsonb_agg(to_jsonb(k)),'[]'::jsonb) into votes_json from jsonb_object_keys(coalesce(gs->'votes','{}'::jsonb)) k;
 private_json:=jsonb_build_object('role',case when uid::text=gs->>'impostor' then 'impostor' else 'crew' end,
   'word',case when uid::text=gs->>'impostor' then null else gs->>'word' end,
   'category',gs->>'category',
   'hasSubmitted',coalesce(gs->'hints'->(uid::text)->((gs->>'round')::int-1),'null'::jsonb)<>'null'::jsonb,
   'hasVoted',coalesce(gs->'votes'->(uid::text),'null'::jsonb)<>'null'::jsonb);
 return jsonb_build_object('roomId',r.id,'roomCode',r.code,'isHost',r.host_id=uid,
   'state',jsonb_build_object('phase',gs->>'phase','round',coalesce((gs->>'round')::int,1),'totalRounds',r.total_rounds,'visibility',r.visibility,'maxPlayers',r.max_players,
     'deadline',gs->>'deadline','players',player_json,'hints',hints_json,'submitted',submitted_json,'votesSubmitted',votes_json,
     'voteCount',jsonb_object_length(coalesce(gs->'votes','{}'::jsonb)),'judgeId',gs->'judgeId','tied',coalesce(gs->'tied','[]'::jsonb),'result',gs->'result'),
   'privateInfo',private_json);
end $$;

create or replace function public.impostor_create_room(p_name text,p_max_players int default 6,p_rounds int default 5,p_visibility text default 'public')
returns jsonb language plpgsql security definer set search_path=public
as $$
declare uid uuid:=auth.uid(); rid uuid; code_value text; emoji_value text;
begin
 if uid is null then raise exception 'Sign in required'; end if;
 if p_max_players not between 2 and 8 or p_rounds not between 3 and 10 or p_visibility not in ('public','private') then raise exception 'Invalid room settings'; end if;
 loop code_value:=upper(substr(encode(gen_random_bytes(6),'hex'),1,6)); exit when not exists(select 1 from public.impostor_rooms where code=code_value); end loop;
 emoji_value:=(array['🦊','🐸','🐼','🐙','🦄','🐧','🐻','🦋'])[1+floor(random()*8)::int];
 insert into public.impostor_rooms(code,host_id,visibility,max_players,total_rounds) values(code_value,uid,p_visibility,p_max_players,p_rounds) returning id into rid;
 insert into public.impostor_players(room_id,user_id,player_name,emoji,is_ready) values(rid,uid,left(trim(coalesce(p_name,'Player')),16),emoji_value,true);
 return public.impostor_snapshot(rid);
end $$;

create or replace function public.impostor_join_room(p_code text,p_name text)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare r public.impostor_rooms; uid uuid:=auth.uid(); emoji_value text;
begin
 if uid is null then raise exception 'Sign in required'; end if;
 select * into r from public.impostor_rooms where code=upper(trim(p_code)) for update;
 if not found or r.status<>'waiting' then raise exception 'Room not found or game already started'; end if;
 if (select count(*) from public.impostor_players where room_id=r.id)>=r.max_players then raise exception 'Room is full'; end if;
 if exists(select 1 from public.impostor_players where room_id=r.id and user_id=uid) then return public.impostor_snapshot(r.id); end if;
 emoji_value:=(array['🦊','🐸','🐼','🐙','🦄','🐧','🐻','🦋'])[1+floor(random()*8)::int];
 insert into public.impostor_players(room_id,user_id,player_name,emoji) values(r.id,uid,left(trim(coalesce(p_name,'Player')),16),emoji_value);
 return public.impostor_snapshot(r.id);
end $$;

create or replace function public.impostor_list_public_rooms()
returns jsonb language sql stable security definer set search_path=public
as $$
 select coalesce(jsonb_agg(jsonb_build_object('code',r.code,'players',(select count(*) from public.impostor_players p where p.room_id=r.id),'maxPlayers',r.max_players,'rounds',r.total_rounds,'host',(select player_name from public.impostor_players p where p.room_id=r.id and p.user_id=r.host_id),'createdAt',r.created_at) order by r.created_at desc),'[]'::jsonb)
 from public.impostor_rooms r where r.visibility='public' and r.status='waiting'
 and (select count(*) from public.impostor_players p where p.room_id=r.id)<r.max_players;
$$;

create or replace function public.impostor_quick_match(p_name text)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare code_value text;
begin
 select r.code into code_value from public.impostor_rooms r
 where r.visibility='public' and r.status='waiting'
 and (select count(*) from public.impostor_players p where p.room_id=r.id)<r.max_players
 order by r.created_at asc limit 1 for update skip locked;
 if code_value is null then raise exception 'No public rooms available'; end if;
 return public.impostor_join_room(code_value,p_name);
end $$;

create or replace function public.impostor_set_ready(p_room_id uuid,p_ready boolean)
returns jsonb language plpgsql security definer set search_path=public
as $$
begin
 update public.impostor_players set is_ready=p_ready where room_id=p_room_id and user_id=auth.uid();
 if not found then raise exception 'You are not in this room'; end if;
 return public.impostor_snapshot(p_room_id);
end $$;

create or replace function public.impostor_get_room(p_code text)
returns jsonb language plpgsql stable security definer set search_path=public
as $$
declare rid uuid;
begin
 select id into rid from public.impostor_rooms where code=upper(trim(p_code));
 if rid is null then raise exception 'Room not found'; end if;
 return public.impostor_snapshot(rid);
end $$;

grant execute on function public.impostor_create_room(text,int,int,text) to authenticated;
grant execute on function public.impostor_join_room(text,text) to authenticated;
grant execute on function public.impostor_list_public_rooms() to authenticated;
grant execute on function public.impostor_quick_match(text) to authenticated;
grant execute on function public.impostor_set_ready(uuid,boolean) to authenticated;
grant execute on function public.impostor_get_room(text) to authenticated;
grant execute on function public.impostor_snapshot(uuid) to authenticated;

do $$ begin
 alter publication supabase_realtime add table public.impostor_rooms;
exception when duplicate_object then null; when others then
 if sqlerrm not like '%already member%' then raise; end if;
end $$;
do $$ begin
 alter publication supabase_realtime add table public.impostor_players;
exception when duplicate_object then null; when others then
 if sqlerrm not like '%already member%' then raise; end if;
end $$;
