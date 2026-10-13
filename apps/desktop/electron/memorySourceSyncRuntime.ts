import { app, dialog, Menu, MenuItem, shell } from "electron";
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { discoverMemorySources } from "./memorySourceSyncCore.js";
import { readStoredState } from "./memorySourceSyncService.js";

/** Compact integration that preserves the rest of the installed desktop app. */
export function startMemorySourceSyncRuntime() {
  const root=path.join(app.getPath("userData"),"SecondBrain","MemorySources");
  const settings=path.join(root,"settings.json");
  const statePath=path.join(root,"sync-state.json");
  const cli=path.join(app.getAppPath(),"bin","openassist-memory-sync.mjs");
  let running=false;
  let enabled=false;
  try { enabled=JSON.parse(fs.readFileSync(settings,"utf8")).enabled===true; } catch { /* First sync is opt-in. */ }
  const save=()=>{fs.mkdirSync(root,{recursive:true,mode:0o700});fs.writeFileSync(settings,JSON.stringify({enabled}),{mode:0o600});};
  const summary=()=>{
    const discovery=discoverMemorySources({homeDir:os.homedir()});
    const state=readStoredState(statePath);
    return {changed:discovery.files.filter(f=>state?.files?.[f.key]?.contentHash!==f.contentHash).length,count:discovery.files.length,lastSync:state?.lastSuccessfulAt};
  };
  /**
   * Did this sync actually upload anything? The CLI prints one JSON line per
   * event on stdout. Without at least one upload there is nothing new for the
   * wiki to describe, and the server already refreshes dirty wikis hourly.
   */
  const uploadedAtLeastOneFile=(output:string)=>{
    for(const line of output.split("\n")) {
      const text=line.trim();
      if(!text.startsWith("{"))continue;
      let event:{event?:unknown;uploaded?:unknown};
      try { event=JSON.parse(text); } catch { continue; }
      if(event.event==="uploaded")return true;
      if(event.event==="complete"&&typeof event.uploaded==="number"&&event.uploaded>0)return true;
    }
    return false;
  };
  const run=(manual=false,refreshWiki=false)=>{
    if(running)return;
    running=true;
    const child=spawn(process.execPath,[cli,"--sync"],{env:{...process.env,ELECTRON_RUN_AS_NODE:"1"},stdio:["ignore","pipe","pipe"]});
    let output="";let error="";
    child.stdout.on("data",chunk=>{output=(output+String(chunk)).slice(-500000);});
    child.stderr.on("data",chunk=>{error=(error+String(chunk)).slice(-500);});
    child.on("error",()=>{running=false;});
    child.on("close",async code=>{
      running=false;
      if(manual)await dialog.showMessageBox({type:code===0?"info":"warning",title:"Memory sync",message:code===0?(output.includes('"event":"already_syncing"')?"Memory sync is already running.":"Memory sync finished."):"Memory sync needs attention.",detail:code===0?"Use Memory > Sync status to see the last completed sync.":error||"Retry after checking the Workspace connection."});
      // Only refresh the wiki when this run actually changed something, or when
      // the owner explicitly asked for a refresh from the Memory menu.
      if(code===0&&!output.includes('"event":"already_syncing"')&&(refreshWiki||uploadedAtLeastOneFile(output))) {
        const wiki=spawn(process.execPath,[cli,"--wiki"],{env:{...process.env,ELECTRON_RUN_AS_NODE:"1"},stdio:"ignore"});
        wiki.on("error",()=>{});
      }
    });
  };
  const addMenu=()=>{
    const menu=Menu.getApplicationMenu();if(!menu||menu.items.some(i=>i.label==="Memory"))return;
    menu.append(new MenuItem({label:"Memory",submenu:[
      {label:"Sync now",click:()=>run(true)},
      {label:"Refresh wiki now",click:()=>run(true,true)},
      {label:"Sync status",click:async()=>{const s=summary();await dialog.showMessageBox({title:"Memory sources",message:`${s.count} curated memory files, ${s.changed} changes waiting`,detail:`Last completed sync: ${s.lastSync?new Date(s.lastSync).toLocaleString():"Not completed yet"}\nConversations are excluded. Files are saved to your connected Drive.`});}},
      {label:"Automatic sync",type:"checkbox",checked:enabled,click:item=>{enabled=item.checked;save();if(enabled)run();}},
      {label:"Open sync folder",click:()=>shell.openPath(root)},
    ]}));Menu.setApplicationMenu(menu);
  };
  const setup=setInterval(addMenu,3000);setup.unref();
  const timer=setInterval(()=>{if(enabled&&!running&&summary().changed>0)run();},5*60_000);timer.unref();
  app.on("before-quit",()=>{clearInterval(timer);clearInterval(setup);});
}
