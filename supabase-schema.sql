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


create or replace function public.impostor_start_game(p_room_id uuid)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare r public.impostor_rooms; uid uuid:=auth.uid(); ids uuid[]; words text[]:=array['Pizza','Volcano','Minecraft','Dolphin','Airplane','Popcorn','Guitar','Shark','Rainbow','Toothbrush','Basketball','Astronaut','Chocolate','Snowman','Headphones','Rollercoaster','Penguin','Smartphone','Watermelon','Skateboard','Castle','YouTube','Umbrella','Dragon','Pancake','Robot','Tornado','Football','Camera','Ghost','Sunglasses','Submarine','Sushi','Cactus','Dinosaur','Keyboard','Camping','Ice cream','Helicopter','Mermaid']; cats text[]:=array['Food','Nature','Games','Animals','Transport','Food','Music','Animals','Nature','Everyday','Sports','People','Food','Nature','Technology','Places','Animals','Technology','Food','Sports','Places','Internet','Everyday','Fantasy','Food','Technology','Nature','Sports','Technology','Fantasy','Everyday','Transport','Food','Nature','Animals','Technology','Places','Food','Transport','Fantasy']; n int; i int; hints_json jsonb:='{}'::jsonb;
begin
 select * into r from public.impostor_rooms where id=p_room_id for update;
 if not found or r.host_id<>uid then raise exception 'Only the host can start'; end if;
 select array_agg(user_id order by joined_at) into ids from public.impostor_players where room_id=p_room_id;
 if coalesce(array_length(ids,1),0)<2 then raise exception 'At least two players are required'; end if;
 if exists(select 1 from public.impostor_players where room_id=p_room_id and not is_ready) then raise exception 'Everyone must be ready'; end if;
 n:=1+floor(random()*array_length(words,1))::int;
 foreach i in array generate_series(1,array_length(ids,1)) loop
   hints_json:=jsonb_set(hints_json,array[ids[i]::text],(select jsonb_agg('null'::jsonb) from generate_series(1,r.total_rounds)),true);
 end loop;
 update public.impostor_rooms set status='playing',game_state=jsonb_build_object('phase','hints','round',1,'word',words[n],'category',cats[n],'impostor',ids[1+floor(random()*array_length(ids,1))::int]::text,'hints',hints_json,'votes','{}'::jsonb,'deadline',now()+interval '60 seconds','judgeId',null,'tied','[]'::jsonb,'result',null),updated_at=now() where id=p_room_id;
 update public.impostor_players set is_ready=false where room_id=p_room_id;
 return public.impostor_snapshot(p_room_id);
end $$;

create or replace function public.impostor_submit_hint(p_room_id uuid,p_hint text)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare r public.impostor_rooms; gs jsonb; uid uuid:=auth.uid(); clean text; round_no int; all_done boolean;
begin
 select * into r from public.impostor_rooms where id=p_room_id for update;
 if not found or not public.impostor_is_member(p_room_id) then raise exception 'Room not found'; end if;
 gs:=r.game_state; round_no:=(gs->>'round')::int; clean:=left(trim(coalesce(p_hint,'')),20);
 if gs->>'phase'<>'hints' or clean='' then raise exception 'Hints are not being accepted'; end if;
 if coalesce(gs->'hints'->(uid::text)->(round_no-1),'null'::jsonb)<>'null'::jsonb then raise exception 'You already submitted a hint'; end if;
 gs:=jsonb_set(gs,array['hints',uid::text,(round_no-1)::text],to_jsonb(clean),true);
 select not exists(select 1 from public.impostor_players p where p.room_id=p_room_id and coalesce(gs->'hints'->(p.user_id::text)->(round_no-1),'null'::jsonb)='null'::jsonb) into all_done;
 if all_done then
   if round_no<(gs->>'round')::int + (r.total_rounds-round_no) then null; end if;
   if round_no<r.total_rounds then gs:=jsonb_set(gs,'{round}',to_jsonb(round_no+1),true); gs:=jsonb_set(gs,'{deadline}',to_jsonb(now()+interval '60 seconds'),true);
   else gs:=jsonb_set(gs,'{phase}','"vote"'::jsonb,true); gs:=jsonb_set(gs,'{deadline}','null'::jsonb,true); end if;
 end if;
 update public.impostor_rooms set game_state=gs,updated_at=now() where id=p_room_id;
 return public.impostor_snapshot(p_room_id);
