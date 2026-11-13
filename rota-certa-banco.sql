-- ==========================================================================
-- Rota Certa — banco de dados (PostgreSQL / Supabase) — versão 2
--
-- Como usar: Supabase > SQL Editor > cole tudo > Run. Em um projeto novo e vazio.
--
-- Ideias principais
--  * Várias empresas no mesmo banco: toda tabela carrega empresa_id e as regras
--    de acesso (RLS) mostram a cada usuário só a empresa dele.
--  * O app só LÊ as tabelas. Toda gravação passa por funções abaixo (RPC) que
--    conferem quem é o usuário, validam os dados e registram na auditoria.
--  * Datas sempre no fuso do Brasil (America/Sao_Paulo), nunca em UTC.
--  * Login: o app transforma  usuário + chave da empresa  no e-mail interno
--    usuario+chave@rotacerta.app  (o "+" garante que não haja colisão).
-- ==========================================================================

create extension if not exists pgcrypto;

-- --------------------------------------------------------------------------
-- Utilidades
-- --------------------------------------------------------------------------
-- Domínio usado nos e-mails internos de login (usuario+chave@dominio). Nenhum e-mail é enviado.
-- Se o Supabase recusar o cadastro com "email_address_invalid", troque por um domínio seu que receba e-mail
-- (e use o MESMO valor em DOMINIO_EMAIL no index.html).
create function email_dominio() returns text language sql immutable as $$ select 'rotacerta.app'::text $$;

create function hoje_br() returns date
language sql stable as $$ select (now() at time zone 'America/Sao_Paulo')::date $$;

create function brl(v numeric) returns text
language sql immutable as $$
  select 'R$ ' || regexp_replace(replace(to_char(coalesce(v,0), 'FM9999999990.00'), '.', ','),
                                 '(\d)(?=(\d{3})+,)', '\1.', 'g')
$$;

create function numero_ficha(n integer) returns text
language sql immutable as $$ select lpad(n::text, 6, '0') $$;

create function cpf_valido(p text) returns boolean
language plpgsql immutable as $$
declare d text := regexp_replace(coalesce(p,''), '\D', '', 'g'); s int := 0; r int; i int;
begin
  if length(d) <> 11 or d ~ '^(\d)\1{10}$' then return false; end if;
  for i in 1..9 loop s := s + substr(d,i,1)::int * (11 - i); end loop;
  r := (s * 10) % 11; if r = 10 then r := 0; end if;
  if r <> substr(d,10,1)::int then return false; end if;
  s := 0;
  for i in 1..10 loop s := s + substr(d,i,1)::int * (12 - i); end loop;
  r := (s * 10) % 11; if r = 10 then r := 0; end if;
  return r = substr(d,11,1)::int;
end $$;

-- --------------------------------------------------------------------------
-- Empresas, usuários e convites
-- --------------------------------------------------------------------------
create table empresas (
  id                   uuid primary key default gen_random_uuid(),
  nome                 text not null,
  chave_acesso         text not null unique check (chave_acesso ~ '^[a-z0-9._-]{3,30}$'),
  ativa                boolean not null default true,        -- false = assinatura suspensa
  cobradores_incluidos integer not null default 2,           -- vagas que já vêm no preço base
  valor_cobrador_extra numeric(10,2),                        -- preço de cada cobrador além das vagas
  criada_em            timestamptz not null default now()
);

create table perfis (
  id             uuid primary key references auth.users(id) on delete cascade,
  empresa_id     uuid not null references empresas(id),
  nome           text not null,
  usuario        text not null check (usuario ~ '^[a-z0-9._-]{3,30}$'),
  papel          text not null check (papel in ('admin','cobrador')),
  periodicidade  text not null default 'semanal' check (periodicidade in ('semanal','mensal')),
  comissao_pct   numeric(5,2) not null default 10,
  ativo          boolean not null default true,
  criado_em      timestamptz not null default now(),
  desativado_em  timestamptz,
  unique (empresa_id, usuario)
);

-- Convites: você gera um código por cliente que comprar o sistema
create table convites (
  codigo               text primary key,
  cobradores_incluidos integer not null default 2,
  valor_cobrador_extra numeric(10,2),
  usado_em             timestamptz,
  empresa_id           uuid references empresas(id),
  criado_em            timestamptz not null default now()
);

create table rotas_bairros (
  empresa_id   uuid not null references empresas(id),
  bairro       text not null,
  cobrador_id  uuid not null references perfis(id),
  primary key (empresa_id, bairro)
);
create unique index on rotas_bairros (empresa_id, lower(bairro));

-- --------------------------------------------------------------------------
-- Clientes e fichas
-- --------------------------------------------------------------------------
create table clientes (
  id          uuid primary key default gen_random_uuid(),
  empresa_id  uuid not null references empresas(id),
  nome        text not null,
  endereco    text,
  referencia  text,
  bairro      text,
  telefone    text,
  criado_em   timestamptz not null default now()
);
create index on clientes (empresa_id, lower(nome));

-- CPF em tabela separada: só o administrador lê. (As regras de acesso funcionam por
-- linha, não por coluna: no cadastro do cliente o cobrador também conseguiria ler o CPF.)
create table clientes_documentos (
  cliente_id  uuid primary key references clientes(id) on delete cascade,
  empresa_id  uuid not null references empresas(id),
  cpf         char(11) not null check (cpf ~ '^[0-9]{11}$'),
  unique (empresa_id, cpf)
);

create table fichas (
  id                  uuid primary key default gen_random_uuid(),
  empresa_id          uuid not null references empresas(id),
  numero              integer not null check (numero > 0),
  cliente_id          uuid not null references clientes(id),
  cobrador_id         uuid not null references perfis(id),
  mercadoria          text not null,
  valor_total         numeric(10,2) not null check (valor_total > 0),
  valor_pago          numeric(10,2) not null default 0,
  parcela             numeric(10,2) not null check (parcela > 0),
  -- dia da visita atual. Só muda quando o administrador confere o dia do cobrador.
  data_cobranca       date not null,
  -- 'pendente' = a cobrar em data_cobranca; 'paga' = recebeu hoje; 'remarcada' = remarcada/não visitada.
  -- Em 'paga' e 'remarcada', proxima_data é o dia em que a ficha volta (aplicado na conferência).
  status              text not null default 'pendente' check (status in ('pendente','paga','remarcada')),
  proxima_data        date,
  nao_visitada        boolean not null default false,
  quitada             boolean not null default false,
  cancelada           boolean not null default false,
  motivo_cancelamento text,
  criada_em           timestamptz not null default now(),
  unique (empresa_id, numero)                         -- bloqueia número repetido
);
create index on fichas (empresa_id, cobrador_id, data_cobranca) where not quitada and not cancelada;
create index on fichas (empresa_id, cliente_id);
create index on fichas (empresa_id) where not quitada and not cancelada;

