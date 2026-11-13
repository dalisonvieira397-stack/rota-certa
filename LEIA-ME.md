# Rota Certa

Sistema de cobrança porta a porta (fichas/cadernetas), com cobrador e administrador, rotas por bairro,
conferência diária de Pix e dinheiro, vales e prestação de contas.

## Arquivos
- `index.html` — o aplicativo inteiro (fica na raiz do repositório)
- `manifest.webmanifest`, `sw.js`, `icon-192.png`, `icon-512.png` — permitem instalar no celular e abrir sem internet
- `banco/rota-certa-banco.sql` — cria o banco no Supabase (rodar uma vez, em projeto vazio)

## Passo a passo
1. **Supabase**: crie um projeto novo. Em *SQL Editor*, cole todo o conteúdo de `banco/rota-certa-banco.sql` e clique em *Run*.
2. **Supabase → Authentication → Providers → Email**: deixe o Email ligado e **desligue "Confirm email"**.
3. **Supabase → Project Settings → API**: copie a *Project URL* e a chave *anon public*.
4. No `index.html`, nas primeiras linhas do bloco `CONFIGURAÇÃO`, preencha `SUPABASE_URL` e `SUPABASE_ANON_KEY`. Salve (commit).
5. **Vercel**: importe o repositório (Framework: *Other*, sem comando de build). Cada commit publica sozinho.
6. **Primeiro cliente**: no *SQL Editor* rode (troque o código):
   `insert into convites (codigo, cobradores_incluidos, valor_cobrador_extra) values ('CLIENTE-001', 2, null);`
   Entregue o código ao cliente. Na tela de login ele toca em *Primeiro acesso da empresa*, informa o código, escolhe a chave da empresa e cria o administrador.
7. O administrador cadastra os cobradores (com senha), define os bairros de cada rota e lança as fichas.
   Os cobradores entram com a **chave da empresa + usuário + senha**.

## Cobradores extras
Para ver quantos cobradores cada empresa usa além das vagas incluídas, rode no SQL Editor:
`select * from empresas_cobradores_extras;`

## Observações
- `DOMINIO_EMAIL` (no `index.html`) e a função `email_dominio()` (no SQL) precisam ter o mesmo valor. Se o cadastro der erro de "e-mail inválido", troque os dois por um domínio seu.
- Troca de senha de cobrador feita pelo administrador ainda não existe: cada um altera a própria em *Minha senha*.
- A conta é suspensa mudando `ativa` para `false` na tabela `empresas`.
