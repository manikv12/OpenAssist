#!/usr/bin/env node
// Explicit local memory sync through the user's signed-in Codex Workspace app.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { MemorySourceWorkspaceCoordinator } from '../dist-electron/memorySourceWorkspaceCoordinator.js';
import { CodexPluginMCPBroker } from '../dist-electron/codexPluginMcpBroker.js';
const sync = process.argv.includes('--sync');
const wiki = process.argv.includes('--wiki');
const root = path.join(os.homedir(), 'Library/Application Support/Open Assist/SecondBrain/MemorySources');
const machine = JSON.parse(fs.readFileSync(path.join(os.homedir(), 'Library/Application Support/OpenAssist/RemoteAccess/machine-id.json'), 'utf8')).machineID;
const executable = [process.env.OPENASSIST_CODEX_EXECUTABLE, '/Applications/Codex.app/Contents/Resources/codex', '/Applications/ChatGPT.app/Contents/Resources/codex', path.join(os.homedir(), '.local/bin/codex')].find(value => value && fs.existsSync(value));
if (!executable) throw new Error('Install Codex before syncing memory.');
let ownsLock=false;
const lockPath=path.join(root,'sync.lock');
if(sync) {
 fs.mkdirSync(root,{recursive:true,mode:0o700});
 if(fs.existsSync(lockPath)) {
   const owner=JSON.parse(fs.readFileSync(lockPath,'utf8'));
   let alive=true;try{process.kill(owner.pid,0);}catch{alive=false;}
   if(alive){console.log(JSON.stringify({event:'already_syncing'}));process.exit(0);}
   fs.unlinkSync(lockPath);
 }
 const lock=fs.openSync(lockPath,'wx',0o600);fs.writeFileSync(lock,JSON.stringify({pid:process.pid}));fs.closeSync(lock);ownsLock=true;
}
const child = spawn(executable, ['app-server', '--stdio'], { stdio: ['pipe', 'pipe', 'pipe'] });
let serial = 0;
const pending = new Map();
child.stderr.on('data', () => {});
child.on('exit', () => { for (const {reject} of pending.values()) reject(new Error('Codex connection closed.')); });
createInterface({input:child.stdout}).on('line', line => {
  let m; try { m = JSON.parse(line); } catch { return; }
  if (pending.has(m.id)) { const p=pending.get(m.id);pending.delete(m.id);clearTimeout(p.timer);m.error ? p.reject(new Error(m.error.message)) : p.resolve(m.result); }
  else if (m.id != null && m.method) child.stdin.write(JSON.stringify({id:m.id,error:{code:-32601,message:'Interactive actions are not supported by memory sync.'}})+'\n');
});
const request = (method, params={}, timeout=120000) => new Promise((resolve,reject) => {
  const id=++serial;const timer=setTimeout(()=>{pending.delete(id);reject(new Error(`${method} timed out.`));},timeout);
  pending.set(id,{resolve,reject,timer});child.stdin.write(JSON.stringify({id,method,params})+'\n');
});
let threadID;
try {
 await request('initialize',{clientInfo:{name:'openassist_memory_sync',version:'1.0.0'},capabilities:{experimentalApi:true}});
 child.stdin.write(JSON.stringify({method:'initialized',params:{}})+'\n');
 const started=await request('thread/start',{cwd:os.homedir(),ephemeral:true,approvalPolicy:'never',config:{'features.apps':true,'features.plugins':true}});
 threadID=started.thread.id;
 const broker=new CodexPluginMCPBroker({request:(method,args,timeout)=>request(method,args,method === "mcpServer/tool/call" && String(args.tool).includes("refresh_second_brain_wiki") ? 900000 : timeout),openThread:async()=>threadID,closeThread:async()=>{},serverAliases:['openassist workspace','openassist_workspace'],sentinelTools:['list_second_brain_memory_sources','sync_second_brain_memory_source_file'],displayName:'OpenAssist Workspace'});
 let completed=0;
 const coordinator=new MemorySourceWorkspaceCoordinator({statePath:path.join(root,'sync-state.json'),machineID:machine,machineName:os.hostname(),homeDir:os.homedir(),callWorkspaceTool:async(name,args)=>{
   const result=await broker.callNamedTool(name,args,true);
   if(name==='sync_second_brain_memory_source_file'&&result.ok)console.log(JSON.stringify({event:'uploaded',count:++completed,source:args.sourceId}));
   return result;
 }});
 const preview=coordinator.preview();
 console.log(JSON.stringify({event:'preview',device:preview.device,counts:preview.counts,changed:preview.changed.length,unchanged:preview.unchangedCount,note:preview.note}));
 if(wiki) {
   // A short bounded pass. The server keeps an hourly cron for dirty wikis, so
   // the desktop never needs to grind through the whole backlog itself.
   for(let batch=0;batch<20;batch++) {
     const r=await broker.callNamedTool('refresh_second_brain_wiki',{limit:5},true);
     console.log(JSON.stringify({event:'wiki',...r}));
     if(!r.ok) {process.exitCode=1;break;}
     const v=r.response?.structuredContent;
     if(!v || v.failures?.length || v.history?.failures?.length) {process.exitCode=1;break;}
     if(!v.pending && !v.cleanupPending && !v.history?.pending) {
       if(v.preservedGenerated)console.log(JSON.stringify({event:'wiki_review',preserved:v.preservedGenerated}));
       break;
     }
     if(batch===19)process.exitCode=1;
   }
 }
 if(sync) {const result=await coordinator.sync();console.log(JSON.stringify({event:'complete',...result}));if(!result.ok)process.exitCode=1;}
} catch(error) {console.error(error.message);process.exitCode=1;}
finally {if(threadID)await request('thread/unsubscribe',{threadId:threadID},5000).catch(()=>{});child.kill();if(ownsLock)fs.unlinkSync(lockPath);}
