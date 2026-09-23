const SUPABASE_URL = 'COLE_AQUI_SUA_SUPABASE_URL';
const SUPABASE_ANON_KEY = 'COLE_AQUI_SUA_SUPABASE_ANON_KEY';

const sb = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
const $ = id => document.getElementById(id);
const money = v => Number(v||0).toLocaleString('pt-BR',{style:'currency',currency:'BRL'});
let session, profile, categories=[], products=[], orders=[], commandItems=[], kitchenCart=[];
let editingOrder=null, closeOrderId=null, currentCategory='all';

function toast(msg){const el=$('toast');el.textContent=msg;el.classList.add('show');setTimeout(()=>el.classList.remove('show'),2600)}
function openModal(id){$(id).classList.remove('hidden')}
function closeModal(id){$(id).classList.add('hidden')}
function esc(s){return String(s??'').replace(/[&<>"']/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[m]))}

async function init(){
  sb.auth.onAuthStateChange(async(_e,s)=>{session=s;if(s) await loadApp(); else showLogin()});
  const {data}=await sb.auth.getSession(); session=data.session;
  if(session) await loadApp(); else showLogin();
}
function showLogin(){$('loginView').classList.remove('hidden');$('appView').classList.add('hidden')}
async function loadApp(){
  $('loginView').classList.add('hidden');$('appView').classList.remove('hidden');
  const p=await sb.from('profiles').select('*').eq('id',session.user.id).single();
  profile=p.data;
  $('userInfo').textContent=`${profile?.full_name||session.user.email} • ${profile?.role||''}`;
  document.querySelectorAll('.admin-only').forEach(x=>x.style.display=profile?.role==='admin'?'':'none');
  await loadAll(); subscribeRealtime();
}
async function loadAll(){
  const [c,p,o]=await Promise.all([
    sb.from('categories').select('*').order('name'),
    sb.from('products').select('*, categories(name)').order('name'),
    sb.from('orders').select('*').order('number',{ascending:false})
  ]);
  categories=c.data||[]; products=p.data||[]; orders=o.data||[];
  renderOrders();renderProducts();renderCategories();renderProductSelectors();renderCommandProducts();renderKitchenProducts();await loadCash();
}
function subscribeRealtime(){
  sb.channel('pos-live').on('postgres_changes',{event:'*',schema:'public',table:'orders'},()=>loadAll())
    .on('postgres_changes',{event:'*',schema:'public',table:'kitchen_orders'},()=>renderKitchenOrders())
    .subscribe();
}
function nav(){
  document.querySelectorAll('.nav').forEach(b=>b.onclick=()=>{
    document.querySelectorAll('.nav').forEach(x=>x.classList.remove('active'));b.classList.add('active');
    document.querySelectorAll('.section').forEach(x=>x.classList.add('hidden'));$(b.dataset.section).classList.remove('hidden');
    if(b.dataset.section==='kitchenSection') renderKitchenOrders();
  });
}
function renderOrders(){
  const open=orders.filter(o=>o.status==='open');
  $('ordersGrid').innerHTML=open.length?open.map(o=>`
    <article class="order-card">
      <h3>Comanda #${o.number}</h3>
      <div>${esc(o.customer_name||'Cliente não informado')} • Mesa ${esc(o.table_number||'-')}</div>
      <div class="total">${money(o.total)}</div>
      <span class="status">ABERTA</span>
      <div class="card-actions" style="margin-top:12px">
        <button onclick="editOrder('${o.id}')">Abrir</button>
        <button onclick="askClose('${o.id}')">Fechar</button>
        <button onclick="printOrder('${o.id}')">Imprimir</button>
        <button class="danger" onclick="cancelOrder('${o.id}')">Excluir</button>
      </div>
    </article>`).join(''):'<p>Nenhuma comanda aberta.</p>';
}
async function renderKitchenOrders(){
  const {data}=await sb.from('kitchen_orders').select('*, kitchen_order_items(*)').order('number',{ascending:false}).limit(30);
  $('kitchenGrid').innerHTML=(data||[]).map(k=>`
    <article class="kitchen-card">
      <h3>Cozinha #${k.number}</h3>
      <div>${esc(k.customer_name||'Cliente')} • Mesa ${esc(k.table_number||'-')}</div>
      <p><span class="status">${esc(k.status)}</span></p>
      ${(k.kitchen_order_items||[]).map(i=>`<div>${i.quantity}x ${esc(i.product_name)}</div>`).join('')}
      <div class="card-actions" style="margin-top:10px">
        <button onclick="setKitchenStatus('${k.id}','PREPARING')">Em preparo</button>
        <button onclick="setKitchenStatus('${k.id}','READY')">Pronto</button>
        <button onclick="setKitchenStatus('${k.id}','DELIVERED')">Entregue</button>
      </div>
    </article>`).join('')||'<p>Nenhum pedido.</p>';
}
async function setKitchenStatus(id,status){await sb.from('kitchen_orders').update({status}).eq('id',id);renderKitchenOrders()}
function renderCommandProducts(){
  const list=currentCategory==='all'?products:products.filter(p=>p.category_id===currentCategory);
  $('commandProducts').innerHTML=list.filter(p=>p.active).map(p=>`
    <button class="product" onclick="addCartProduct('${p.id}')"><strong>${esc(p.name)}</strong><small>${money(p.price)} ${p.send_to_kitchen?'• 🍳 cozinha':''}</small></button>`).join('');
  $('categoryFilters').innerHTML=`<button class="${currentCategory==='all'?'active':''}" onclick="filterCategory('all')">Todos</button>`+
    categories.filter(c=>c.active).map(c=>`<button class="${currentCategory===c.id?'active':''}" onclick="filterCategory('${c.id}')">${esc(c.name)}</button>`).join('');
}
function filterCategory(id){currentCategory=id;renderCommandProducts()}
function addCartProduct(id){
  const p=products.find(x=>x.id===id);if(!p)return;
  let x=commandItems.find(i=>i.product_id===id&&!i.voided);
  if(x)x.quantity++;
  else commandItems.push({id:null,product_id:p.id,product_name:p.name,unit_price:Number(p.price),quantity:1,send_to_kitchen:p.send_to_kitchen,kitchen_sent_qty:0,kitchen_cancelled_qty:0,voided:false});
  renderCommandCart();
}
function renderCommandCart(){
  $('commandCart').innerHTML=commandItems.filter(i=>!i.voided).map((i,idx)=>`
    <div class="cart-row">
      <div>${esc(i.product_name)}${i.send_to_kitchen?' 🍳':''}</div>
      <div class="qty"><button onclick="changeQty(${idx},-1)">−</button>${i.quantity}<button onclick="changeQty(${idx},1)">+</button></div>
      <div>${money(i.unit_price*i.quantity)}</div>
      <button onclick="removeCart(${idx})">×</button>
    </div>`).join('')||'<small>Nenhum item.</small>';
  const total=commandItems.filter(i=>!i.voided).reduce((s,i)=>s+i.quantity*i.unit_price,0);
  $('commandTotal').textContent=money(total);
}
function changeQty(idx,d){commandItems[idx].quantity=Math.max(1,Number(commandItems[idx].quantity)+d);renderCommandCart()}
function removeCart(idx){commandItems[idx].voided=true;commandItems[idx].quantity=0;renderCommandCart()}
function openNewCommand(){
  editingOrder=null;commandItems=[];$('commandModalTitle').textContent='Nova comanda';$('commandCustomer').value='';$('commandTable').value='';renderCommandCart();openModal('commandModal');
}
async function editOrder(id){
  editingOrder=orders.find(o=>o.id===id);if(!editingOrder)return;
  const r=await sb.from('order_items').select('*').eq('order_id',id).order('created_at');
  commandItems=(r.data||[]).map(x=>({...x}));
  $('commandModalTitle').textContent=`Comanda #${editingOrder.number}`;
  $('commandCustomer').value=editingOrder.customer_name||'';$('commandTable').value=editingOrder.table_number||'';
  renderCommandCart();openModal('commandModal');
}
async function saveCommand(){
  const customer=$('commandCustomer').value.trim(),table=$('commandTable').value.trim();
  if(!editingOrder){
    const r=await sb.from('orders').insert({customer_name:customer,table_number:table,opened_by:session.user.id}).select().single();
    if(r.error){toast(r.error.message);return} editingOrder=r.data;
  }else await sb.from('orders').update({customer_name:customer,table_number:table}).eq('id',editingOrder.id);

  const old=(await sb.from('order_items').select('*').eq('order_id',editingOrder.id)).data||[];
  for(const item of commandItems){
    if(!item.id){
      if(item.voided)continue;
      const r=await sb.from('order_items').insert({
        order_id:editingOrder.id,product_id:item.product_id,product_name:item.product_name,unit_price:item.unit_price,
        quantity:item.quantity,send_to_kitchen:item.send_to_kitchen
      }).select().single();
      if(r.error){toast(r.error.message);continue}
      if(item.send_to_kitchen){
        await sendKitchenBatch(editingOrder,r.data,item.quantity,'ORDER');
      }
    }else{
      const previous=old.find(x=>x.id===item.id);if(!previous)continue;
      const effective=Number(previous.kitchen_sent_qty)-Number(previous.kitchen_cancelled_qty);
      if(!item.voided && item.quantity>effective && item.send_to_kitchen){
        await sendKitchenBatch(editingOrder,item,item.quantity-effective,'ORDER');
      }
      if((item.voided?0:item.quantity)<effective && item.send_to_kitchen){
        await sendKitchenBatch(editingOrder,item,effective-(item.voided?0:item.quantity),'CANCEL');
      }
      await sb.from('order_items').update({
        quantity:item.voided?0:item.quantity,voided:!!item.voided,
        product_name:item.product_name,unit_price:item.unit_price,send_to_kitchen:item.send_to_kitchen
      }).eq('id',item.id);
    }
  }
  const currentIds=new Set(commandItems.filter(i=>i.id).map(i=>i.id));
  for(const o of old){
    if(!currentIds.has(o.id) && !o.voided){
      const effective=Number(o.kitchen_sent_qty)-Number(o.kitchen_cancelled_qty);
      if(effective>0 && o.send_to_kitchen) await sendKitchenBatch(editingOrder,o,effective,'CANCEL');
      if(effective>0) await sb.from('order_items').update({quantity:0,voided:true}).eq('id',o.id);
      else await sb.from('order_items').delete().eq('id',o.id);
    }
  }
  toast('Comanda salva');closeModal('commandModal');await loadAll();
}
async function sendKitchenBatch(order,item,qty,type='ORDER'){
  if(!qty)return;
  const payload=[{order_item_id:item.id,product_id:item.product_id,product_name:item.product_name,quantity:qty,notes:item.notes||''}];
  const r=await sb.rpc('create_kitchen_batch',{p_order_id:order.id,p_customer_name:order.customer_name||'',p_table_number:order.table_number||'',p_items:payload,p_order_type:type});
  if(r.error)toast('Erro cozinha: '+r.error.message);
}
async function cancelOrder(id){
  if(!confirm('Excluir/cancelar esta comanda?'))return;
  await sb.from('orders').update({status:'cancelled'}).eq('id',id);await loadAll();
}
function askClose(id){
  const o=orders.find(x=>x.id===id);if(!o)return;
  closeOrderId=id;$('closeTotal').textContent=money(o.total);$('paymentAmount').value=Number(o.total).toFixed(2);openModal('closeModal');
}
async function finishClose(print){
  const amount=Number($('paymentAmount').value);const o=orders.find(x=>x.id===closeOrderId);
  if(Math.abs(amount-Number(o.total))>.009){toast('O valor recebido deve ser igual ao total.');return}
  const r=await sb.rpc('close_order',{p_order_id:closeOrderId,p_payments:[{method:$('paymentMethod').value,amount}],p_print:print});
  if(r.error){toast(r.error.message);return}
  closeModal('closeModal');await loadAll();toast('Comanda fechada');
}
async function printOrder(id){
  const o=orders.find(x=>x.id===id);if(!o)return;
  const items=(await sb.from('order_items').select('*').eq('order_id',id).eq('voided',false)).data||[];
  const html=`<div class="receipt"><h2>Cumpadres FC</h2><b>Comanda #${o.number}</b><p>Mesa: ${esc(o.table_number||'-')}<br>Cliente: ${esc(o.customer_name||'-')}</p>${items.map(i=>`<div>${i.quantity}x ${esc(i.product_name)}<span>${money(i.quantity*i.unit_price)}</span></div>`).join('')}<hr><h3>TOTAL ${money(o.total)}</h3></div>`;
  const w=window.open('','_blank','width=360,height=700');w.document.write(`<style>@page{size:58mm auto;margin:0}body{font:12px Arial;width:54mm;margin:2mm}.receipt h2{text-align:center}.receipt div{display:flex;justify-content:space-between;margin:4px 0}</style>${html}`);w.document.close();w.focus();w.print();
}
function renderKitchenProducts(){
  $('kitchenProducts').innerHTML=products.filter(p=>p.active&&p.send_to_kitchen).map(p=>`<button class="product" onclick="addKitchenProduct('${p.id}')"><strong>${esc(p.name)}</strong><small>${money(p.price)}</small></button>`).join('');
}
function addKitchenProduct(id){const p=products.find(x=>x.id===id);let x=kitchenCart.find(i=>i.product_id===id);if(x)x.quantity++;else kitchenCart.push({product_id:p.id,product_name:p.name,quantity:1});renderKitchenCart()}
function renderKitchenCart(){$('kitchenCart').innerHTML=kitchenCart.map((i,n)=>`<div class="cart-row"><div>${esc(i.product_name)}</div><div>${i.quantity}</div><div></div><button onclick="kitchenCart.splice(${n},1);renderKitchenCart()">×</button></div>`).join('')||'<small>Nenhum item.</small>'}
async function sendDirectKitchen(){
  if(!kitchenCart.length){toast('Adicione itens');return}
  const r=await sb.rpc('create_kitchen_batch',{p_order_id:null,p_customer_name:$('kitchenCustomer').value,p_table_number:$('kitchenTable').value,p_items:kitchenCart,p_order_type:'ORDER'});
  if(r.error){toast(r.error.message);return}
  kitchenCart=[];renderKitchenCart();closeModal('kitchenModal');toast('Pedido enviado para a cozinha e colocado na fila de impressão');renderKitchenOrders();
}
function renderProducts(){
  $('productsTable').innerHTML=`<table class="table"><tr><th>Produto</th><th>Categoria</th><th>Preço</th><th>Cozinha</th><th></th></tr>${products.map(p=>`<tr><td>${esc(p.name)}</td><td>${esc(p.categories?.name||'-')}</td><td>${money(p.price)}</td><td>${p.send_to_kitchen?'Sim':'Não'}</td><td><button onclick="editProduct('${p.id}')">Editar</button></td></tr>`).join('')}</table>`;
}
function renderCategories(){$('categoriesTable').innerHTML=`<table class="table"><tr><th>Categoria</th><th>Status</th><th></th></tr>${categories.map(c=>`<tr><td>${esc(c.name)}</td><td>${c.active?'Ativa':'Inativa'}</td><td><button onclick="editCategory('${c.id}')">Editar</button></td></tr>`).join('')}</table>`}
function renderProductSelectors(){$('productCategory').innerHTML='<option value="">Sem categoria</option>'+categories.map(c=>`<option value="${c.id}">${esc(c.name)}</option>`).join('')}
function editProduct(id){const p=products.find(x=>x.id===id);$('productId').value=p.id;$('productName').value=p.name;$('productPrice').value=p.price;$('productCategory').value=p.category_id||'';$('productKitchen').checked=p.send_to_kitchen;$('productActive').checked=p.active;openModal('productModal')}
async function saveProduct(){
  const data={name:$('productName').value.trim(),price:Number($('productPrice').value),category_id:$('productCategory').value||null,send_to_kitchen:$('productKitchen').checked,active:$('productActive').checked};
  const id=$('productId').value;const r=id?await sb.from('products').update(data).eq('id',id):await sb.from('products').insert(data);
  if(r.error){toast(r.error.message);return}closeModal('productModal');await loadAll();
}
function editCategory(id){const c=categories.find(x=>x.id===id);$('categoryId').value=c.id;$('categoryName').value=c.name;openModal('categoryModal')}
async function saveCategory(){const name=$('categoryName').value.trim(),id=$('categoryId').value;const r=id?await sb.from('categories').update({name}).eq('id',id):await sb.from('categories').insert({name});if(r.error)toast(r.error.message);else{closeModal('categoryModal');await loadAll()}}
async function loadCash(){
  const r=await sb.from('cash_sessions').select('*').eq('status','open').order('opened_at',{ascending:false}).limit(1).maybeSingle();
  const open=!!r.data;$('cashBadge').textContent=open?'CAIXA ABERTO':'CAIXA FECHADO';$('cashBadge').style.background=open?'#e9f8ee':'#ffecec';$('cashStatusText').textContent=open?`Aberto em ${new Date(r.data.opened_at).toLocaleString('pt-BR')}`:'Caixa fechado';
}
async function openCash(){const v=Number($('openingBalance').value||0);const r=await sb.from('cash_sessions').insert({opened_by:session.user.id,opening_balance:v});if(r.error)toast(r.error.message);else{toast('Caixa aberto');loadCash()}}
async function closeCash(){const r=await sb.from('cash_sessions').select('id').eq('status','open').order('opened_at',{ascending:false}).limit(1).maybeSingle();if(!r.data){toast('Nenhum caixa aberto');return}const v=Number($('closingBalance').value||0);const x=await sb.from('cash_sessions').update({status:'closed',closed_by:session.user.id,closing_balance:v,closed_at:new Date().toISOString()}).eq('id',r.data.id);if(x.error)toast(x.error.message);else{toast('Caixa fechado');loadCash()}}
$('loginBtn').onclick=async()=>{const r=await sb.auth.signInWithPassword({email:$('loginEmail').value,password:$('loginPassword').value});if(r.error)$('loginMsg').textContent=r.error.message}
$('signupBtn').onclick=async()=>{const r=await sb.auth.signUp({email:$('loginEmail').value,password:$('loginPassword').value,data:{full_name:prompt('Nome')}});$('loginMsg').textContent=r.error?r.error.message:'Cadastro criado. Se o Supabase exigir confirmação, confirme o e-mail.'}
$('logoutBtn').onclick=()=>sb.auth.signOut();$('refreshBtn').onclick=loadAll;$('newCommandBtn').onclick=openNewCommand;$('saveCommandBtn').onclick=saveCommand;$('closeCommandModalBtn').onclick=()=>closeModal('commandModal');
$('closePrintBtn').onclick=()=>finishClose(true);$('closeNoPrintBtn').onclick=()=>finishClose(false);$('newKitchenBtn').onclick=()=>{kitchenCart=[];renderKitchenCart();$('kitchenCustomer').value='';$('kitchenTable').value='';openModal('kitchenModal')};$('sendKitchenBtn').onclick=sendDirectKitchen;
$('newProductBtn').onclick=()=>{$('productId').value='';$('productName').value='';$('productPrice').value='';$('productKitchen').checked=false;$('productActive').checked=true;openModal('productModal')};
$('saveProductBtn').onclick=saveProduct;$('newCategoryBtn').onclick=()=>{$('categoryId').value='';$('categoryName').value='';openModal('categoryModal')};$('saveCategoryBtn').onclick=saveCategory;
$('openCashBtn').onclick=openCash;$('closeCashBtn').onclick=closeCash;$('customItemBtn').onclick=()=>openModal('customModal');
$('addCustomBtn').onclick=()=>{const name=$('customName').value.trim(),price=Number($('customPrice').value),qty=Number($('customQty').value||1);if(!name||price<0)return toast('Preencha nome e preço');commandItems.push({id:null,product_id:null,product_name:name,unit_price:price,quantity:qty,send_to_kitchen:$('customKitchen').checked,kitchen_sent_qty:0,kitchen_cancelled_qty:0,voided:false});closeModal('customModal');renderCommandCart()};
document.querySelectorAll('[data-close]').forEach(b=>b.onclick=()=>closeModal(b.dataset.close));nav();init();