end $$;

create or replace function public.impostor_advance_timeout(p_room_id uuid)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare r public.impostor_rooms; gs jsonb; round_no int;
begin
 select * into r from public.impostor_rooms where id=p_room_id for update;
 if not found or r.host_id<>auth.uid() then raise exception 'Only the host can advance the timer'; end if;
 gs:=r.game_state; round_no:=(gs->>'round')::int;
 if gs->>'phase'<>'hints' or (gs->>'deadline')::timestamptz>now() then return public.impostor_snapshot(p_room_id); end if;
 if round_no<r.total_rounds then gs:=jsonb_set(gs,'{round}',to_jsonb(round_no+1),true); gs:=jsonb_set(gs,'{deadline}',to_jsonb(now()+interval '60 seconds'),true);
 else gs:=jsonb_set(gs,'{phase}','"vote"'::jsonb,true); gs:=jsonb_set(gs,'{deadline}','null'::jsonb,true); end if;
 update public.impostor_rooms set game_state=gs,updated_at=now() where id=p_room_id;
 return public.impostor_snapshot(p_room_id);
end $$;

create or replace function public.impostor_submit_vote(p_room_id uuid,p_target uuid)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare r public.impostor_rooms; gs jsonb; uid uuid:=auth.uid(); votes jsonb; total_players int; max_votes int; tied_ids jsonb; winner_id uuid; judge_id uuid;
begin
 select * into r from public.impostor_rooms where id=p_room_id for update;
 if not found or not public.impostor_is_member(p_room_id) then raise exception 'Room not found'; end if;
 gs:=r.game_state;
 if gs->>'phase'<>'vote' or p_target=uid or not exists(select 1 from public.impostor_players where room_id=p_room_id and user_id=p_target) then raise exception 'Invalid vote'; end if;
 votes:=coalesce(gs->'votes','{}'::jsonb);
 if votes ? uid::text then raise exception 'You already voted'; end if;
 votes:=jsonb_set(votes,array[uid::text],to_jsonb(p_target::text),true); gs:=jsonb_set(gs,'{votes}',votes,true);
 select count(*) into total_players from public.impostor_players where room_id=p_room_id;
 if jsonb_object_length(votes)=total_players then
   select max(cnt) into max_votes from (select count(*) cnt from jsonb_each_text(votes) group by value) q;
   select jsonb_agg(value::uuid) into tied_ids from (select value from jsonb_each_text(votes) group by value having count(*)=max_votes) q;
   if jsonb_array_length(tied_ids)>1 then
     select user_id into judge_id from public.impostor_players where room_id=p_room_id and user_id::text<>gs->>'impostor' order by joined_at limit 1;
     gs:=jsonb_set(gs,'{phase}','"judge"'::jsonb,true); gs:=jsonb_set(gs,'{tied}',tied_ids,true); gs:=jsonb_set(gs,'{judgeId}',to_jsonb(judge_id::text),true);
   else
     winner_id:=(tied_ids->>0)::uuid;
     if winner_id::text=gs->>'impostor' then gs:=jsonb_set(gs,'{phase}','"guess"'::jsonb,true);
     else gs:=jsonb_set(gs,'{phase}','"results"'::jsonb,true); gs:=jsonb_set(gs,'{result}',jsonb_build_object('winner','impostor','detail','An innocent player was voted out.','word',gs->>'word','impostor',gs->>'impostor'),true); update public.impostor_rooms set status='finished' where id=p_room_id; end if;
   end if;
 end if;
 update public.impostor_rooms set game_state=gs,updated_at=now() where id=p_room_id;
 return public.impostor_snapshot(p_room_id);
end $$;

create or replace function public.impostor_judge_vote(p_room_id uuid,p_target uuid)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare r public.impostor_rooms; gs jsonb;
begin
 select * into r from public.impostor_rooms where id=p_room_id for update;
 if not found then raise exception 'Room not found'; end if;
 gs:=r.game_state;
 if gs->>'phase'<>'judge' or gs->>'judgeId'<>auth.uid()::text or not (gs->'tied' ? p_target::text) then raise exception 'You cannot make this decision'; end if;
 if p_target::text=gs->>'impostor' then gs:=jsonb_set(gs,'{phase}','"guess"'::jsonb,true);
 else gs:=jsonb_set(gs,'{phase}','"results"'::jsonb,true); gs:=jsonb_set(gs,'{result}',jsonb_build_object('winner','impostor','detail','The Judge selected an innocent player.','word',gs->>'word','impostor',gs->>'impostor'),true); update public.impostor_rooms set status='finished' where id=p_room_id; end if;
 update public.impostor_rooms set game_state=gs,updated_at=now() where id=p_room_id;
 return public.impostor_snapshot(p_room_id);
