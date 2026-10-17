-- Run once in Supabase > SQL Editor
create table staff(user_id uuid primary key references auth.users on delete cascade);
create table champs(id uuid primary key references auth.users on delete cascade,name text not null,phone text not null,email text not null,aadhaar_last4 text,areas text[] default '{}',skills text[] default '{}',status text default 'pending',online boolean default true,terms_at timestamptz,last_assigned timestamptz default 'epoch',created_at timestamptz default now());
create table leads(id bigint generated always as identity primary key,name text,phone text,email text,source text,service text,area text,status text default 'New',champ_id uuid references champs,amount numeric default 0,rating int,tried uuid[] default '{}',offer_expires timestamptz,reject_reason text,raw jsonb,created_at timestamptz default now());
create table events(id bigint generated always as identity primary key,lead_id bigint references leads on delete cascade,champ_id uuid,kind text,note text,created_at timestamptz default now());
create function is_staff() returns boolean language sql security definer stable as $$ select exists(select 1 from staff where user_id=auth.uid()) $$;
alter table staff enable row level security;alter table champs enable row level security;alter table leads enable row level security;alter table events enable row level security;
create policy c_sel on champs for select using(id=auth.uid() or is_staff());
create policy c_ins on champs for insert with check(id=auth.uid() and status='pending');
create policy c_upd on champs for update using(is_staff());
create policy l_sel on leads for select using(is_staff() or champ_id=auth.uid());
create policy l_all on leads for all using(is_staff()) with check(is_staff());
create policy e_sel on events for select using(is_staff() or champ_id=auth.uid());
create policy s_sel on staff for select using(user_id=auth.uid());
-- Round robin: the eligible champ (approved, online, skill + area match, not yet tried) who was offered a lead longest ago
create function assign_next(p_lead bigint) returns uuid language plpgsql security definer as $$
declare l leads; c uuid;
begin
 select * into l from leads where id=p_lead for update;
 select id into c from champs where status='approved' and online and l.service=any(skills) and l.area=any(areas) and not(id=any(l.tried)) order by last_assigned limit 1;
 if c is null then
  update leads set status='New',champ_id=null,offer_expires=null where id=p_lead;
  insert into events(lead_id,kind,note) values(p_lead,'unassigned','No eligible champ: needs executive'); return null;
 end if;
 update leads set status='Assigned',champ_id=c,tried=tried||c,offer_expires=now()+interval '2 minutes' where id=p_lead;
 update champs set last_assigned=now() where id=c;
 insert into events(lead_id,champ_id,kind) values(p_lead,c,'offered'); return c;
end $$;
create function staff_assign(p_lead bigint,p_champ uuid default null) returns void language plpgsql security definer as $$
begin
 if not is_staff() then raise exception 'staff only'; end if;
 if p_champ is null then update leads set tried='{}' where id=p_lead; perform assign_next(p_lead);
 else update leads set status='Assigned',champ_id=p_champ,tried=tried||p_champ,offer_expires=now()+interval '2 minutes' where id=p_lead;
  insert into events(lead_id,champ_id,kind,note) values(p_lead,p_champ,'offered','Manual by executive'); end if;
end $$;
create function respond_offer(p_lead bigint,p_accept boolean,p_reason text default null) returns void language plpgsql security definer as $$
begin
 if not exists(select 1 from leads where id=p_lead and champ_id=auth.uid() and status='Assigned') then raise exception 'not your offer'; end if;
 if p_accept then
  update leads set status='Accepted',offer_expires=null where id=p_lead;
  insert into events(lead_id,champ_id,kind) values(p_lead,auth.uid(),'accepted');
 else
  if coalesce(trim(p_reason),'')='' then raise exception 'reason required'; end if;
  insert into events(lead_id,champ_id,kind,note) values(p_lead,auth.uid(),'rejected',p_reason);
  update leads set reject_reason=p_reason where id=p_lead;
  perform assign_next(p_lead);
 end if;
end $$;
create function advance_job(p_lead bigint,p_amount numeric default null) returns void language plpgsql security definer as $$
declare s text;
begin
 select status into s from leads where id=p_lead and champ_id=auth.uid();
 if s='Accepted' then update leads set status='Started' where id=p_lead; insert into events(lead_id,champ_id,kind) values(p_lead,auth.uid(),'started');
 elsif s='Started' then update leads set status='Completed',amount=coalesce(p_amount,0) where id=p_lead; insert into events(lead_id,champ_id,kind,note) values(p_lead,auth.uid(),'completed',p_amount::text);
 else raise exception 'invalid state'; end if;
end $$;
create function set_online(p boolean) returns void language sql security definer as $$ update champs set online=p where id=auth.uid() $$;
create function expire_offers() returns void language plpgsql security definer as $$
declare r record;
begin for r in select id,champ_id from leads where status='Assigned' and offer_expires<now() loop
 insert into events(lead_id,champ_id,kind) values(r.id,r.champ_id,'missed'); perform assign_next(r.id); end loop; end $$;
revoke execute on function assign_next(bigint),expire_offers() from public,anon,authenticated; grant execute on function assign_next(bigint),expire_offers() to service_role;
-- Private bucket for Aadhaar copies
insert into storage.buckets(id,name,public) values('kyc','kyc',false) on conflict do nothing;
create policy kyc_ins on storage.objects for insert to authenticated with check(bucket_id='kyc' and (storage.foldername(name))[1]=auth.uid()::text);
create policy kyc_sel on storage.objects for select to authenticated using(bucket_id='kyc' and ((storage.foldername(name))[1]=auth.uid()::text or is_staff()));
alter publication supabase_realtime add table leads;
-- Auto-pass unanswered offers every minute (enable Database > Extensions > pg_cron first)
select cron.schedule('expire-offers','* * * * *','select expire_offers()');