create table pagamentos (
  id              uuid primary key default gen_random_uuid(),
  empresa_id      uuid not null references empresas(id),
  ficha_id        uuid not null references fichas(id),
  cobrador_id     uuid not null references perfis(id),  -- quem cobrou (não muda se a ficha for transferida)
  data            date not null,
  valor           numeric(10,2) not null check (valor > 0),
  forma           text,
  inicial         boolean not null default false,       -- já estava pago antes do sistema (importação)
  corrigido       boolean not null default false,
  criado_em       timestamptz not null default now(),
  id_cliente_app  uuid unique,                          -- evita duplicar quando o app reenvia (modo sem internet)
  check ((inicial and forma is null) or (not inicial and forma in ('dinheiro','pix')))
);
create index on pagamentos (empresa_id, data);
create index on pagamentos (empresa_id, cobrador_id, data);
create index on pagamentos (ficha_id);

-- --------------------------------------------------------------------------
-- Fechamento do dia, vales, prestação de contas e auditoria
-- --------------------------------------------------------------------------
create table fechamentos_dia (
  id               uuid primary key default gen_random_uuid(),
  empresa_id       uuid not null references empresas(id),
  cobrador_id      uuid not null references perfis(id),
  data             date not null,
  enviado_em       timestamptz,                  -- cobrador enviou o resultado do dia
  pix_esperado     numeric(10,2),
  especie_esperada numeric(10,2),
  especie_entregue numeric(10,2),
  diferenca        numeric(10,2),                -- o que faltou vira vale automático
  confirmado_por   uuid references perfis(id),
  confirmado_em    timestamptz,
  unique (empresa_id, cobrador_id, data)
);

create table vales (
  id            uuid primary key default gen_random_uuid(),
  empresa_id    uuid not null references empresas(id),
  cobrador_id   uuid not null references perfis(id),
  data          date not null,
  valor         numeric(10,2) not null check (valor > 0),
  origem        text not null default 'manual' check (origem in ('manual','diferenca_fechamento')),
  fechamento_id uuid references fechamentos_dia(id),
  criado_em     timestamptz not null default now()
);
create index on vales (empresa_id, cobrador_id);

create table prestacoes_contas (
  id              uuid primary key default gen_random_uuid(),
  empresa_id      uuid not null references empresas(id),
  cobrador_id     uuid not null references perfis(id),
  periodo_ini     date,
  periodo_fim     date not null,
  total_cobrado   numeric(10,2) not null,
  comissao        numeric(10,2) not null,
  vales           numeric(10,2) not null,
  saldo_anterior  numeric(10,2) not null default 0,  -- negativo = dívida que veio da prestação anterior
  saldo_final     numeric(10,2) not null,            -- negativo = cobrador ficou devendo
  criada_em       timestamptz not null default now()
);
create index on prestacoes_contas (empresa_id, cobrador_id, criada_em desc);

create table auditoria (
  id          bigserial primary key,
  empresa_id  uuid not null references empresas(id),
  usuario_id  uuid,
  quem        text not null,
  acao        text not null,
  detalhe     text not null default '',
  criado_em   timestamptz not null default now()
);
create index on auditoria (empresa_id, criado_em desc);

-- Visão para você (dono do sistema) cobrar os cobradores extras de cada empresa.
-- Rode no SQL Editor; as empresas não conseguem ver os dados umas das outras.
create view empresas_cobradores_extras with (security_invoker = true) as
select e.id as empresa_id, e.nome, e.ativa,
       count(p.id) filter (where p.papel = 'cobrador' and p.ativo)                  as cobradores_ativos,
       e.cobradores_incluidos,
       greatest(count(p.id) filter (where p.papel = 'cobrador' and p.ativo)
                - e.cobradores_incluidos, 0)                                         as cobradores_extras,
       greatest(count(p.id) filter (where p.papel = 'cobrador' and p.ativo)
                - e.cobradores_incluidos, 0) * coalesce(e.valor_cobrador_extra, 0)   as valor_extra_mensal
from empresas e
left join perfis p on p.empresa_id = e.id
group by e.id;

-- --------------------------------------------------------------------------
-- Quem é o usuário (usado nas regras de acesso e nas funções)
-- --------------------------------------------------------------------------
create function empresa_atual() returns uuid
language sql stable security definer set search_path = public as $$
  select p.empresa_id from perfis p join empresas e on e.id = p.empresa_id
   where p.id = auth.uid() and p.ativo and e.ativa
$$;

create function papel_atual() returns text
language sql stable security definer set search_path = public as $$
  select p.papel from perfis p join empresas e on e.id = p.empresa_id
   where p.id = auth.uid() and p.ativo and e.ativa
$$;

create function exigir_admin() returns uuid
language plpgsql stable security definer set search_path = public as $$
declare v uuid;
begin
  select p.empresa_id into v from perfis p join empresas e on e.id = p.empresa_id
   where p.id = auth.uid() and p.ativo and e.ativa and p.papel = 'admin';
  if v is null then raise exception 'Acesso negado' using errcode = '42501'; end if;
  return v;
end $$;

create function exigir_cobrador() returns uuid
language plpgsql stable security definer set search_path = public as $$
declare v uuid;
begin
  select p.empresa_id into v from perfis p join empresas e on e.id = p.empresa_id
   where p.id = auth.uid() and p.ativo and e.ativa and p.papel = 'cobrador';
  if v is null then raise exception 'Acesso negado' using errcode = '42501'; end if;
  return v;
end $$;

create function auditar(p_acao text, p_detalhe text default '') returns void
language plpgsql security definer set search_path = public as $$
declare v_nome text;
begin
  select nome into v_nome from perfis where id = auth.uid();
  insert into auditoria (empresa_id, usuario_id, quem, acao, detalhe)
  values (empresa_atual(), auth.uid(), coalesce(v_nome, '?'), p_acao, left(coalesce(p_detalhe,''), 600));
end $$;

