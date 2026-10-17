import {createClient} from "https://esm.sh/@supabase/supabase-js@2.45.4";
const db=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const env=(k:string)=>Deno.env.get(k)||"";
const H={"content-type":"application/json","access-control-allow-origin":"*","access-control-allow-headers":"*"};
const out=(b:unknown,s=200)=>new Response(JSON.stringify(b),{status:s,headers:H});
const SV=[["bridal","Bridal Makeup"],["party","Party Makeup"],["hair","Hair Styling"],["nail","Nail Extensions"],["pre","Pre-Bridal"],["parlour","Beauty Parlour at Home"]];
const svc=(t="")=>SV.find(([k])=>String(t).toLowerCase().includes(k))?.[1]||"";
async function save(l:any){
 const phone=String(l.phone||"").replace(/\D/g,"").slice(-10);
 if(phone.length!==10)return{skipped:"bad phone"};
 const since=new Date(Date.now()-864e5).toISOString();
 const{data:d}=await db.from("leads").select("id").eq("phone",phone).gte("created_at",since).limit(1);
 if(d?.length)return{duplicate:d[0].id};
 const{data,error}=await db.from("leads").insert({name:l.name||"Unknown",phone,email:l.email||null,source:l.source,service:svc(l.service)||l.service||null,area:l.area||null,raw:l.raw||null}).select("id,service,area").single();
 if(error)throw error;
 if(env("AUTO_ASSIGN")==="1"&&data.service&&data.area)await db.rpc("assign_next",{p_lead:data.id});
 return{id:data.id};
}
async function sigOk(req:Request,body:string){
 const sig=req.headers.get("x-hub-signature-256")||"";
 const k=await crypto.subtle.importKey("raw",new TextEncoder().encode(env("META_APP_SECRET")),{name:"HMAC",hash:"SHA-256"},false,["sign"]);
 const m=await crypto.subtle.sign("HMAC",k,new TextEncoder().encode(body));
 return sig==="sha256="+[...new Uint8Array(m)].map(b=>b.toString(16).padStart(2,"0")).join("");
}
Deno.serve(async req=>{
 if(req.method==="OPTIONS")return out({});
 const u=new URL(req.url),src=u.searchParams.get("source");
 try{
  if(req.method==="GET"&&u.searchParams.get("hub.mode")==="subscribe"){
   const t=src==="meta"?env("META_VERIFY_TOKEN"):env("WA_VERIFY_TOKEN");
   return u.searchParams.get("hub.verify_token")===t?new Response(u.searchParams.get("hub.challenge")):out({error:"bad token"},403);
  }
  const body=await req.text();let j:any={};try{j=JSON.parse(body)}catch{}
  const res:any[]=[];
  if(src==="website"){
   if(j.website_url)return out({ok:true}); // honeypot field
   res.push(await save({...j,source:"Website"}));
  }else if(src==="google"){
   if(j.google_key!==env("GOOGLE_KEY"))return out({error:"unauthorized"},401);
   const f:any={};(j.user_column_data||[]).forEach((c:any)=>f[c.column_id]=c.string_value);
   res.push(await save({name:f.FULL_NAME,phone:f.PHONE_NUMBER,email:f.EMAIL,source:"Google Ads",raw:j}));
  }else if(src==="meta"){
   if(!(await sigOk(req,body)))return out({error:"bad signature"},401);
   for(const e of j.entry||[])for(const c of e.changes||[]){
    const id=c.value?.leadgen_id;if(!id)continue;
    const r=await(await fetch(`https://graph.facebook.com/v21.0/${id}?access_token=${env("META_PAGE_TOKEN")}`)).json();
    const f:any={};(r.field_data||[]).forEach((x:any)=>f[x.name]=x.values?.[0]);
    res.push(await save({name:f.full_name,phone:f.phone_number,email:f.email,service:f.service||"",area:f.city||f.area||"",source:"Meta Ads",raw:r}));
   }
  }else if(src==="whatsapp"){
   if(!(await sigOk(req,body)))return out({error:"bad signature"},401);
   for(const e of j.entry||[])for(const c of e.changes||[]){const v=c.value||{};
    for(const m of v.messages||[])res.push(await save({name:v.contacts?.[0]?.profile?.name,phone:m.from,service:svc(m.text?.body),source:"WhatsApp",raw:m}));
   }
  }else return out({error:"unknown source"},400);
  return out({ok:true,res});
 }catch(e){console.error(e);return out({error:"server error"},500)}
});
