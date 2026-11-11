-- IMPOSTOR: sequential hint turns (60 seconds per player)
-- Run this entire file once in Supabase SQL Editor after updating the site.

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
   'isTurn',uid::text=gs->>'currentPlayerId',
   'hasVoted',coalesce(gs->'votes'->(uid::text),'null'::jsonb)<>'null'::jsonb);
 return jsonb_build_object('roomId',r.id,'roomCode',r.code,'isHost',r.host_id=uid,
   'state',jsonb_build_object('phase',gs->>'phase','round',coalesce((gs->>'round')::int,1),'totalRounds',r.total_rounds,'visibility',r.visibility,'maxPlayers',r.max_players,
     'deadline',gs->>'deadline','turnPlayerId',gs->>'currentPlayerId','turnIndex',coalesce((gs->>'turnIndex')::int,0),'players',player_json,'hints',hints_json,'submitted',submitted_json,'votesSubmitted',votes_json,
     'voteCount',(select count(*) from jsonb_object_keys(coalesce(gs->'votes','{}'::jsonb))),'judgeId',gs->'judgeId','tied',coalesce(gs->'tied','[]'::jsonb),'result',gs->'result'),
   'privateInfo',private_json);
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
 n:=1+floor(random()*array_length(words,1))::int;
 for i in 1..array_length(ids,1) loop
   hints_json:=jsonb_set(hints_json,array[ids[i]::text],(select jsonb_agg('null'::jsonb) from generate_series(1,r.total_rounds)),true);
 end loop;
 update public.impostor_rooms set status='playing',game_state=jsonb_build_object('phase','hints','round',1,'word',words[n],'category',cats[n],'impostor',ids[1+floor(random()*array_length(ids,1))::int]::text,'hints',hints_json,'votes','{}'::jsonb,'turnOrder',to_jsonb(ids),'turnIndex',0,'currentPlayerId',ids[1]::text,'deadline',now()+interval '60 seconds','judgeId',null,'tied','[]'::jsonb,'result',null),updated_at=now() where id=p_room_id;
 update public.impostor_players set is_ready=false where room_id=p_room_id;
 return public.impostor_snapshot(p_room_id);
end $$;

create or replace function public.impostor_submit_hint(p_room_id uuid,p_hint text)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare r public.impostor_rooms; gs jsonb; uid uuid:=auth.uid(); clean text; round_no int; turn_order jsonb; turn_idx int; next_idx int;
begin
 select * into r from public.impostor_rooms where id=p_room_id for update;
 if not found or not public.impostor_is_member(p_room_id) then raise exception 'Room not found'; end if;
 gs:=r.game_state; round_no:=(gs->>'round')::int; clean:=left(trim(coalesce(p_hint,'')),20);
 if gs->>'phase'<>'hints' or clean='' then raise exception 'Hints are not being accepted'; end if;
 if uid::text<>gs->>'currentPlayerId' then raise exception 'Wait for your turn to give a hint'; end if;
 if (gs->>'deadline')::timestamptz<=now() then raise exception 'Your turn has expired'; end if;
 if coalesce(gs->'hints'->(uid::text)->(round_no-1),'null'::jsonb)<>'null'::jsonb then raise exception 'You already submitted a hint'; end if;
 gs:=jsonb_set(gs,array['hints',uid::text,(round_no-1)::text],to_jsonb(clean),true);
 turn_order:=gs->'turnOrder'; turn_idx:=coalesce((gs->>'turnIndex')::int,0); next_idx:=turn_idx+1;
 if next_idx<jsonb_array_length(turn_order) then
   gs:=jsonb_set(gs,'{turnIndex}',to_jsonb(next_idx),true);
   gs:=jsonb_set(gs,'{currentPlayerId}',turn_order->next_idx,true);
   gs:=jsonb_set(gs,'{deadline}',to_jsonb(now()+interval '60 seconds'),true);
 elsif round_no<r.total_rounds then
   gs:=jsonb_set(gs,'{round}',to_jsonb(round_no+1),true);
   gs:=jsonb_set(gs,'{turnIndex}','0'::jsonb,true);
   gs:=jsonb_set(gs,'{currentPlayerId}',turn_order->0,true);
   gs:=jsonb_set(gs,'{deadline}',to_jsonb(now()+interval '60 seconds'),true);
 else
   gs:=jsonb_set(gs,'{phase}','"vote"'::jsonb,true);
   gs:=jsonb_set(gs,'{deadline}','null'::jsonb,true);
   gs:=jsonb_set(gs,'{currentPlayerId}','null'::jsonb,true);
 end if;
 update public.impostor_rooms set game_state=gs,updated_at=now() where id=p_room_id;
 return public.impostor_snapshot(p_room_id);
end $$;

create or replace function public.impostor_advance_timeout(p_room_id uuid)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare r public.impostor_rooms; gs jsonb; round_no int; turn_order jsonb; turn_idx int; next_idx int; current_id text;
begin
 select * into r from public.impostor_rooms where id=p_room_id for update;
 if not found or r.host_id<>auth.uid() then raise exception 'Only the host can advance the timer'; end if;
 gs:=r.game_state; round_no:=(gs->>'round')::int;
 if gs->>'phase'<>'hints' or (gs->>'deadline')::timestamptz>now() then return public.impostor_snapshot(p_room_id); end if;
 turn_order:=gs->'turnOrder'; turn_idx:=coalesce((gs->>'turnIndex')::int,0); current_id:=gs->>'currentPlayerId';
 if current_id is not null and coalesce(gs->'hints'->current_id->(round_no-1),'null'::jsonb)='null'::jsonb then
   gs:=jsonb_set(gs,array['hints',current_id,(round_no-1)::text],to_jsonb('(skipped)'::text),true);
 end if;
 next_idx:=turn_idx+1;
 if next_idx<jsonb_array_length(turn_order) then
   gs:=jsonb_set(gs,'{turnIndex}',to_jsonb(next_idx),true);
   gs:=jsonb_set(gs,'{currentPlayerId}',turn_order->next_idx,true);
   gs:=jsonb_set(gs,'{deadline}',to_jsonb(now()+interval '60 seconds'),true);
 elsif round_no<r.total_rounds then
   gs:=jsonb_set(gs,'{round}',to_jsonb(round_no+1),true);
   gs:=jsonb_set(gs,'{turnIndex}','0'::jsonb,true);
   gs:=jsonb_set(gs,'{currentPlayerId}',turn_order->0,true);
   gs:=jsonb_set(gs,'{deadline}',to_jsonb(now()+interval '60 seconds'),true);
 else
   gs:=jsonb_set(gs,'{phase}','"vote"'::jsonb,true);
   gs:=jsonb_set(gs,'{deadline}','null'::jsonb,true);
   gs:=jsonb_set(gs,'{currentPlayerId}','null'::jsonb,true);
 end if;
 update public.impostor_rooms set game_state=gs,updated_at=now() where id=p_room_id;
 return public.impostor_snapshot(p_room_id);
end $$;

grant execute on function public.impostor_snapshot(uuid) to authenticated;
grant execute on function public.impostor_start_game(uuid) to authenticated;
grant execute on function public.impostor_submit_hint(uuid,text) to authenticated;
grant execute on function public.impostor_advance_timeout(uuid) to authenticated;
