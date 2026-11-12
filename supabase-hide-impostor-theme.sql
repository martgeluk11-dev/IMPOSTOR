-- IMPOSTOR security fix: never send the category/theme to the impostor.
-- Run this once in Supabase SQL Editor after deploying the updated site.

create or replace function public.impostor_snapshot(p_room_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public
as $$
declare r public.impostor_rooms; uid uuid:=auth.uid(); member_count int; player_json jsonb; gs jsonb; hints_json jsonb:='{}'::jsonb; submitted_json jsonb:='[]'::jsonb; votes_json jsonb:='[]'::jsonb; private_json jsonb;
begin
 select * into r from public.impostor_rooms where id=p_room_id;
 if not found or not public.impostor_is_member(p_room_id) then raise exception 'Room not found'; end if;
 select count(*) into member_count from public.impostor_players where room_id=p_room_id;
 select coalesce(jsonb_agg(jsonb_build_object('id',user_id,'name',player_name,'ready',is_ready,'emoji',emoji,'avatar_id',avatar_id) order by joined_at),'[]'::jsonb)
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
   'category',case when uid::text=gs->>'impostor' then null else gs->>'category' end,
   'hasSubmitted',coalesce(gs->'hints'->(uid::text)->((gs->>'round')::int-1),'null'::jsonb)<>'null'::jsonb,
   'isTurn',uid::text=gs->>'currentPlayerId',
   'hasVoted',coalesce(gs->'votes'->(uid::text),'null'::jsonb)<>'null'::jsonb);
 return jsonb_build_object('roomId',r.id,'roomCode',r.code,'isHost',r.host_id=uid,
   'state',jsonb_build_object('phase',gs->>'phase','round',coalesce((gs->>'round')::int,1),'totalRounds',r.total_rounds,'visibility',r.visibility,'maxPlayers',r.max_players,
     'deadline',gs->>'deadline','turnPlayerId',gs->>'currentPlayerId','turnIndex',coalesce((gs->>'turnIndex')::int,0),'players',player_json,'hints',hints_json,'submitted',submitted_json,'votesSubmitted',votes_json,
     'voteCount',(select count(*) from jsonb_object_keys(coalesce(gs->'votes','{}'::jsonb))),'judgeId',gs->'judgeId','tied',coalesce(gs->'tied','[]'::jsonb),'result',gs->'result'),
   'privateInfo',private_json);
end $$;
