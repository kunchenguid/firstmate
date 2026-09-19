import {EventEmitter} from 'node:events';
import {PassThrough} from 'node:stream';
import {createInterface} from 'node:readline';

export function createFakeAppServer(scenario){
 const server=new EventEmitter(),input=new PassThrough();
 server.stdin=input;server.stdout=new PassThrough();server.stderr=new PassThrough();
 let toolStage='',exited=false,pendingAcknowledgement=null;
 const finish=()=>{
  if(exited)return;
  exited=true;server.stdout.end();server.stderr.end();
  setImmediate(()=>server.emit('exit',0,null));
 };
 const fail=error=>{server.stderr.write(error.message+'\n');server.emit('error',error);finish();};
 const send=value=>server.stdout.write(JSON.stringify(value)+'\n');
 const thread='primary';let turn='',turnNumber=0;
 const complete=(status='completed')=>send({method:'turn/completed',params:{threadId:thread,turn:{id:turn,status}}});
 const call=(id,tool,args,overrides={})=>send({id,method:'item/tool/call',params:{threadId:thread,turnId:turn,callId:'call-'+id,namespace:null,tool,arguments:args,...overrides}});
 const lines=createInterface({input});
 lines.on('line',line=>{
  try {
   const frame=JSON.parse(line);
   if(frame.method==='initialized')return;
   if(scenario==='interrupted-direct-ack'){
    if(frame.id===900){
     const result=JSON.parse(frame.result.contentItems[0].text);
     pendingAcknowledgement={receipt:result.receipt,observed:result.challenge};complete('interrupted');return;
    }
    if(frame.id===901){toolStage='reread';call(902,'fm_notification_check',{});return;}
    if(frame.id===902){
     const result=JSON.parse(frame.result.contentItems[0].text);
     toolStage='ack';call(903,'fm_notification_ack',{receipt:result.receipt,observed:result.challenge});return;
    }
    if(frame.id===903){complete();return;}
   }
   if(frame.id===900){
    if(scenario==='success'||scenario==='success-then-next-check'){
     const result=JSON.parse(frame.result.contentItems[0].text);
     toolStage='ack';call(901,'fm_notification_ack',{receipt:result.receipt,observed:result.challenge});
    }else complete();
    return;
   }
   if(frame.id===901){
    if(scenario==='success-then-next-check'){toolStage='next-check';call(902,'fm_notification_check',{});}
    else complete();
    return;
   }
   if(frame.id===902){complete();return;}
   if(frame.method==='initialize'){send({id:frame.id,result:{}});return;}
   if(frame.method==='config/read'){send({id:frame.id,result:{config:{features:{apps:false,plugins:false},mcp_servers:{}}}});return;}
   if(frame.method==='thread/start'){
    send({id:frame.id,result:{thread:{id:thread},sandbox:{type:'readOnly',networkAccess:false},approvalPolicy:'never'}});return;
   }
   if(frame.method==='app/installed'){send({id:frame.id,result:{apps:[]}});return;}
   if(frame.method==='mcpServerStatus/list'){send({id:frame.id,result:{data:[],nextCursor:null}});return;}
   if(frame.method==='turn/start'){
    turn='automatic-turn-'+(++turnNumber);
    send({id:frame.id,result:{turn:{id:turn}}});
    queueMicrotask(()=>{
     if(scenario==='prose')complete();
     else if(scenario==='denied'){toolStage='check';call(900,'fm_notification_check',{}, {namespace:'other'});}
     else if(scenario==='malformed'){toolStage='check';call(900,'fm_notification_check',null);}
     else if(scenario==='success'||scenario==='success-then-next-check'){toolStage='check';call(900,'fm_notification_check',{});}
     else if(scenario==='interrupted-direct-ack'){
      if(turnNumber===1){toolStage='check';call(900,'fm_notification_check',{});}
      else {toolStage='direct-ack';call(901,'fm_notification_ack',pendingAcknowledgement);}
     }
     else fail(Error('unknown scenario '+scenario));
    });
    return;
   }
   if(frame.method==='turn/interrupt'){send({id:frame.id,result:{}});return;}
   if(frame.id!==undefined&&frame.error)return;
   throw Error('unexpected frame '+JSON.stringify({frame,toolStage}));
  }catch(error){fail(error);}
 });
 lines.on('close',finish);
 server.kill=()=>{lines.close();input.destroy();finish();return true;};
 return server;
}
