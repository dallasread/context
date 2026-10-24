// Event store for the pr-feedback-fixer report: events in, runners fold them into
// thread state, queries read it. Runs in Node (tests) and inlined in the page.
const PFF=(()=>{
const VERSION="v1", RENAMED={noted:"deferred"};
const event=(objectId,action,data,time=Date.now())=>({key:`${time}/threads/${objectId}/${action}/${VERSION}`,time,collection:"threads",objectId,action,data,version:VERSION});
// A log line is an event, or an entry from before the log held events.
const fromLine=o=>o.action?o:event(o.thread,"classified",o,Date.parse(o.at));
function parseJsonl(text){const out=[];for(const l of String(text).split("\n")){if(!l.trim())continue;try{const o=JSON.parse(l);if(o&&(o.action||o.thread))out.push(fromLine(o))}catch(e){}}return out}
const stable=v=>Array.isArray(v)?"["+v.map(stable).join(",")+"]":v&&typeof v==="object"?"{"+Object.keys(v).sort().map(k=>JSON.stringify(k)+":"+stable(v[k])).join(",")+"}":JSON.stringify(v??null);
const thread=(s,id)=>s.threads.get(id)||s.threads.set(id,{thread:id,snapshots:[]}).get(id);
const RUNNERS={
 "threads.classified"(s,e){const t=thread(s,e.objectId);Object.assign(t,e.data,{thread:e.objectId,time:e.time,classified:true});
  t.outcome=RENAMED[t.outcome]||t.outcome;t.at=e.data.at||new Date(e.time).toISOString()},
 "threads.observed"(s,e){const t=thread(s,e.objectId);t.ctx=e.data;t.snapshots.push({time:e.time,ctx:e.data})}};
class EventStore{
 constructor(runners=RUNNERS){this.runners=runners;this.events=new Map()}
 // Adds an event unless one with its key is already here; true when added.
 track(e){if(!e||!e.key||this.events.has(e.key))return false;this.events.set(e.key,e);return true}
 restore(list){let n=0;for(const e of list)if(this.track(e))n++;return n}
 all(){return [...this.events.values()].sort((a,b)=>a.time-b.time||(a.key<b.key?-1:a.key>b.key?1:0))}
 state(){const s={threads:new Map(),events:this.all()};for(const e of s.events){const r=this.runners[e.collection+"."+e.action];if(r)r(s,e)}return s}}
const handled=(r,me)=>{const c=r.ctx;return !!(c&&(c.resolved||c.comments.length&&c.comments[c.comments.length-1].author===me))};
const threads=s=>[...s.threads.values()].filter(t=>t.classified).sort((a,b)=>b.time-a.time);
const needsYou=(s,me)=>threads(s).filter(t=>!handled(t,me));
function byPullRequest(ts){const g=new Map();for(const t of ts){const k=t.repo+"#"+t.pr;g.has(k)||g.set(k,[]);g.get(k).push(t)}return g}
const mine=(m,k)=>!!(m&&(m.reactions||[]).some(x=>x.content===k&&x.mine));
// What I changed between consecutive snapshots of each thread, newest first.
// An entry is undoable when it is the newest change to its target and still holds.
function diff(t,prev,next,time,me){const out=[],at=new Date(time).toISOString(),add=(kind,target,extra)=>out.push({kind,thread:t.thread,time,at,target,...extra});
 const p=new Map(prev.comments.map(m=>[m.id,m])),n=new Map(next.comments.map(m=>[m.id,m])),said=m=>({comment:m.id,url:m.url,body:String(m.body||"").slice(0,200)});
 for(const m of next.comments)if(!p.has(m.id)&&m.author===me)add("reply","c:"+m.id,said(m));
 for(const m of prev.comments)if(!n.has(m.id)&&m.author===me)add("unreply","c:"+m.id,said(m));
 if(!!prev.resolved!==!!next.resolved)add(next.resolved?"resolve":"unresolve","r:"+t.thread);
 for(const m of next.comments){const o=p.get(m.id);if(!o)continue;
  for(const k of new Set([...(o.reactions||[]),...(m.reactions||[])].map(x=>x.content))){const was=mine(o,k),is=mine(m,k);
   if(was!==is)add(is?"react":"unreact","x:"+m.id+"/"+k,{comment:m.id,content:k})}}
 return out}
function holds(h,c){if(!c)return false;const m=c.comments.find(x=>x.id===h.comment);
 return h.kind==="reply"?!!m:h.kind==="resolve"?!!c.resolved:h.kind==="react"?mine(m,h.content):h.kind==="unreact"?!!m&&!mine(m,h.content):false}
function history(s,me){const all=[];
 for(const t of threads(s))for(let i=1;i<t.snapshots.length;i++)all.push(...diff(t,t.snapshots[i-1].ctx,t.snapshots[i].ctx,t.snapshots[i].time,me));
 const latest=new Set();
 return all.map((h,i)=>[h,i]).sort((a,b)=>b[0].time-a[0].time||b[1]-a[1]).map(([h])=>{const t=s.threads.get(h.thread),first=!latest.has(h.target);latest.add(h.target);
  const{target,...rest}=h;return{...rest,undoable:first&&holds(h,t.ctx)}}).slice(0,200)}
return {VERSION,RENAMED,event,fromLine,parseJsonl,stable,RUNNERS,EventStore,handled,threads,needsYou,byPullRequest,history};
})();
if(typeof module!=="undefined")module.exports=PFF;
