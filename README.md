# Cumpadres FC V2

Sistema de comandas com:
- Supabase Auth + PostgreSQL + RLS
- Categorias e produtos
- Produtos pré-cadastrados e itens avulsos
- Comandas abertas em tempo real
- Inclusão, alteração e exclusão lógica de itens
- Controle de quantidade já enviada à cozinha
- Impressão de novos itens da cozinha
- Impressão de cancelamentos quando um item já enviado é reduzido/removido
- Pedido direto para cozinha sem abrir comanda
- Caixa
- Impressão de fechamento/recibo
- Fila de impressão para impressora térmica 58 mm

## 1. Supabase

1. Crie um projeto no Supabase.
2. Abra SQL Editor.
3. Execute `supabase.sql` inteiro.
4. No primeiro cadastro pelo sistema, o primeiro usuário é criado como `admin`.
5. Se precisar promover outro usuário:
   `update public.profiles set role='admin' where id='UUID';`
6. Em `Table Editor > printers`, cadastre:
   - uma impressora `type = kitchen`
   - uma impressora `type = receipt`
   e preencha `windows_printer_name` exatamente como aparece no Windows.

## 2. Frontend

Abra `app.js` e substitua:
- COLE_AQUI_SUA_SUPABASE_URL
- COLE_AQUI_SUA_SUPABASE_ANON_KEY

Depois publique os três arquivos:
- index.html
- style.css
- app.js

Para desenvolvimento local pode usar Live Server.

## 3. Impressão automática da cozinha

O navegador não deve receber a SERVICE_ROLE_KEY. Ela fica somente no computador que possui a impressora.

Na pasta `print-service`:
1. instale Node.js LTS.
2. copie `config.example.json` para `config.json`.
3. preencha URL e SERVICE_ROLE_KEY.
4. confira o nome das impressoras no Windows.
5. execute:
   npm install
   npm start

O serviço verifica a fila do Supabase, gera uma página 58 mm e envia para a impressora do Windows.

## 4. Fluxo

Comanda:
Produto marcado "Enviar para cozinha" -> salvar -> RPC -> kitchen_orders -> print_jobs -> serviço local -> impressora.

Pedido direto:
Pedido Cozinha -> selecionar itens -> RPC -> print_jobs -> impressora.

Alteração:
- aumento de quantidade: imprime somente a diferença.
- redução/remover item já enviado: imprime CANCELAMENTO da quantidade retirada.
- item ainda não enviado: não gera cancelamento.

## 5. Segurança

Nunca coloque a SUPABASE_SERVICE_ROLE_KEY no HTML/JS.
Somente a ANON KEY pode ficar no frontend.

## 6. Observação sobre impressoras USB

O serviço usa o spooler de impressão do Windows. Isso permite trabalhar com impressoras térmicas instaladas no Windows, inclusive USB, desde que o driver esteja instalado e a impressora apareça em Impressoras e scanners.

Para impressora de rede, também é possível instalar a impressora no Windows e usar o mesmo fluxo.