-- Recalcula o valor pago e se a ficha está quitada, sempre a partir dos pagamentos
create function recalcular_ficha(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_pago numeric;
begin
  select coalesce(sum(valor), 0) into v_pago from pagamentos where ficha_id = p_id;
  update fichas set valor_pago = v_pago, quitada = (v_pago >= valor_total) where id = p_id;
end $$;

-- --------------------------------------------------------------------------
-- Regras de acesso (leitura)
-- --------------------------------------------------------------------------
alter table empresas            enable row level security;
alter table perfis              enable row level security;
alter table convites            enable row level security;
alter table rotas_bairros       enable row level security;
alter table clientes            enable row level security;
alter table clientes_documentos enable row level security;
alter table fichas              enable row level security;
alter table pagamentos          enable row level security;
alter table fechamentos_dia     enable row level security;
alter table vales               enable row level security;
alter table prestacoes_contas   enable row level security;
alter table auditoria           enable row level security;

create policy empresa_propria on empresas for select to authenticated
  using (id = (select empresa_atual()));

create policy perfis_admin on perfis for select to authenticated
  using (empresa_id = (select empresa_atual()) and (select papel_atual()) = 'admin');
create policy perfis_proprio on perfis for select to authenticated
  using (id = auth.uid());

-- Administrador enxerga tudo da própria empresa
do $$
declare t text;
begin
  foreach t in array array['rotas_bairros','clientes','clientes_documentos','fichas','pagamentos',
                           'fechamentos_dia','vales','prestacoes_contas','auditoria'] loop
    execute format($f$create policy admin_le on %I for select to authenticated
      using (empresa_id = (select empresa_atual()) and (select papel_atual()) = 'admin')$f$, t);
  end loop;
end $$;

-- Cobrador enxerga só a própria rota
create policy cobrador_rotas on rotas_bairros for select to authenticated
  using (cobrador_id = auth.uid() and (select empresa_atual()) is not null);
create policy cobrador_fichas on fichas for select to authenticated
  using (cobrador_id = auth.uid() and (select papel_atual()) = 'cobrador');
create policy cobrador_clientes on clientes for select to authenticated
  using ((select papel_atual()) = 'cobrador'
         and id in (select cliente_id from fichas where cobrador_id = auth.uid()));
create policy cobrador_pagamentos on pagamentos for select to authenticated
  using (cobrador_id = auth.uid() and (select papel_atual()) = 'cobrador');
create policy cobrador_fechamentos on fechamentos_dia for select to authenticated
  using (cobrador_id = auth.uid() and (select papel_atual()) = 'cobrador');
create policy cobrador_vales on vales for select to authenticated
  using (cobrador_id = auth.uid() and (select papel_atual()) = 'cobrador');
create policy cobrador_prestacoes on prestacoes_contas for select to authenticated
  using (cobrador_id = auth.uid() and (select papel_atual()) = 'cobrador');

-- --------------------------------------------------------------------------
-- Primeiro acesso de uma empresa (com código de convite)
-- Antes: a pessoa cria o usuário no app (Auth); depois chama esta função.
-- Para gerar um convite:  insert into convites (codigo) values ('CODIGO-DO-CLIENTE');
-- --------------------------------------------------------------------------
create function ativar_convite(
  p_codigo text, p_empresa_nome text, p_chave text, p_nome_admin text, p_usuario text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c convites; v_email text; v_emp uuid;
begin
  if auth.uid() is null then raise exception 'Acesso negado' using errcode = '42501'; end if;
  if exists (select 1 from perfis where id = auth.uid()) then raise exception 'Este usuário já pertence a uma empresa'; end if;
  select * into c from convites where codigo = p_codigo for update;
  if not found or c.usado_em is not null then raise exception 'Código de convite inválido ou já usado'; end if;
  if coalesce(trim(p_empresa_nome),'') = '' or coalesce(trim(p_nome_admin),'') = '' then raise exception 'Informe o nome da empresa e o seu nome'; end if;
  if p_chave !~ '^[a-z0-9._-]{3,30}$' then raise exception 'A chave da empresa deve ter de 3 a 30 letras minúsculas, números, ponto, hífen ou sublinhado'; end if;
  if p_usuario !~ '^[a-z0-9._-]{3,30}$' then raise exception 'O usuário deve ter de 3 a 30 letras minúsculas, números, ponto, hífen ou sublinhado'; end if;
  if exists (select 1 from empresas where chave_acesso = p_chave) then raise exception 'Essa chave de empresa já está em uso. Escolha outra'; end if;
  select email into v_email from auth.users where id = auth.uid();
  if v_email is distinct from p_usuario || '+' || p_chave || '@' || email_dominio() then raise exception 'Usuário e chave não conferem com o cadastro de acesso'; end if;
  insert into empresas (nome, chave_acesso, cobradores_incluidos, valor_cobrador_extra)
  values (trim(p_empresa_nome), p_chave, c.cobradores_incluidos, c.valor_cobrador_extra) returning id into v_emp;
  insert into perfis (id, empresa_id, nome, usuario, papel) values (auth.uid(), v_emp, trim(p_nome_admin), p_usuario, 'admin');
  update convites set usado_em = now(), empresa_id = v_emp where codigo = p_codigo;
  perform auditar('Empresa criada', trim(p_empresa_nome));
  return jsonb_build_object('empresa_id', v_emp);
end $$;

-- --------------------------------------------------------------------------
-- Cobradores e rotas (administrador)
-- --------------------------------------------------------------------------
-- Depois que o app cria o usuário no Auth, esta função cria o perfil do cobrador
create function cadastrar_cobrador_perfil(
  p_id uuid, p_nome text, p_usuario text, p_periodicidade text default 'semanal'
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_e uuid := exigir_admin(); v_chave text; v_email text; v_ativos int; v_inc int;
begin
  if coalesce(trim(p_nome),'') = '' then raise exception 'Informe o nome do cobrador'; end if;
  if p_usuario !~ '^[a-z0-9._-]{3,30}$' then raise exception 'O usuário deve ter de 3 a 30 letras minúsculas, números, ponto, hífen ou sublinhado'; end if;
  if p_periodicidade not in ('semanal','mensal') then raise exception 'Periodicidade inválida'; end if;
  select chave_acesso, cobradores_incluidos into v_chave, v_inc from empresas where id = v_e;
  select email into v_email from auth.users where id = p_id;
  if v_email is distinct from p_usuario || '+' || v_chave || '@' || email_dominio() then raise exception 'O acesso criado não confere com o usuário informado'; end if;
  if exists (select 1 from perfis where empresa_id = v_e and usuario = p_usuario) then raise exception 'Já existe um cobrador com esse usuário'; end if;
  insert into perfis (id, empresa_id, nome, usuario, papel, periodicidade)
  values (p_id, v_e, trim(p_nome), p_usuario, 'cobrador', p_periodicidade);
  select count(*) into v_ativos from perfis where empresa_id = v_e and papel = 'cobrador' and ativo;
  perform auditar('Cobrador cadastrado', trim(p_nome) || case when v_ativos > v_inc then ' (cobrador extra)' else '' end);
  return jsonb_build_object('extra', v_ativos > v_inc, 'ativos', v_ativos, 'incluidos', v_inc);
end $$;

create function ativar_cobrador(p_id uuid, p_ativo boolean) returns void
language plpgsql security definer set search_path = public as $$
declare v_e uuid := exigir_admin(); v_nome text; v_n int;
begin
  select nome into v_nome from perfis where id = p_id and empresa_id = v_e and papel = 'cobrador';
  if v_nome is null then raise exception 'Cobrador não encontrado'; end if;
  if not p_ativo then
    select count(*) into v_n from fichas where cobrador_id = p_id and not quitada and not cancelada;
    if v_n > 0 then raise exception '% ainda tem % ficha(s) ativa(s). Transfira as fichas para outro cobrador antes de desativar', v_nome, v_n; end if;
    update perfis set ativo = false, desativado_em = now() where id = p_id;
    perform auditar('Cobrador desativado', v_nome);
  else
    update perfis set ativo = true, desativado_em = null where id = p_id;
    perform auditar('Cobrador reativado', v_nome);
  end if;
end $$;

create function definir_rota(p_cobrador uuid, p_bairro text) returns void
language plpgsql security definer set search_path = public as $$
declare v_e uuid := exigir_admin(); v_b text := trim(coalesce(p_bairro,'')); v_ant text; v_novo text;
begin
  if v_b = '' then raise exception 'Informe o bairro'; end if;
  select nome into v_novo from perfis where id = p_cobrador and empresa_id = v_e and papel = 'cobrador' and ativo;
  if v_novo is null then raise exception 'Cobrador não encontrado ou desativado'; end if;
  select p.nome into v_ant from rotas_bairros r join perfis p on p.id = r.cobrador_id
   where r.empresa_id = v_e and lower(r.bairro) = lower(v_b);
  delete from rotas_bairros where empresa_id = v_e and lower(bairro) = lower(v_b);
  insert into rotas_bairros (empresa_id, bairro, cobrador_id) values (v_e, v_b, p_cobrador);
  perform auditar('Rota definida', v_b || ' → ' || v_novo || coalesce(' (antes: ' || v_ant || ')', ''));
end $$;

create function remover_bairro(p_bairro text) returns void
language plpgsql security definer set search_path = public as $$
declare v_e uuid := exigir_admin();
begin
  delete from rotas_bairros where empresa_id = v_e and lower(bairro) = lower(trim(p_bairro));
  perform auditar('Bairro removido da rota', trim(p_bairro));
end $$;

create function registrar_vale(p_cobrador uuid, p_valor numeric) returns void
language plpgsql security definer set search_path = public as $$
declare v_e uuid := exigir_admin(); v_nome text;
begin
  if p_valor is null or p_valor <= 0 then raise exception 'Informe um valor maior que zero'; end if;
  select nome into v_nome from perfis where id = p_cobrador and empresa_id = v_e and papel = 'cobrador';
  if v_nome is null then raise exception 'Cobrador não encontrado'; end if;
  perform pg_advisory_xact_lock(hashtext('cobrador:' || p_cobrador::text));
  insert into vales (empresa_id, cobrador_id, data, valor, criado_em) values (v_e, p_cobrador, hoje_br(), p_valor, clock_timestamp());
  perform auditar('Vale registrado', v_nome || ' · ' || brl(p_valor));
end $$;

-- --------------------------------------------------------------------------
-- Lançar ficha (uma só, e em lote para a importação)
-- --------------------------------------------------------------------------
create function _lancar(
  v_e uuid, p_nome text, p_bairro text, p_endereco text, p_referencia text, p_telefone text,
  p_cpf text, p_mercadoria text, p_valor_total numeric, p_parcela numeric, p_data date,
  p_numero integer, p_cliente_id uuid, p_valor_pago numeric default 0
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_cob uuid; v_cli uuid; v_cpf text; v_dono uuid; v_n int; v_f uuid; v_cobnome text; v_pago numeric := coalesce(p_valor_pago, 0);
begin
  if coalesce(trim(p_nome),'') = '' or coalesce(trim(p_bairro),'') = '' then raise exception 'Informe o nome e o bairro do cliente'; end if;
  if p_valor_total is null or p_valor_total <= 0 or p_parcela is null or p_parcela <= 0 then raise exception 'O valor total e o valor da parcela devem ser maiores que zero'; end if;
  if v_pago < 0 or v_pago > p_valor_total then raise exception 'Valor pago inválido'; end if;
  select r.cobrador_id, p.nome into v_cob, v_cobnome from rotas_bairros r join perfis p on p.id = r.cobrador_id
   where r.empresa_id = v_e and lower(r.bairro) = lower(trim(p_bairro)) and p.ativo;
  if v_cob is null then raise exception 'Nenhum cobrador ativo atende o bairro "%"', p_bairro; end if;

  v_cpf := nullif(regexp_replace(coalesce(p_cpf,''), '\D', '', 'g'), '');
  if v_cpf is not null then
    if not cpf_valido(v_cpf) then raise exception 'CPF inválido'; end if;
    select cliente_id into v_dono from clientes_documentos where empresa_id = v_e and cpf = v_cpf;
  end if;

  if p_cliente_id is not null then
    select id into v_cli from clientes where id = p_cliente_id and empresa_id = v_e;
    if v_cli is null then raise exception 'Cliente não encontrado'; end if;
    update clientes set endereco   = coalesce(nullif(trim(p_endereco),''), endereco),
                        referencia = coalesce(p_referencia, referencia),
                        telefone   = coalesce(nullif(trim(p_telefone),''), telefone)
     where id = v_cli;
  else
    if v_dono is not null then raise exception 'Este CPF já está cadastrado para outro cliente'; end if;
    insert into clientes (empresa_id, nome, endereco, referencia, bairro, telefone)
    values (v_e, trim(p_nome), nullif(trim(p_endereco),''), nullif(trim(p_referencia),''), trim(p_bairro), nullif(trim(p_telefone),''))
    returning id into v_cli;
  end if;

  if v_cpf is not null then
    if v_dono is not null and v_dono <> v_cli then raise exception 'Este CPF já está cadastrado para outro cliente'; end if;
    if exists (select 1 from clientes_documentos where cliente_id = v_cli and cpf <> v_cpf) then
      raise exception 'Este cliente já tem outro CPF cadastrado';
    end if;
    insert into clientes_documentos (cliente_id, empresa_id, cpf) values (v_cli, v_e, v_cpf) on conflict (cliente_id) do nothing;
  end if;

  perform pg_advisory_xact_lock(hashtext(v_e::text));
  v_n := coalesce(p_numero, (select coalesce(max(numero), 0) + 1 from fichas where empresa_id = v_e));
  if v_n <= 0 then raise exception 'Número de ficha inválido'; end if;
  if exists (select 1 from fichas where empresa_id = v_e and numero = v_n) then
    raise exception 'O número % já está em uso', numero_ficha(v_n);
  end if;

  insert into fichas (empresa_id, numero, cliente_id, cobrador_id, mercadoria, valor_total, parcela, data_cobranca)
  values (v_e, v_n, v_cli, v_cob, coalesce(nullif(trim(p_mercadoria),''), 'Mercadoria'), p_valor_total, p_parcela, coalesce(p_data, hoje_br()))
  returning id into v_f;

  if v_pago > 0 then
    insert into pagamentos (empresa_id, ficha_id, cobrador_id, data, valor, forma, inicial)
    values (v_e, v_f, v_cob, hoje_br(), v_pago, null, true);
    perform recalcular_ficha(v_f);
  end if;
  return jsonb_build_object('id', v_f, 'numero', v_n, 'cliente_id', v_cli, 'cobrador_id', v_cob, 'cobrador', v_cobnome);
end $$;

create function lancar_ficha(
  p_nome text, p_bairro text, p_endereco text, p_referencia text, p_telefone text, p_cpf text,
  p_mercadoria text, p_valor_total numeric, p_parcela numeric, p_data date default null,
  p_numero integer default null, p_cliente_id uuid default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_e uuid := exigir_admin(); r jsonb;
begin
  r := _lancar(v_e, p_nome, p_bairro, p_endereco, p_referencia, p_telefone, p_cpf, p_mercadoria,
               p_valor_total, p_parcela, p_data, p_numero, p_cliente_id, 0);
  perform auditar('Ficha lançada', 'Ficha ' || numero_ficha((r->>'numero')::int) || ' · ' || trim(p_nome) || ' · '
                  || brl(p_valor_total) || ' · ' || (r->>'cobrador'));
  return r;
end $$;

-- Importação em lotes (ex.: 500 linhas por chamada). Cada linha é validada sozinha;
-- as que falham voltam em "erros" com o número da linha, sem impedir as demais.
create function importar_fichas(p_linhas jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_e uuid := exigir_admin(); j jsonb; v_ok int := 0; v_novos int := 0; v_erros jsonb := '[]'::jsonb;
        v_cli uuid; v_cpf text; v_antes int; v_depois int;
begin
  if jsonb_typeof(p_linhas) <> 'array' or jsonb_array_length(p_linhas) > 1000 then raise exception 'Envie até 1000 linhas por vez'; end if;
  for j in select * from jsonb_array_elements(p_linhas) loop
    begin
      v_cpf := nullif(regexp_replace(coalesce(j->>'cpf',''), '\D', '', 'g'), '');
      v_cli := null;
      if v_cpf is not null then
        select cliente_id into v_cli from clientes_documentos where empresa_id = v_e and cpf = v_cpf;
      end if;
      if v_cli is null then
        select id into v_cli from clientes where empresa_id = v_e
           and lower(nome) = lower(trim(j->>'cliente')) and lower(coalesce(bairro,'')) = lower(trim(coalesce(j->>'bairro','')))
         limit 1;
      end if;
      select count(*) into v_antes from clientes where empresa_id = v_e;
      perform _lancar(v_e, j->>'cliente', j->>'bairro', j->>'endereco', j->>'referencia', j->>'telefone', j->>'cpf',
                      j->>'mercadoria', (j->>'valor_total')::numeric, (j->>'parcela')::numeric,
                      nullif(j->>'data','')::date, nullif(j->>'numero','')::int, v_cli,
                      coalesce(nullif(j->>'valor_pago','')::numeric, 0));
      select count(*) into v_depois from clientes where empresa_id = v_e;
      v_novos := v_novos + (v_depois - v_antes);
      v_ok := v_ok + 1;
    exception when others then
      v_erros := v_erros || jsonb_build_object('linha', j->>'linha', 'msg', sqlerrm);
    end;
  end loop;
  perform auditar('Importação de fichas', v_ok || ' ficha(s) importada(s), ' || v_novos || ' cliente(s) novo(s), ' || jsonb_array_length(v_erros) || ' linha(s) com erro');
  return jsonb_build_object('importadas', v_ok, 'clientes_novos', v_novos, 'erros', v_erros);
end $$;

-- --------------------------------------------------------------------------
-- Editar, cancelar, transferir (administrador)
-- --------------------------------------------------------------------------
create function editar_ficha(
  p_ficha uuid, p_endereco text, p_referencia text, p_telefone text, p_cpf text,
  p_mercadoria text, p_mercadoria_nova text, p_valor_add numeric, p_parcela numeric,
  p_cobrador uuid, p_data date default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_e uuid := exigir_admin(); f fichas; c clientes; v_cpf text; v_dono uuid; v_cpf_atual text;
        v_merc text; v_total numeric; v_parc numeric; v_cob uuid; v_mud text[] := '{}'; v_reabriu boolean := false;
        v_nome_cob_ant text; v_nome_cob text; v_era_quitada boolean;
begin
  select * into f from fichas where id = p_ficha and empresa_id = v_e for update;
  if not found then raise exception 'Ficha não encontrada'; end if;
  v_era_quitada := f.quitada;
  if f.cancelada then raise exception 'Reabra a ficha antes de editá-la'; end if;
  select * into c from clientes where id = f.cliente_id;

  v_cpf := nullif(regexp_replace(coalesce(p_cpf,''), '\D', '', 'g'), '');
  select cpf into v_cpf_atual from clientes_documentos where cliente_id = c.id;
  if v_cpf is distinct from v_cpf_atual then
    if v_cpf is not null then
      if not cpf_valido(v_cpf) then raise exception 'CPF inválido'; end if;
      select cliente_id into v_dono from clientes_documentos where empresa_id = v_e and cpf = v_cpf and cliente_id <> c.id;
      if v_dono is not null then raise exception 'Este CPF já está cadastrado para %', (select nome from clientes where id = v_dono); end if;
    end if;
    delete from clientes_documentos where cliente_id = c.id;
    if v_cpf is not null then insert into clientes_documentos (cliente_id, empresa_id, cpf) values (c.id, v_e, v_cpf); end if;
    v_mud := array_append(v_mud, 'CPF alterado');
  end if;

  if nullif(trim(p_endereco),'') is not null and trim(p_endereco) is distinct from c.endereco then
    v_mud := v_mud || ('Endereço: ' || coalesce(c.endereco,'—') || ' → ' || trim(p_endereco)); end if;
  if coalesce(trim(p_referencia),'') is distinct from coalesce(c.referencia,'') then
    v_mud := v_mud || ('Referência: ' || coalesce(c.referencia,'—') || ' → ' || coalesce(nullif(trim(p_referencia),''),'—')); end if;
  if coalesce(trim(p_telefone),'') is distinct from coalesce(c.telefone,'') then
    v_mud := v_mud || ('Telefone: ' || coalesce(c.telefone,'—') || ' → ' || coalesce(nullif(trim(p_telefone),''),'—')); end if;
  update clientes set endereco = coalesce(nullif(trim(p_endereco),''), endereco),
                      referencia = nullif(trim(coalesce(p_referencia,'')),''),
                      telefone = nullif(trim(coalesce(p_telefone,'')),'')
   where id = c.id;

  v_merc := coalesce(nullif(trim(p_mercadoria),''), f.mercadoria);
  if nullif(trim(p_mercadoria_nova),'') is not null then v_merc := v_merc || ' + ' || trim(p_mercadoria_nova); end if;
  if v_merc is distinct from f.mercadoria then v_mud := v_mud || ('Mercadoria: ' || f.mercadoria || ' → ' || v_merc); end if;

  v_total := f.valor_total + coalesce(p_valor_add, 0);
  if coalesce(p_valor_add, 0) < 0 then raise exception 'O valor a somar não pode ser negativo'; end if;
  if v_total is distinct from f.valor_total then v_mud := v_mud || ('Valor total: ' || brl(f.valor_total) || ' → ' || brl(v_total)); end if;

  v_parc := coalesce(p_parcela, f.parcela);
  if v_parc <= 0 then raise exception 'A parcela deve ser maior que zero'; end if;
  if v_parc is distinct from f.parcela then v_mud := v_mud || ('Parcela: ' || brl(f.parcela) || ' → ' || brl(v_parc)); end if;

  v_cob := coalesce(p_cobrador, f.cobrador_id);
  if v_cob <> f.cobrador_id then
    select nome into v_nome_cob from perfis where id = v_cob and empresa_id = v_e and papel = 'cobrador' and ativo;
    if v_nome_cob is null then raise exception 'Cobrador não encontrado ou desativado'; end if;
    select nome into v_nome_cob_ant from perfis where id = f.cobrador_id;
    v_mud := v_mud || ('Cobrador: ' || coalesce(v_nome_cob_ant,'—') || ' → ' || v_nome_cob);
  end if;

  update fichas set mercadoria = v_merc, valor_total = v_total, parcela = v_parc, cobrador_id = v_cob where id = f.id;
  perform recalcular_ficha(f.id);
  select * into f from fichas where id = p_ficha;

  -- ficha que estava quitada e voltou a ter saldo: volta a ser cobrada
  if v_era_quitada and not f.quitada then
    update fichas set status = 'pendente', data_cobranca = coalesce(p_data, hoje_br()), proxima_data = null, nao_visitada = false where id = f.id;
    v_mud := v_mud || ('Ficha reaberta para ' || to_char(coalesce(p_data, hoje_br()), 'DD/MM/YYYY'));
    v_reabriu := true;
  elsif p_data is not null and not f.quitada then
    if f.status = 'paga' then
      update fichas set proxima_data = p_data where id = f.id;
    else
      update fichas set status = 'pendente', data_cobranca = p_data, proxima_data = null, nao_visitada = false where id = f.id;
    end if;
    v_mud := v_mud || ('Próxima cobrança: ' || to_char(p_data, 'DD/MM/YYYY'));
  end if;

  perform auditar('Ficha editada', 'Ficha ' || numero_ficha(f.numero) || ' · ' || c.nome || ' · '
                  || case when cardinality(v_mud) = 0 then 'sem mudança de dados' else array_to_string(v_mud, '; ') end);
  return jsonb_build_object('reabriu', v_reabriu);
end $$;

create function cancelar_ficha(p_ficha uuid, p_motivo text) returns void
language plpgsql security definer set search_path = public as $$
declare v_e uuid := exigir_admin(); f fichas; v_nome text;
begin
  if coalesce(trim(p_motivo),'') = '' then raise exception 'Informe o motivo (ex.: mercadoria devolvida)'; end if;
  select * into f from fichas where id = p_ficha and empresa_id = v_e for update;
  if not found then raise exception 'Ficha não encontrada'; end if;
  if f.cancelada then raise exception 'Esta ficha já está cancelada'; end if;
  if exists (select 1 from pagamentos where ficha_id = f.id and data = hoje_br() and not inicial) then
    raise exception 'Esta ficha teve pagamento hoje. Corrija ou exclua o pagamento antes de cancelar';
  end if;
  update fichas set cancelada = true, motivo_cancelamento = trim(p_motivo), proxima_data = null where id = f.id;
  select nome into v_nome from clientes where id = f.cliente_id;
  perform auditar('Ficha cancelada', 'Ficha ' || numero_ficha(f.numero) || ' · ' || v_nome || ' · pago ' || brl(f.valor_pago)
                  || ' de ' || brl(f.valor_total) || ' · motivo: ' || trim(p_motivo));
end $$;

create function reabrir_ficha(p_ficha uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_e uuid := exigir_admin(); f fichas; v_nome text;
begin
  select * into f from fichas where id = p_ficha and empresa_id = v_e for update;
  if not found or not f.cancelada then raise exception 'Ficha não encontrada ou não está cancelada'; end if;
  update fichas set cancelada = false, motivo_cancelamento = null where id = f.id;
  if not f.quitada then
    update fichas set status = 'pendente', data_cobranca = hoje_br(), proxima_data = null, nao_visitada = false where id = f.id;
  end if;
  select nome into v_nome from clientes where id = f.cliente_id;
  perform auditar('Ficha reaberta', 'Ficha ' || numero_ficha(f.numero) || ' · ' || v_nome);
end $$;

create function trazer_para_hoje(p_ficha uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_e uuid := exigir_admin(); f fichas; v_nome text;
begin
  select * into f from fichas where id = p_ficha and empresa_id = v_e for update;
  if not found or f.quitada or f.cancelada then raise exception 'Ficha não encontrada ou encerrada'; end if;
  update fichas set status = 'pendente', data_cobranca = hoje_br(), proxima_data = null, nao_visitada = false where id = f.id;
  select nome into v_nome from clientes where id = f.cliente_id;
  perform auditar('Ficha trazida para hoje', 'Ficha ' || numero_ficha(f.numero) || ' · ' || v_nome);
end $$;

create function transferir_fichas(p_de uuid, p_para uuid) returns integer
language plpgsql security definer set search_path = public as $$
declare v_e uuid := exigir_admin(); v_n int; v_de text; v_para text;
begin
  if p_de = p_para then raise exception 'Escolha dois cobradores diferentes'; end if;
  select nome into v_de from perfis where id = p_de and empresa_id = v_e and papel = 'cobrador';
  select nome into v_para from perfis where id = p_para and empresa_id = v_e and papel = 'cobrador' and ativo;
  if v_de is null or v_para is null then raise exception 'Cobrador não encontrado ou desativado'; end if;
  update fichas f set cobrador_id = p_para
   where f.empresa_id = v_e and f.cobrador_id = p_de and not f.quitada and not f.cancelada
     and not exists (select 1 from pagamentos pg where pg.ficha_id = f.id and pg.data = hoje_br() and not pg.inicial);
  get diagnostics v_n = row_count;
  perform auditar('Fichas transferidas', v_n || ' ficha(s) de ' || v_de || ' para ' || v_para);
  return v_n;
end $$;

-- --------------------------------------------------------------------------
-- Corrigir ou excluir um pagamento (administrador)
-- --------------------------------------------------------------------------
create function corrigir_pagamento(p_pagamento uuid, p_valor numeric, p_forma text, p_motivo text) returns void
language plpgsql security definer set search_path = public as $$
declare v_e uuid := exigir_admin(); p pagamentos; f fichas; v_outros numeric; v_nome text; v_antes text;
begin
  if coalesce(trim(p_motivo),'') = '' then raise exception 'Informe o motivo da correção'; end if;
  if p_valor is null or p_valor <= 0 then raise exception 'Informe um valor maior que zero'; end if;
  if p_forma not in ('dinheiro','pix') then raise exception 'Forma de pagamento inválida'; end if;
  select * into p from pagamentos where id = p_pagamento and empresa_id = v_e for update;
  if not found or p.inicial then raise exception 'Pagamento não encontrado ou anterior ao sistema'; end if;
  select * into f from fichas where id = p.ficha_id for update;
  select coalesce(sum(valor),0) into v_outros from pagamentos where ficha_id = f.id and id <> p.id;
  if v_outros + p_valor > f.valor_total + 0.001 then raise exception 'O valor pago passaria do total da ficha (%)', brl(f.valor_total); end if;
  v_antes := brl(p.valor) || ' ' || p.forma;
  update pagamentos set valor = p_valor, forma = p_forma, corrigido = true where id = p.id;
  perform recalcular_ficha(f.id);
  select nome into v_nome from clientes where id = f.cliente_id;
  perform auditar('Pagamento corrigido', 'Ficha ' || numero_ficha(f.numero) || ' · ' || v_nome || ' · de ' || v_antes
                  || ' para ' || brl(p_valor) || ' ' || p_forma || ' · motivo: ' || trim(p_motivo));
end $$;

create function excluir_pagamento(p_pagamento uuid, p_motivo text) returns void
language plpgsql security definer set search_path = public as $$
declare v_e uuid := exigir_admin(); p pagamentos; f fichas; v_nome text;
begin
  if coalesce(trim(p_motivo),'') = '' then raise exception 'Informe o motivo da exclusão'; end if;
  select * into p from pagamentos where id = p_pagamento and empresa_id = v_e for update;
  if not found or p.inicial then raise exception 'Pagamento não encontrado ou anterior ao sistema'; end if;
  select * into f from fichas where id = p.ficha_id for update;
  delete from pagamentos where id = p.id;
  perform recalcular_ficha(f.id);
  -- se era o pagamento da visita atual, a ficha volta a ficar pendente
  if f.status = 'paga' and f.data_cobranca = p.data
     and not exists (select 1 from pagamentos where ficha_id = f.id and data = p.data and not inicial) then
    update fichas set status = 'pendente', proxima_data = null where id = f.id;
  end if;
  select nome into v_nome from clientes where id = f.cliente_id;
  perform auditar('Pagamento excluído', 'Ficha ' || numero_ficha(f.numero) || ' · ' || v_nome || ' · ' || brl(p.valor) || ' '
                  || coalesce(p.forma,'') || ' de ' || to_char(p.data,'DD/MM/YYYY') || ' · motivo: ' || trim(p_motivo));
end $$;

-- --------------------------------------------------------------------------
-- Rotina do cobrador (baixa, remarcação, próxima data, enviar resultado do dia)
-- p_data permite que baixas feitas sem internet entrem no dia certo quando o app reenviar
-- --------------------------------------------------------------------------
create function _dia_fechado(v_e uuid, v_cob uuid, v_data date) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from fechamentos_dia where empresa_id = v_e and cobrador_id = v_cob and data = v_data and confirmado_em is not null)
$$;

create function registrar_baixa(
  p_ficha uuid, p_valor numeric, p_forma text, p_proxima date default null,
  p_id_cliente_app uuid default null, p_data date default null
) returns void
language plpgsql security definer set search_path = public as $$
declare v_e uuid := exigir_cobrador(); v_data date := coalesce(p_data, hoje_br()); f fichas;
begin
  if v_data > hoje_br() or v_data < hoje_br() - 3 then raise exception 'Data da baixa inválida'; end if;
  -- reenvio do mesmo registro (modo sem internet): não faz nada
  if p_id_cliente_app is not null and exists (select 1 from pagamentos where id_cliente_app = p_id_cliente_app) then return; end if;
  if p_forma is null or p_forma not in ('dinheiro','pix') then raise exception 'Forma de pagamento inválida'; end if;
  if p_valor is null or p_valor <= 0 then raise exception 'Informe um valor maior que zero'; end if;
  select * into f from fichas where id = p_ficha and cobrador_id = auth.uid() and empresa_id = v_e for update;
  if not found then raise exception 'Ficha não encontrada para este cobrador'; end if;
  if f.cancelada or f.quitada then raise exception 'Esta ficha já está encerrada'; end if;
  if _dia_fechado(v_e, auth.uid(), v_data) then raise exception 'DIA_FECHADO: o administrador já conferiu esse dia'; end if;
  if f.status <> 'pendente' or f.data_cobranca <> v_data then raise exception 'Esta ficha não está pendente para cobrança nesse dia'; end if;
  if p_valor > f.valor_total - f.valor_pago + 0.001 then raise exception 'O valor é maior que o restante da ficha (%)', brl(f.valor_total - f.valor_pago); end if;
  if p_valor < f.valor_total - f.valor_pago - 0.001 and (p_proxima is null or p_proxima <= v_data) then
    raise exception 'A ficha ainda não será quitada: escolha a data da próxima cobrança (depois de %)', to_char(v_data,'DD/MM/YYYY');
  end if;
  -- serializa com a prestação de contas do cobrador: todo pagamento cai em exatamente um período
  perform pg_advisory_xact_lock(hashtext('cobrador:' || auth.uid()::text));
  insert into pagamentos (empresa_id, ficha_id, cobrador_id, data, valor, forma, id_cliente_app, criado_em)
  values (v_e, f.id, auth.uid(), v_data, p_valor, p_forma, p_id_cliente_app, clock_timestamp());
  perform recalcular_ficha(f.id);
  update fichas set status = 'paga', nao_visitada = false,
         proxima_data = case when quitada then null else p_proxima end
   where id = f.id;
end $$;

create function remarcar_ficha(p_ficha uuid, p_nova date, p_data date default null) returns void
language plpgsql security definer set search_path = public as $$
declare v_e uuid := exigir_cobrador(); v_data date := coalesce(p_data, hoje_br()); f fichas;
begin
  if v_data > hoje_br() or v_data < hoje_br() - 3 then raise exception 'Data inválida'; end if;
  select * into f from fichas where id = p_ficha and cobrador_id = auth.uid() and empresa_id = v_e for update;
  if not found then raise exception 'Ficha não encontrada para este cobrador'; end if;
  if f.status = 'remarcada' and f.proxima_data = p_nova and f.data_cobranca = v_data then return; end if;  -- reenvio
  if f.cancelada or f.quitada then raise exception 'Esta ficha já está encerrada'; end if;
  if _dia_fechado(v_e, auth.uid(), v_data) then raise exception 'DIA_FECHADO: o administrador já conferiu esse dia'; end if;
  if f.status <> 'pendente' or f.data_cobranca <> v_data then raise exception 'Esta ficha não está pendente para cobrança nesse dia'; end if;
  if p_nova is null or p_nova <= v_data then raise exception 'A nova data precisa ser depois de %', to_char(v_data,'DD/MM/YYYY'); end if;
  update fichas set status = 'remarcada', proxima_data = p_nova, nao_visitada = false where id = f.id;
end $$;

create function alterar_proxima_data(p_ficha uuid, p_data date) returns void
language plpgsql security definer set search_path = public as $$
declare v_e uuid := exigir_cobrador(); f fichas;
begin
  select * into f from fichas where id = p_ficha and cobrador_id = auth.uid() and empresa_id = v_e for update;
  if not found then raise exception 'Ficha não encontrada para este cobrador'; end if;
  if f.quitada or f.cancelada or f.status not in ('paga','remarcada') then raise exception 'Esta ficha não aceita nova data agora'; end if;
  if _dia_fechado(v_e, auth.uid(), f.data_cobranca) then raise exception 'DIA_FECHADO: o administrador já conferiu esse dia'; end if;
  if p_data is null or p_data <= f.data_cobranca then raise exception 'A data precisa ser depois de %', to_char(f.data_cobranca,'DD/MM/YYYY'); end if;
  update fichas set proxima_data = p_data where id = f.id;
end $$;

create function enviar_resultado_dia(p_data date default null) returns integer
language plpgsql security definer set search_path = public as $$
declare v_e uuid := exigir_cobrador(); v_data date := coalesce(p_data, hoje_br()); v_n int;
begin
  if v_data > hoje_br() or v_data < hoje_br() - 3 then raise exception 'Data inválida'; end if;
  if _dia_fechado(v_e, auth.uid(), v_data) then raise exception 'DIA_FECHADO: o administrador já conferiu esse dia'; end if;
  -- o que não foi visitado fica marcado para o dia seguinte
  update fichas set status = 'remarcada', nao_visitada = true, proxima_data = v_data + 1
   where empresa_id = v_e and cobrador_id = auth.uid() and data_cobranca = v_data
     and status = 'pendente' and not quitada and not cancelada;
  get diagnostics v_n = row_count;
  insert into fechamentos_dia (empresa_id, cobrador_id, data, enviado_em) values (v_e, auth.uid(), v_data, now())
  on conflict (empresa_id, cobrador_id, data) do update set enviado_em = coalesce(fechamentos_dia.enviado_em, now());
  perform auditar('Resultado do dia enviado', to_char(v_data,'DD/MM/YYYY') || ' · ' || v_n || ' ficha(s) não visitada(s)');
  return v_n;
end $$;

-- --------------------------------------------------------------------------
-- Conferência do dia (administrador): confere o dinheiro, lança o vale da diferença
-- e libera as fichas do dia seguinte
-- --------------------------------------------------------------------------
create function conferir_dia(p_cobrador uuid, p_data date, p_entregue numeric) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_e uuid := exigir_admin(); v_data date := coalesce(p_data, hoje_br()); fe fechamentos_dia;
        v_esp numeric; v_pix numeric; v_dif numeric; v_nome text; v_n int;
begin
  select nome into v_nome from perfis where id = p_cobrador and empresa_id = v_e and papel = 'cobrador';
  if v_nome is null then raise exception 'Cobrador não encontrado'; end if;
  if p_entregue is null or p_entregue < 0 then raise exception 'Informe o valor entregue em dinheiro'; end if;
  select * into fe from fechamentos_dia where empresa_id = v_e and cobrador_id = p_cobrador and data = v_data for update;
  if not found or fe.enviado_em is null then raise exception 'O cobrador ainda não enviou o resultado do dia'; end if;
  if fe.confirmado_em is not null then raise exception 'Este dia já foi conferido'; end if;
  select coalesce(sum(valor) filter (where forma = 'dinheiro'), 0), coalesce(sum(valor) filter (where forma = 'pix'), 0)
    into v_esp, v_pix from pagamentos where cobrador_id = p_cobrador and data = v_data and not inicial;
  v_dif := greatest(0, v_esp - p_entregue);
  update fechamentos_dia set pix_esperado = v_pix, especie_esperada = v_esp, especie_entregue = p_entregue, diferenca = v_dif,
         confirmado_por = auth.uid(), confirmado_em = now() where id = fe.id;
  if v_dif > 0 then
    perform pg_advisory_xact_lock(hashtext('cobrador:' || p_cobrador::text));
    insert into vales (empresa_id, cobrador_id, data, valor, origem, fechamento_id, criado_em)
    values (v_e, p_cobrador, v_data, v_dif, 'diferenca_fechamento', fe.id, clock_timestamp());
  end if;
  -- libera as fichas na nova data
  update fichas set data_cobranca = coalesce(proxima_data, v_data + 1), status = 'pendente', nao_visitada = false, proxima_data = null
   where empresa_id = v_e and cobrador_id = p_cobrador and data_cobranca = v_data
     and status in ('paga','remarcada') and not quitada and not cancelada;
  get diagnostics v_n = row_count;
  perform auditar('Dia conferido', v_nome || ' · ' || to_char(v_data,'DD/MM/YYYY') || ' · espécie esperada ' || brl(v_esp)
                  || ' · entregue ' || brl(p_entregue) || case when v_dif > 0 then ' · diferença de ' || brl(v_dif) || ' lançada como vale' else '' end);
  return jsonb_build_object('especie_esperada', v_esp, 'pix_esperado', v_pix, 'diferenca', v_dif, 'fichas_liberadas', v_n);
end $$;

-- --------------------------------------------------------------------------
-- Prestação de contas (administrador). Tudo é calculado aqui, nunca pelo navegador.
-- --------------------------------------------------------------------------
create function calcular_prestacao(p_cobrador uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_e uuid := exigir_admin(); u prestacoes_contas; v_tem boolean; v_pct numeric; v_total numeric; v_com numeric;
        v_vales numeric; v_ant numeric := 0; v_qtd int;
begin
  select comissao_pct into v_pct from perfis where id = p_cobrador and empresa_id = v_e and papel = 'cobrador';
  if v_pct is null then raise exception 'Cobrador não encontrado'; end if;
  select * into u from prestacoes_contas where empresa_id = v_e and cobrador_id = p_cobrador order by criada_em desc limit 1;
  v_tem := found;
  select coalesce(sum(valor),0), count(distinct ficha_id) into v_total, v_qtd from pagamentos
   where empresa_id = v_e and cobrador_id = p_cobrador and not inicial and (not v_tem or criado_em > u.criada_em);
  select coalesce(sum(valor),0) into v_vales from vales
   where empresa_id = v_e and cobrador_id = p_cobrador and (not v_tem or criado_em > u.criada_em);
  if v_tem and u.saldo_final < 0 then v_ant := u.saldo_final; end if;
  v_com := round(v_total * v_pct / 100, 2);
  return jsonb_build_object('desde', case when v_tem then u.periodo_fim end, 'total_cobrado', v_total, 'comissao', v_com,
         'vales', v_vales, 'saldo_anterior', v_ant, 'saldo_final', v_com - v_vales + v_ant, 'qtd_fichas', v_qtd);
end $$;

create function prestar_contas(p_cobrador uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_e uuid := exigir_admin(); r jsonb; v_nome text;
begin
  perform pg_advisory_xact_lock(hashtext('cobrador:' || p_cobrador::text));
  r := calcular_prestacao(p_cobrador);
  select nome into v_nome from perfis where id = p_cobrador;
  insert into prestacoes_contas (empresa_id, cobrador_id, periodo_ini, periodo_fim, total_cobrado, comissao, vales, saldo_anterior, saldo_final, criada_em)
  values (v_e, p_cobrador, (r->>'desde')::date + 1, hoje_br(), (r->>'total_cobrado')::numeric, (r->>'comissao')::numeric,
          (r->>'vales')::numeric, (r->>'saldo_anterior')::numeric, (r->>'saldo_final')::numeric, clock_timestamp());
  perform auditar('Prestação de contas', v_nome || ' · cobrado ' || brl((r->>'total_cobrado')::numeric) || ' · saldo final ' || brl((r->>'saldo_final')::numeric));
  return r;
end $$;

-- Eventos que só informam (recibo e lembrete enviados por WhatsApp)
create function registrar_evento(p_acao text, p_detalhe text default '') returns void
language plpgsql security definer set search_path = public as $$
begin
  if empresa_atual() is null then raise exception 'Acesso negado' using errcode = '42501'; end if;
  if p_acao not in ('Recibo enviado','Lembrete enviado') then raise exception 'Ação não permitida'; end if;
  perform auditar(p_acao, p_detalhe);
end $$;

-- --------------------------------------------------------------------------
-- Permissões: o app só lê as tabelas e chama as funções abaixo
-- --------------------------------------------------------------------------
revoke all on all tables in schema public from anon, authenticated;
grant select on all tables in schema public to authenticated;
revoke select on convites from authenticated;

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function
  empresa_atual(), papel_atual(), hoje_br(),
  ativar_convite(text,text,text,text,text),
  cadastrar_cobrador_perfil(uuid,text,text,text), ativar_cobrador(uuid,boolean),
  definir_rota(uuid,text), remover_bairro(text), registrar_vale(uuid,numeric),
  lancar_ficha(text,text,text,text,text,text,text,numeric,numeric,date,integer,uuid),
  importar_fichas(jsonb),
  editar_ficha(uuid,text,text,text,text,text,text,numeric,numeric,uuid,date),
  cancelar_ficha(uuid,text), reabrir_ficha(uuid), trazer_para_hoje(uuid), transferir_fichas(uuid,uuid),
  corrigir_pagamento(uuid,numeric,text,text), excluir_pagamento(uuid,text),
  registrar_baixa(uuid,numeric,text,date,uuid,date), remarcar_ficha(uuid,date,date),
  alterar_proxima_data(uuid,date), enviar_resultado_dia(date),
  conferir_dia(uuid,date,numeric), calcular_prestacao(uuid), prestar_contas(uuid),
  registrar_evento(text,text)
to authenticated;