end $$;

create or replace function public.impostor_submit_guess(p_room_id uuid,p_guess text)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare r public.impostor_rooms; gs jsonb; win text; detail_text text;
begin
 select * into r from public.impostor_rooms where id=p_room_id for update;
 if not found then raise exception 'Room not found'; end if;
 gs:=r.game_state;
 if gs->>'phase'<>'guess' or gs->>'impostor'<>auth.uid()::text then raise exception 'You cannot make this guess'; end if;
 if lower(trim(coalesce(p_guess,'')))=lower(gs->>'word') then win:='impostor'; detail_text:='The impostor guessed the secret word.';
 else win:='crew'; detail_text:='The impostor guessed incorrectly.'; end if;
 gs:=jsonb_set(gs,'{phase}','"results"'::jsonb,true);
 gs:=jsonb_set(gs,'{result}',jsonb_build_object('winner',win,'detail',detail_text,'word',gs->>'word','impostor',gs->>'impostor'),true);
 update public.impostor_rooms set game_state=gs,status='finished',updated_at=now() where id=p_room_id;
 return public.impostor_snapshot(p_room_id);
end $$;

create or replace function public.impostor_leave_room(p_room_id uuid)
returns void language plpgsql security definer set search_path=public
as $$
declare r public.impostor_rooms; gs jsonb; uid uuid:=auth.uid(); next_host uuid;
begin
 select * into r from public.impostor_rooms where id=p_room_id for update;
 if not found then return; end if;
 gs:=r.game_state;
 if gs is not null and gs->>'phase'<>'results' and gs->>'impostor'=uid::text then
   gs:=jsonb_set(gs,'{phase}','"results"'::jsonb,true);
   gs:=jsonb_set(gs,'{result}',jsonb_build_object('winner','crew','detail','The impostor left the game.','word',gs->>'word','impostor',gs->>'impostor'),true);
   update public.impostor_rooms set game_state=gs,status='finished' where id=p_room_id;
 end if;
 delete from public.impostor_players where room_id=p_room_id and user_id=uid;
 if r.host_id=uid then
   select user_id into next_host from public.impostor_players where room_id=p_room_id order by joined_at limit 1;
   if next_host is null then delete from public.impostor_rooms where id=p_room_id;
   else update public.impostor_rooms set host_id=next_host where id=p_room_id; end if;
 elsif (select count(*) from public.impostor_players where room_id=p_room_id)<2 and gs is not null and gs->>'phase'<>'results' then
   gs:=jsonb_set(gs,'{phase}','"results"'::jsonb,true);
   gs:=jsonb_set(gs,'{result}',jsonb_build_object('winner','crew','detail','Not enough players remained.','word',gs->>'word','impostor',gs->>'impostor'),true);
   update public.impostor_rooms set game_state=gs,status='finished' where id=p_room_id;
 end if;
end $$;

create or replace function public.impostor_reset_room(p_room_id uuid)
returns jsonb language plpgsql security definer set search_path=public
as $$
begin
 if not exists(select 1 from public.impostor_rooms where id=p_room_id and host_id=auth.uid()) then raise exception 'Only the host can restart'; end if;
 update public.impostor_rooms set game_state=null,status='waiting',updated_at=now() where id=p_room_id;
 update public.impostor_players set is_ready=(user_id=auth.uid()) where room_id=p_room_id;
 return public.impostor_snapshot(p_room_id);
end $$;

grant execute on function public.impostor_start_game(uuid) to authenticated;
grant execute on function public.impostor_submit_hint(uuid,text) to authenticated;
grant execute on function public.impostor_advance_timeout(uuid) to authenticated;
grant execute on function public.impostor_submit_vote(uuid,uuid) to authenticated;
grant execute on function public.impostor_judge_vote(uuid,uuid) to authenticated;
grant execute on function public.impostor_submit_guess(uuid,text) to authenticated;
grant execute on function public.impostor_leave_room(uuid) to authenticated;
grant execute on function public.impostor_reset_room(uuid) to authenticated;
