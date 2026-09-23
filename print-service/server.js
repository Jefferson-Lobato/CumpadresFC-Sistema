const fs = require('fs');
const path = require('path');
const os = require('os');
const PDFDocument = require('pdfkit');
const printer = require('pdf-to-printer');
const { createClient } = require('@supabase/supabase-js');

const config = JSON.parse(fs.readFileSync(path.join(__dirname,'config.json'),'utf8'));
const sb = createClient(config.supabaseUrl, config.supabaseServiceKey, {
  auth: { persistSession:false, autoRefreshToken:false }
});

const sleep = ms => new Promise(r=>setTimeout(r,ms));
const money = v => Number(v||0).toLocaleString('pt-BR',{style:'currency',currency:'BRL'});
const WIDTH = 164; // ~58mm em pontos

function makePdf(job, filename){
  return new Promise((resolve,reject)=>{
    const payload=job.payload||{};
    const isReceipt=job.job_type==='RECEIPT';
    const items=payload.items||[];
    const height=170 + items.length*32 + (isReceipt?120:0);
    const doc=new PDFDocument({size:[WIDTH,height],margin:6});
    const out=fs.createWriteStream(filename);
    doc.pipe(out);

    const center=t=>doc.font('Helvetica-Bold').fontSize(12).text(String(t),{align:'center'});
    const line=t=>doc.font('Helvetica').fontSize(8.5).text(String(t));
    const sep=()=>doc.text('--------------------------------');
    center(payload.bar_name||'CUMPADRES FC');
    center(isReceipt?'COMPROVANTE':'COZINHA');
    doc.moveDown(.3);
    line(`Pedido: #${payload.order_number||payload.kitchen_order_id||''}`);
    line(`Mesa: ${payload.table_number||'-'}`);
    line(`Cliente: ${payload.customer_name||'-'}`);
    if(payload.order_type==='CANCEL') center('*** CANCELAMENTO ***');
    sep();

    for(const i of items){
      const q=Number(i.quantity||0);
      if(isReceipt){
        doc.font('Helvetica').fontSize(8.5).text(`${q}x ${i.product_name}`);
        doc.text(money(i.subtotal ?? q*Number(i.unit_price||0)),{align:'right'});
      }else{
        doc.font('Helvetica-Bold').fontSize(10).text(`${q}x ${i.product_name}`);
        if(i.notes) line(`Obs: ${i.notes}`);
      }
      doc.moveDown(.15);
    }

    if(isReceipt){
      sep();
      doc.font('Helvetica-Bold').fontSize(11).text(`TOTAL ${money(payload.total)}`);
      doc.moveDown(.4);
      for(const p of (payload.payments||[])) line(`${p.method}: ${money(p.amount)}`);
    }
    doc.moveDown(.8);
    line(new Date(payload.created_at||Date.now()).toLocaleString('pt-BR'));
    doc.end();
    out.on('finish',()=>resolve(filename));
    out.on('error',reject);
  });
}

async function getPrinterName(job){
  if(job.printer_id){
    const r=await sb.from('printers').select('windows_printer_name').eq('id',job.printer_id).single();
    if(!r.error && r.data?.windows_printer_name)return r.data.windows_printer_name;
  }
  const type=job.job_type==='KITCHEN'?'kitchen':'receipt';
  const r=await sb.from('printers').select('windows_printer_name').eq('type',type).eq('active',true).limit(1).single();
  if(r.error) throw new Error('Impressora não cadastrada no Supabase');
  if(!r.data.windows_printer_name) throw new Error('windows_printer_name não configurado');
  return r.data.windows_printer_name;
}

async function processJob(job){
  const printerName=await getPrinterName(job);
  const filename=path.join(os.tmpdir(),`cumpadres-${job.id}.pdf`);
  try{
    await makePdf(job,filename);
    await printer.print(filename,{printer:printerName});
    await sb.rpc('complete_print_job',{p_job_id:job.id,p_success:true});
    console.log(`Impresso ${job.id} em ${printerName}`);
  }catch(err){
    console.error(err);
    await sb.rpc('complete_print_job',{p_job_id:job.id,p_success:false,p_error:String(err.message||err)});
  }finally{
    try{fs.unlinkSync(filename)}catch{}
  }
}

async function main(){
  console.log('Cumpadres FC Print Service iniciado');
  while(true){
    try{
      const {data,error}=await sb.rpc('claim_print_job');
      if(error) console.error('Fila:',error.message);
      else if(data?.length) await processJob(data[0]);
    }catch(e){console.error(e)}
    await sleep(config.pollIntervalMs||1200);
  }
}
main();
