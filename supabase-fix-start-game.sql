-- Run this in Supabase SQL Editor to replace the deployed start-game function.
-- Starting requires only the host and at least two joined players.

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
 update public.impostor_rooms set status='playing',game_state=jsonb_build_object('phase','hints','round',1,'word',words[n],'category',cats[n],'impostor',ids[1+floor(random()*array_length(ids,1))::int]::text,'hints',hints_json,'votes','{}'::jsonb,'deadline',now()+interval '60 seconds','judgeId',null,'tied','[]'::jsonb,'result',null),updated_at=now() where id=p_room_id;
 update public.impostor_players set is_ready=false where room_id=p_room_id;
 return public.impostor_snapshot(p_room_id);
end $$;

grant execute on function public.impostor_start_game(uuid) to authenticated;
