-- ============================================================
-- Função: public.cs_resumo_atendimento  (v8)
-- Mudanças v8:
--   • Nova categoria 'automatico' (🤖): auto-resposta de bot do aluno (corretor/lead-gen) —
--     aluno NÃO engajou pessoalmente. Tirada de dentro de 'outros'. Entra antes de 'outros'
--     e NÃO aparece em frases.
--   • Afinado p/ recuperar genuínos: "curso é excelente"→elogios, "não fui avisado/como funciona
--     o desafio"→dificuldade, "grávida/cirurgia/internado"→afetivo, "maratonar"→compromisso.
-- Mudanças v7:
--   • Guarda de NEGAÇÃO (lookbehind) em risco/dificuldade/prova/elogios/acesso/
--     engajamento/compromisso. Ex.: "não tenho dúvida" não cai mais em dificuldade,
--     "nunca arrematei" não cai em prova, "não gostei" não cai em elogios.
--   • Postgres ARE suporta lookbehind de comprimento variável: (?<!n[ãa]o (é |foi |...)?|nunca |jamais )
-- Mudanças v6:
--   • PROVA social = resultado REAL (arremate/leilão/primeiro resultado). Removido 'venda'/'resultado'
--     soltos: alunos corretores têm auto-resposta com "venda/imóveis" e o desafio se chama
--     "Aceleração dos Resultados" → causava falso positivo em massa.
--   • ELOGIOS ampliado e promovido na hierarquia (antes era engolido por engajamento/acesso).
--   • Hierarquia: risco → tecnico → dificuldade → prova → elogios → acesso →
--     engajamento_curso → compromisso → comunidade → afetivo → outros
-- Mudanças v5:
--   • Nova categoria 'acesso' (acesso liberado/funcionando — antes caía em 'prova')
--   • Nova categoria 'elogios' (satisfação/elogio ao curso)
--   • 'prova' agora é só RESULTADO real (arremate/venda/lucro), não acesso
--   • Nuvem de palavras por período (campo 'nuvem' em cada bucket: top 40 palavras)
--   • Hierarquia: risco → tecnico → dificuldade → acesso → prova →
--     engajamento_curso → elogios → compromisso → comunidade → afetivo → outros
-- v4:
--   • Categorias 'engajamento_curso' e 'comunidade'
-- v3:
--   • RESPOSTAS = conversas únicas com msg do aluno no período
--   • Parâmetros p_custom_start, p_custom_end (opcional, retorna bucket 'custom')
-- ============================================================

-- Remove versões antigas
DROP FUNCTION IF EXISTS public.cs_resumo_atendimento(uuid, date, int);
DROP FUNCTION IF EXISTS public.cs_resumo_atendimento(uuid, date, int, date, date);

CREATE OR REPLACE FUNCTION public.cs_resumo_atendimento(
  p_cliente_id uuid,
  p_inicio_projeto date DEFAULT '2026-04-27'::date,
  p_meta_mensal int DEFAULT 800,
  p_custom_start date DEFAULT NULL,
  p_custom_end date DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $func$
WITH
cfg AS (
  SELECT
    now() AS t_now,
    now() - interval '7 days'  AS d7_start,
    now() - interval '14 days' AS d8_start,
    now() - interval '7 days'  AS d8_end,
    (date_trunc('month', now() AT TIME ZONE 'America/Sao_Paulo') AT TIME ZONE 'America/Sao_Paulo') - interval '1 month' AS mf_start,
    (date_trunc('month', now() AT TIME ZONE 'America/Sao_Paulo') AT TIME ZONE 'America/Sao_Paulo') AS mf_end,
    (date_trunc('month', now() AT TIME ZONE 'America/Sao_Paulo') AT TIME ZONE 'America/Sao_Paulo') AS m_atual_start,
    GREATEST(1, ((now() AT TIME ZONE 'America/Sao_Paulo')::date - p_inicio_projeto)::int) AS dias_corridos,
    ((now() AT TIME ZONE 'America/Sao_Paulo')::date - (date_trunc('month', now() AT TIME ZONE 'America/Sao_Paulo')::date) + 1)::int AS dias_mes_atual,
    CASE WHEN p_custom_start IS NOT NULL THEN p_custom_start AT TIME ZONE 'America/Sao_Paulo' END AS cust_start,
    CASE WHEN p_custom_end IS NOT NULL THEN (p_custom_end + interval '1 day') AT TIME ZONE 'America/Sao_Paulo' END AS cust_end
),
contatos_excl AS (
  SELECT id, contact_id FROM conversas_chatwoot
  WHERE cliente_id = p_cliente_id
    AND (COALESCE(contact_name,'') ILIKE '%tiago%'
      OR COALESCE(contact_name,'') ILIKE '%teste%')
),
msgs AS (
  SELECT m.conversa_id, m.message_type, m.private, m.message_created_at, m.content, c.contact_id
  FROM mensagens_chatwoot m
  JOIN conversas_chatwoot c ON c.id = m.conversa_id
  WHERE m.cliente_id = p_cliente_id
    AND m.conversa_id NOT IN (SELECT id FROM contatos_excl)
),
-- DISPAROS = cada nota privada do bot
disparos AS (
  SELECT m.conversa_id, m.contact_id, m.message_created_at AS dt
  FROM msgs m
  WHERE m.message_type=1 AND m.private=true
),
-- Cada disparo pode cair em múltiplos buckets (overlap)
disparos_buckets AS (
  SELECT d.conversa_id, d.contact_id, d.dt, b.bucket
  FROM disparos d
  CROSS JOIN LATERAL (
    SELECT unnest(ARRAY[
      CASE WHEN d.dt >= (SELECT d7_start FROM cfg) THEN 'd7' END,
      CASE WHEN d.dt >= (SELECT d8_start FROM cfg) AND d.dt < (SELECT d8_end FROM cfg) THEN 'd8_14' END,
      CASE WHEN d.dt >= (SELECT mf_start FROM cfg) AND d.dt < (SELECT mf_end FROM cfg) THEN 'mes_fechado' END,
      CASE WHEN (SELECT cust_start FROM cfg) IS NOT NULL
        AND d.dt >= (SELECT cust_start FROM cfg) AND d.dt < (SELECT cust_end FROM cfg) THEN 'custom' END
    ]) AS bucket
  ) AS b
  WHERE b.bucket IS NOT NULL
),
kpi_agg AS (
  SELECT bucket,
    COUNT(*) AS disparos,
    COUNT(DISTINCT contact_id) AS alunos_atendidos
  FROM disparos_buckets
  GROUP BY bucket
),
-- Mensagens públicas por bucket (com overlap)
msgs_buckets AS (
  SELECT m.conversa_id, m.contact_id, m.message_type, b.bucket
  FROM msgs m
  CROSS JOIN LATERAL (
    SELECT unnest(ARRAY[
      CASE WHEN m.message_created_at >= (SELECT d7_start FROM cfg) THEN 'd7' END,
      CASE WHEN m.message_created_at >= (SELECT d8_start FROM cfg) AND m.message_created_at < (SELECT d8_end FROM cfg) THEN 'd8_14' END,
      CASE WHEN m.message_created_at >= (SELECT mf_start FROM cfg) AND m.message_created_at < (SELECT mf_end FROM cfg) THEN 'mes_fechado' END,
      CASE WHEN (SELECT cust_start FROM cfg) IS NOT NULL
        AND m.message_created_at >= (SELECT cust_start FROM cfg) AND m.message_created_at < (SELECT cust_end FROM cfg) THEN 'custom' END
    ]) AS bucket
  ) AS b
  WHERE b.bucket IS NOT NULL AND m.private=false AND m.message_type IN (0,1)
),
msg_agg AS (
  SELECT bucket,
    COUNT(*) FILTER (WHERE message_type=0) AS msgs_aluno,
    COUNT(*) FILTER (WHERE message_type=1) AS msgs_tcs
  FROM msgs_buckets
  GROUP BY bucket
),
-- RESPOSTAS = conversas únicas com msg incoming do aluno no período (definição operacional)
respostas_agg AS (
  SELECT bucket, COUNT(DISTINCT conversa_id) AS respostas
  FROM msgs_buckets
  WHERE message_type=0
  GROUP BY bucket
),
-- Classificação de assuntos (1 conversa = 1 assunto dominante)
texto_aluno AS (
  SELECT m.conversa_id,
    STRING_AGG(m.content, ' | ' ORDER BY m.message_created_at) AS texto,
    MAX(m.message_created_at) AS ult_msg
  FROM msgs m
  WHERE m.message_type=0 AND m.private=false
    AND m.content IS NOT NULL AND LENGTH(m.content) > 5
  GROUP BY m.conversa_id
),
classif AS (
  SELECT conversa_id, ult_msg, texto,
    CASE
      WHEN texto ~* '\m(?<!n[ãa]o (é |t[áa] |ta |foi |est[áa] |estou |tenho |vou |tem |vai |consegui |deu |sei |quero |sou )?|nunca |jamais )(cancelar|reembolso|desistir|n[ãa]o quero mais|estornar|me devolv|me arrepend)' THEN 'risco'
      WHEN texto ~* '\m(plataforma|hotmart|n[ãa]o consigo acessar|n[ãa]o consegui acessar|ainda n[ãa]o (consigo|consegui) acessar|n[ãa]o consigo entrar|sem acesso|n[ãa]o recebi (o |meu )?acesso|n[ãa]o abre|n[ãa]o carrega|login|senha|v[ií]deo n[ãa]o|aula n[ãa]o (abre|carrega)|youtube|aplicativo)' THEN 'tecnico'
      WHEN texto ~* '\m(?<!n[ãa]o (é |t[áa] |ta |foi |est[áa] |estou |tenho |vou |tem |vai |consegui |deu |sei |quero |sou )?|nunca |jamais )(n[ãa]o entendi|t[oô] perdid|tenho d[uú]vida|me ajuda|dif[ií]cil|n[ãa]o sei como|preciso de ajuda|complicado|n[ãa]o fui avisad|n[ãa]o me avisaram|como funciona (o )?desafio|como (participo|entro|fa[çc]o pra entrar) (n?o )?desafio)' THEN 'dificuldade'
      -- PROVA = resultado real (arremate/leilão/primeiro resultado). NÃO usar 'venda'/'resultado' soltos:
      -- alunos são corretores (auto-resposta com "venda/imóveis") e o desafio se chama "Aceleração dos Resultados".
      WHEN texto ~* '\m(?<!n[ãa]o (é |t[áa] |ta |foi |est[áa] |estou |tenho |vou |tem |vai |consegui |deu |sei |quero |sou )?|nunca |jamais |ainda n[ãa]o )(arrematei|consegui arrematar|arrematar meu primeiro|minha primeira arremata|primeira arremata(ç|c)[ãa]o|ganhei (o |um |meu )?leil[ãa]o|lance vencedor|tive (meu )?primeiro resultado|j[aá] tive resultado|primeiro resultado com|consegui meu primeiro (im[oó]vel|resultado|lance)|fechei meu primeiro (neg[oó]cio|im[oó]vel)|recuperei o investimento)' THEN 'prova'
      WHEN texto ~* '\m(?<!n[ãa]o (é |t[áa] |ta |foi |est[áa] |estou |tenho |vou |tem |vai |consegui |deu |sei |quero |sou )?|nunca |jamais )(amei|adorei|adorando|amando|maravilhos|sensacional|incr[ií]vel|melhor (curso|conte[uú]do|aula|professor|mentor|investimento|decis[ãa]o)|gostei (muito|demais|bastante|do|da|de|desse|dessa)|gosto (muito|demais|bastante|do|da|de)|gostando (muito|demais|do|da|de)|muito bom|t[aá] (sendo )?[óo]tim[oa]|content[ea] (com|demais)|satisfeit[oa]|recomendo|did[aá]tica (boa|[óo]tim[oa]|excelente|incr[ií]vel|maravilh|sensacional)|vale a pena|valeu a pena|mudou (a |minha )vida|ajud(ou|ando) (muito|demais|bastante)|aprendendo (muito|bastante|demais)|conte[uú]do (bom|[óo]timo|rico|incr[ií]vel|excelente|maravilh)|(curso|aula|m[eé]todo|conte[uú]do) (é |est[áa] |t[áa] |ta |ficou |muito |bem )?(excelente|[óo]tim[oa]|maravilh|incr[ií]vel|sensacional|rico|top|bom)|parab[ée]ns|nota (10|dez)|amo (o |as |esse |essa )?(curso|aula|conte|m[eé]todo)|show de bola)' THEN 'elogios'
      WHEN texto ~* '\m(?<!n[ãa]o (é |t[áa] |ta |foi |est[áa] |estou |tenho |vou |tem |vai |consegui |deu |sei |quero |sou )?|nunca |jamais |ainda n[ãa]o )(consegui acessar|deu certo (o|os) acesso|deu certo o login|acesso (liberad|funcionou|deu certo|certo|ok)|j[aá] (acessei|entrei|consegui acessar)|liberaram (o|meu) acesso|recebi (o|meu) acesso|j[aá] (t[oô]|estou) (dentro|na plataforma|na [aá]rea)|entrei na (plataforma|[aá]rea|conta|aula))' THEN 'acesso'
      WHEN texto ~* '\m(?<!n[ãa]o (é |t[áa] |ta |foi |est[áa] |estou |tenho |vou |tem |vai |consegui |deu |sei |quero |sou )?|nunca |jamais |ainda n[ãa]o )(assisti|assistindo|comecei|come[çc]ando|j[aá] comecei|estou (assistindo|fazendo|estudando|vendo)|t[oô] (assistindo|fazendo|estudando)|m[oó]dulo|fiz a (aula|tarefa|atividade)|fazendo os? curso|t[oô] no curso)' THEN 'engajamento_curso'
      WHEN texto ~* '\m(?<!n[ãa]o (é |t[áa] |ta |foi |est[áa] |estou |tenho |vou |tem |vai |consegui |deu |sei |quero |sou )?|nunca |jamais )(vou (fazer|come[çc]ar|tentar|seguir|estudar|assistir|acessar|voltar|maratonar|me dedicar|correr atr[áa]s)|me comprometo|aceito o desafio|t[oô] dentro|partiu|bora|vamo|maraton|colocar em dia|p[ôo]r em dia)' THEN 'compromisso'
      WHEN texto ~* '\m(grupo|telegram|discord|comunidade|whats(app)? do)' THEN 'comunidade'
      WHEN texto ~* '\m(gratid[ãa]o|aben[çc]oad|obrigad|grat[oa]|familia|filh|m[ãa]e|esposa|marido|sa[uú]de|hospitalizad|viagem|viajando|ocupad|luto|doente|gr[aá]vid|gestante|cirurgia|internad|faleceu|faleciment)' THEN 'afetivo'
      WHEN texto ~* '(agradec(e|emos|o)[^|]{0,30}(contato|mensagem)|como (podemos|posso) (te |lhe )?ajud|em que (posso|podemos) (te |lhe )?ajud|escolha (uma|a |abaixo|uma das|uma op)|seja (muito )?bem.?vind|corretor[a]? de im[oó]vei|sou (a |o )?[a-zà-ÿ ]{2,28}(corretor|corretora|consultor|consultora|especialista|imobili)|creci|imobili[áa]ri|despachante|[àa] disposi[çc][ãa]o|estou em atendimento|plant[ãa]o|me informe seu nome|setor de vendas|central de vendas|financiamento (habitacional|imobili)|loc[aá][çc][ãa]o de im|especialistas? em|assim que poss[ií]vel[^|]{0,10}(retorn|respond)|em breve[^|]{0,10}(retorno|envio)|realizando (o|um) sonho|👉|🏡|🏠|🔑)' THEN 'automatico'
      ELSE 'outros'
    END AS categoria,
    texto ~* '\mdesafio' AS menciona_desafio
  FROM texto_aluno
),
classif_buckets AS (
  SELECT cl.conversa_id, cl.categoria, cl.menciona_desafio, cl.texto, b.bucket
  FROM classif cl
  CROSS JOIN LATERAL (
    SELECT unnest(ARRAY[
      CASE WHEN cl.ult_msg >= (SELECT d7_start FROM cfg) THEN 'd7' END,
      CASE WHEN cl.ult_msg >= (SELECT d8_start FROM cfg) AND cl.ult_msg < (SELECT d8_end FROM cfg) THEN 'd8_14' END,
      CASE WHEN cl.ult_msg >= (SELECT mf_start FROM cfg) AND cl.ult_msg < (SELECT mf_end FROM cfg) THEN 'mes_fechado' END,
      CASE WHEN (SELECT cust_start FROM cfg) IS NOT NULL
        AND cl.ult_msg >= (SELECT cust_start FROM cfg) AND cl.ult_msg < (SELECT cust_end FROM cfg) THEN 'custom' END
    ]) AS bucket
  ) AS b
  WHERE b.bucket IS NOT NULL
),
assuntos_raw AS (
  SELECT bucket, categoria, COUNT(*) AS n,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY bucket), 1) AS pct
  FROM classif_buckets GROUP BY bucket, categoria
),
assuntos_agg AS (
  SELECT bucket,
    jsonb_agg(jsonb_build_object('cat', categoria, 'n', n, 'pct', pct) ORDER BY n DESC) AS assuntos
  FROM assuntos_raw GROUP BY bucket
),
-- ===== Nuvem de palavras por bucket (top 40 termos do aluno) =====
nuvem_tokens AS (
  SELECT cb.bucket, w.word
  FROM classif_buckets cb
  JOIN texto_aluno ta ON ta.conversa_id = cb.conversa_id
  CROSS JOIN LATERAL regexp_split_to_table(lower(ta.texto), '[^a-zà-ÿ]+') AS w(word)
  WHERE length(w.word) >= 4
    AND w.word NOT IN (
      'para','pra','pro','com','uma','não','nao','mas','por','dos','das','como','mais','isso','esse','essa',
      'são','sao','foi','ser','tem','ter','sua','seu','meu','minha','minhas','meus','suas','seus','ele','ela',
      'eles','elas','aqui','então','entao','muito','muita','muitos','muitas','bem','ainda','sim','num','numa',
      'nas','nos','até','ate','depois','antes','sobre','entre','sem','quando','onde','quem','qual','quais',
      'porque','também','tambem','sempre','nunca','estava','estavam','sendo','você','voce','vcs','assim','cada',
      'pois','desde','vez','vezes','tipo','nada','algo','outro','outra','outros','outras','mesmo','mesma','aquilo',
      'esses','essas','aquele','aquela','tudo','todo','toda','todos','todas','dele','dela','deles','delas','este',
      'esta','estes','estas','estou','estamos','gente','coisa','coisas','bom','dia','boa','tarde','noite',
      'obrigado','obrigada','brigado','valeu','beleza','joia','ola','olá','kkkk','kkkkk','kkkkkk','kkkkkkk',
      'rsrs','haha','hahaha','vamos','vamo','agora','hoje','ontem','pode','posso','iria','fica','ficar','quero',
      'queria','acho','sei','tava','nossa','vai','vou','está','estão','estao','tenho','tinha','seria','isto',
      -- nomes próprios / persona da CS e do creator (adicionar por cliente quando necessário)
      'pamela','murilo'
    )
),
nuvem_ranked AS (
  SELECT bucket, word, COUNT(*) AS n,
    ROW_NUMBER() OVER (PARTITION BY bucket ORDER BY COUNT(*) DESC, word) AS rn
  FROM nuvem_tokens
  GROUP BY bucket, word
  HAVING COUNT(*) >= 2
),
nuvem_agg AS (
  SELECT bucket,
    jsonb_agg(jsonb_build_object('w', word, 'n', n) ORDER BY n DESC) AS nuvem
  FROM nuvem_ranked
  WHERE rn <= 40
  GROUP BY bucket
),
desafio_agg AS (
  SELECT bucket,
    jsonb_build_object(
      'n_mencionou', COUNT(*) FILTER (WHERE menciona_desafio),
      'pct_mencionou', COALESCE(ROUND(100.0*COUNT(*) FILTER (WHERE menciona_desafio)/NULLIF(COUNT(*),0), 1), 0),
      'n_engajou', COUNT(*) FILTER (WHERE menciona_desafio AND texto ~* '\m(vou (fazer|come[çc]ar|assistir|participar)|t[oô] dentro|topo|aceito|bora|partiu|j[aá] comecei)'),
      'pct_engajou', COALESCE(ROUND(100.0*COUNT(*) FILTER (WHERE menciona_desafio AND texto ~* '\m(vou (fazer|come[çc]ar|assistir|participar)|t[oô] dentro|topo|aceito|bora|partiu|j[aá] comecei)')/NULLIF(COUNT(*) FILTER (WHERE menciona_desafio),0), 1), 0)
    ) AS desafio
  FROM classif_buckets GROUP BY bucket
),
-- Ritmo por bucket (d7, d8_14 e custom — mes_fechado fica vazio)
ritmo_by_bucket AS (
  SELECT
    b.bucket,
    (m.message_created_at AT TIME ZONE 'America/Sao_Paulo')::date AS dia,
    COUNT(*) FILTER (WHERE m.message_type=0) AS rec,
    COUNT(*) FILTER (WHERE m.message_type=1) AS env
  FROM msgs m
  CROSS JOIN LATERAL (
    SELECT unnest(ARRAY[
      CASE WHEN m.message_created_at >= (SELECT d7_start FROM cfg) THEN 'd7' END,
      CASE WHEN m.message_created_at >= (SELECT d8_start FROM cfg) AND m.message_created_at < (SELECT d8_end FROM cfg) THEN 'd8_14' END,
      CASE WHEN (SELECT cust_start FROM cfg) IS NOT NULL
        AND m.message_created_at >= (SELECT cust_start FROM cfg) AND m.message_created_at < (SELECT cust_end FROM cfg) THEN 'custom' END
    ]) AS bucket
  ) AS b
  WHERE b.bucket IS NOT NULL AND m.private=false AND m.message_type IN (0,1)
  GROUP BY 1, 2
),
ritmo_agg AS (
  SELECT bucket,
    jsonb_agg(jsonb_build_object('dia', to_char(dia, 'DD/MM'), 'rec', rec, 'env', env) ORDER BY dia) AS r
  FROM ritmo_by_bucket GROUP BY bucket
),
-- Heatmap só pra d7 e custom
heatmap_by_bucket AS (
  SELECT
    b.bucket,
    EXTRACT(HOUR FROM m.message_created_at AT TIME ZONE 'America/Sao_Paulo')::int AS h,
    COUNT(*) AS n
  FROM msgs m
  CROSS JOIN LATERAL (
    SELECT unnest(ARRAY[
      CASE WHEN m.message_created_at >= (SELECT d7_start FROM cfg) THEN 'd7' END,
      CASE WHEN (SELECT cust_start FROM cfg) IS NOT NULL
        AND m.message_created_at >= (SELECT cust_start FROM cfg) AND m.message_created_at < (SELECT cust_end FROM cfg) THEN 'custom' END
    ]) AS bucket
  ) AS b
  WHERE b.bucket IS NOT NULL AND m.private=false AND m.message_type=0
  GROUP BY 1, 2
),
heatmap_agg AS (
  SELECT bucket,
    (SELECT array_agg(COALESCE(n2.n, 0) ORDER BY g.h)
     FROM generate_series(0,23) AS g(h)
     LEFT JOIN (SELECT h, n FROM heatmap_by_bucket WHERE bucket = ob.bucket) n2 ON n2.h = g.h) AS arr
  FROM (SELECT DISTINCT bucket FROM heatmap_by_bucket) ob
),
-- Classificação NO NÍVEL DA MENSAGEM (mesma regra) — pra escolher uma frase que de fato
-- exibe o sinal da categoria (não uma msg qualquer/auto-resposta da conversa).
msg_cat AS (
  SELECT m.conversa_id, m.content,
    CASE
      WHEN m.content ~* '\m(?<!n[ãa]o (é |t[áa] |ta |foi |est[áa] |estou |tenho |vou |tem |vai |consegui |deu |sei |quero |sou )?|nunca |jamais )(cancelar|reembolso|desistir|n[ãa]o quero mais|estornar|me devolv|me arrepend)' THEN 'risco'
      WHEN m.content ~* '\m(plataforma|hotmart|n[ãa]o consigo acessar|n[ãa]o consegui acessar|ainda n[ãa]o (consigo|consegui) acessar|n[ãa]o consigo entrar|sem acesso|n[ãa]o recebi (o |meu )?acesso|n[ãa]o abre|n[ãa]o carrega|login|senha|v[ií]deo n[ãa]o|aula n[ãa]o (abre|carrega)|youtube|aplicativo)' THEN 'tecnico'
      WHEN m.content ~* '\m(?<!n[ãa]o (é |t[áa] |ta |foi |est[áa] |estou |tenho |vou |tem |vai |consegui |deu |sei |quero |sou )?|nunca |jamais )(n[ãa]o entendi|t[oô] perdid|tenho d[uú]vida|me ajuda|dif[ií]cil|n[ãa]o sei como|preciso de ajuda|complicado|n[ãa]o fui avisad|n[ãa]o me avisaram|como funciona (o )?desafio|como (participo|entro|fa[çc]o pra entrar) (n?o )?desafio)' THEN 'dificuldade'
      WHEN m.content ~* '\m(?<!n[ãa]o (é |t[áa] |ta |foi |est[áa] |estou |tenho |vou |tem |vai |consegui |deu |sei |quero |sou )?|nunca |jamais |ainda n[ãa]o )(arrematei|consegui arrematar|arrematar meu primeiro|minha primeira arremata|primeira arremata(ç|c)[ãa]o|ganhei (o |um |meu )?leil[ãa]o|lance vencedor|tive (meu )?primeiro resultado|j[aá] tive resultado|primeiro resultado com|consegui meu primeiro (im[oó]vel|resultado|lance)|fechei meu primeiro (neg[oó]cio|im[oó]vel)|recuperei o investimento)' THEN 'prova'
      WHEN m.content ~* '\m(?<!n[ãa]o (é |t[áa] |ta |foi |est[áa] |estou |tenho |vou |tem |vai |consegui |deu |sei |quero |sou )?|nunca |jamais )(amei|adorei|adorando|amando|maravilhos|sensacional|incr[ií]vel|melhor (curso|conte[uú]do|aula|professor|mentor|investimento|decis[ãa]o)|gostei (muito|demais|bastante|do|da|de|desse|dessa)|gosto (muito|demais|bastante|do|da|de)|gostando (muito|demais|do|da|de)|muito bom|t[aá] (sendo )?[óo]tim[oa]|content[ea] (com|demais)|satisfeit[oa]|recomendo|did[aá]tica (boa|[óo]tim[oa]|excelente|incr[ií]vel|maravilh|sensacional)|vale a pena|valeu a pena|mudou (a |minha )vida|ajud(ou|ando) (muito|demais|bastante)|aprendendo (muito|bastante|demais)|conte[uú]do (bom|[óo]timo|rico|incr[ií]vel|excelente|maravilh)|(curso|aula|m[eé]todo|conte[uú]do) (é |est[áa] |t[áa] |ta |ficou |muito |bem )?(excelente|[óo]tim[oa]|maravilh|incr[ií]vel|sensacional|rico|top|bom)|parab[ée]ns|nota (10|dez)|amo (o |as |esse |essa )?(curso|aula|conte|m[eé]todo)|show de bola)' THEN 'elogios'
      WHEN m.content ~* '\m(?<!n[ãa]o (é |t[áa] |ta |foi |est[áa] |estou |tenho |vou |tem |vai |consegui |deu |sei |quero |sou )?|nunca |jamais |ainda n[ãa]o )(consegui acessar|deu certo (o|os) acesso|deu certo o login|acesso (liberad|funcionou|deu certo|certo|ok)|j[aá] (acessei|entrei|consegui acessar)|liberaram (o|meu) acesso|recebi (o|meu) acesso|j[aá] (t[oô]|estou) (dentro|na plataforma|na [aá]rea)|entrei na (plataforma|[aá]rea|conta|aula))' THEN 'acesso'
      WHEN m.content ~* '\m(?<!n[ãa]o (é |t[áa] |ta |foi |est[áa] |estou |tenho |vou |tem |vai |consegui |deu |sei |quero |sou )?|nunca |jamais |ainda n[ãa]o )(assisti|assistindo|comecei|come[çc]ando|j[aá] comecei|estou (assistindo|fazendo|estudando|vendo)|t[oô] (assistindo|fazendo|estudando)|m[oó]dulo|fiz a (aula|tarefa|atividade)|fazendo os? curso|t[oô] no curso)' THEN 'engajamento_curso'
      WHEN m.content ~* '\m(?<!n[ãa]o (é |t[áa] |ta |foi |est[áa] |estou |tenho |vou |tem |vai |consegui |deu |sei |quero |sou )?|nunca |jamais )(vou (fazer|come[çc]ar|tentar|seguir|estudar|assistir|acessar|voltar|maratonar|me dedicar|correr atr[áa]s)|me comprometo|aceito o desafio|t[oô] dentro|partiu|bora|vamo|maraton|colocar em dia|p[ôo]r em dia)' THEN 'compromisso'
      WHEN m.content ~* '\m(grupo|telegram|discord|comunidade|whats(app)? do)' THEN 'comunidade'
      WHEN m.content ~* '\m(gratid[ãa]o|aben[çc]oad|obrigad|grat[oa]|familia|filh|m[ãa]e|esposa|marido|sa[uú]de|hospitalizad|viagem|viajando|ocupad|luto|doente|gr[aá]vid|gestante|cirurgia|internad|faleceu|faleciment)' THEN 'afetivo'
      ELSE 'outros'
    END AS mcat
  FROM msgs m
  WHERE m.message_type=0 AND m.private=false AND m.content IS NOT NULL
    AND LENGTH(m.content) BETWEEN 25 AND 250
    AND m.content !~* '(agradec(emos|o) (seu|sua) (contato|mensagem))|(n[ãa]o (estamos|estou|estarei) dispon[ií]ve)|(responderemos|retornarei|retorno em breve|assim que poss[ií]vel)|(deixe sua mensagem)|(em breve (envio|retorno))|(hor[áa]rio de atendimento)|(seja (muito )?bem.?vindo)|(sou (corretor|corretora|consultor|consultora|especialista))|(creci)|(setor de vendas)|(central de vendas)|(plantão)'
),
frases_raw AS (
  -- só pega frases cuja PRÓPRIA mensagem exibe o sinal da categoria da conversa
  SELECT DISTINCT ON (mc.conversa_id, cb.categoria, cb.bucket) mc.content, cb.categoria, cb.bucket
  FROM msg_cat mc
  JOIN classif_buckets cb ON cb.conversa_id = mc.conversa_id AND cb.categoria = mc.mcat
  WHERE cb.bucket IN ('d7','d8_14','mes_fechado','custom')
    AND cb.categoria NOT IN ('outros','automatico')
),
frases_ranked AS (
  SELECT content, categoria, bucket,
    ROW_NUMBER() OVER (PARTITION BY bucket, categoria ORDER BY md5(content)) AS rn
  FROM frases_raw
),
frases_agg AS (
  SELECT bucket, jsonb_object_agg(categoria, frases) AS frases
  FROM (
    SELECT bucket, categoria, jsonb_agg(content ORDER BY rn) AS frases
    FROM frases_ranked WHERE rn <= 3 GROUP BY bucket, categoria
  ) x GROUP BY bucket
),
-- All-time: respostas = conversas únicas com incoming msg em qualquer momento
alltime_agg AS (
  SELECT
    COUNT(*) AS disparos,
    COUNT(DISTINCT contact_id) AS alunos
  FROM disparos
),
alltime_resp AS (
  SELECT COUNT(DISTINCT conversa_id) AS respostas
  FROM msgs WHERE private=false AND message_type=0
),
alltime_conv AS (
  SELECT COUNT(DISTINCT conversa_id) AS conversas_unicas
  FROM msgs WHERE private=false AND message_type IN (0,1)
),
-- Mês atual: respostas = conversas únicas com incoming msg no mês atual
mes_atual_agg AS (
  SELECT
    COUNT(*) AS disparos,
    COUNT(DISTINCT contact_id) AS alunos
  FROM disparos
  WHERE dt >= (SELECT m_atual_start FROM cfg)
),
mes_atual_resp AS (
  SELECT COUNT(DISTINCT conversa_id) AS respostas
  FROM msgs WHERE private=false AND message_type=0
    AND message_created_at >= (SELECT m_atual_start FROM cfg)
),
periodos_meta AS (
  SELECT bucket, label, sublabel FROM (VALUES
    ('d7', 'Últimos 7 dias',
      to_char(((SELECT d7_start FROM cfg) AT TIME ZONE 'America/Sao_Paulo')::date, 'DD/MM') || ' a ' || to_char((now() AT TIME ZONE 'America/Sao_Paulo')::date, 'DD/MM')),
    ('d8_14', 'Semana retrasada',
      to_char(((SELECT d8_start FROM cfg) AT TIME ZONE 'America/Sao_Paulo')::date, 'DD/MM') || ' a ' || to_char((((SELECT d8_end FROM cfg) - interval '1 day') AT TIME ZONE 'America/Sao_Paulo')::date, 'DD/MM')),
    ('mes_fechado',
      'Mês de ' || (ARRAY['Jan','Fev','Mar','Abr','Mai','Jun','Jul','Ago','Set','Out','Nov','Dez'])[EXTRACT(MONTH FROM (SELECT mf_start FROM cfg) AT TIME ZONE 'America/Sao_Paulo')::int]
        || '/' || to_char(((SELECT mf_start FROM cfg) AT TIME ZONE 'America/Sao_Paulo')::date, 'YY'),
      to_char(((SELECT mf_start FROM cfg) AT TIME ZONE 'America/Sao_Paulo')::date, 'DD/MM/YYYY') || ' a ' || to_char((((SELECT mf_end FROM cfg) - interval '1 day') AT TIME ZONE 'America/Sao_Paulo')::date, 'DD/MM/YYYY'))
  ) AS t(bucket, label, sublabel)
  UNION ALL
  -- Adiciona bucket 'custom' apenas se p_custom_start foi passado
  SELECT 'custom',
    to_char(p_custom_start, 'DD/MM') || ' a ' || to_char(p_custom_end, 'DD/MM'),
    to_char(p_custom_start, 'DD/MM/YYYY') || ' a ' || to_char(p_custom_end, 'DD/MM/YYYY')
  WHERE p_custom_start IS NOT NULL AND p_custom_end IS NOT NULL
)
SELECT jsonb_build_object(
  'atualizado_em', to_char(now() AT TIME ZONE 'America/Sao_Paulo', 'YYYY-MM-DD HH24:MI'),
  'inicio_projeto', to_char(p_inicio_projeto, 'YYYY-MM-DD'),
  'meta_mensal', p_meta_mensal,
  'dias_corridos', (SELECT dias_corridos FROM cfg),
  'alltime', (SELECT jsonb_build_object(
    'disparos', a.disparos,
    'respostas', (SELECT respostas FROM alltime_resp),
    'taxa_resp', CASE WHEN a.disparos > 0
      THEN ROUND(100.0*(SELECT respostas FROM alltime_resp)/a.disparos, 1) ELSE 0 END,
    'alunos_atendidos', a.alunos,
    'disparos_por_aluno', CASE WHEN a.alunos > 0 THEN ROUND(a.disparos::numeric/a.alunos, 2) ELSE 0 END,
    'conversas_unicas', (SELECT conversas_unicas FROM alltime_conv),
    'meta_proporcional', ROUND((SELECT dias_corridos FROM cfg) * p_meta_mensal::numeric / 30)::int,
    'pct_meta', CASE WHEN (SELECT dias_corridos FROM cfg) > 0 AND p_meta_mensal > 0
      THEN ROUND(100.0 * a.disparos / ((SELECT dias_corridos FROM cfg) * p_meta_mensal::numeric / 30), 1) ELSE 0 END,
    'pace_diario', CASE WHEN (SELECT dias_corridos FROM cfg) > 0
      THEN ROUND(a.disparos::numeric / (SELECT dias_corridos FROM cfg), 1) ELSE 0 END
  ) FROM alltime_agg a),
  'mes_atual', (SELECT jsonb_build_object(
    'label', (ARRAY['Jan','Fev','Mar','Abr','Mai','Jun','Jul','Ago','Set','Out','Nov','Dez'])[EXTRACT(MONTH FROM now() AT TIME ZONE 'America/Sao_Paulo')::int]
      || '/' || to_char(now() AT TIME ZONE 'America/Sao_Paulo', 'YY'),
    'disparos', ma.disparos,
    'respostas', (SELECT respostas FROM mes_atual_resp),
    'taxa_resp', CASE WHEN ma.disparos > 0
      THEN ROUND(100.0*(SELECT respostas FROM mes_atual_resp)/ma.disparos, 1) ELSE 0 END,
    'alunos_atendidos', ma.alunos,
    'dias_decorridos', (SELECT dias_mes_atual FROM cfg),
    'meta', p_meta_mensal,
    'meta_proporcional', ROUND((SELECT dias_mes_atual FROM cfg) * p_meta_mensal::numeric / 30)::int,
    'pct_meta', CASE WHEN (SELECT dias_mes_atual FROM cfg) > 0 AND p_meta_mensal > 0
      THEN ROUND(100.0 * ma.disparos / ((SELECT dias_mes_atual FROM cfg) * p_meta_mensal::numeric / 30), 1) ELSE 0 END,
    'projecao_fim_mes', CASE WHEN (SELECT dias_mes_atual FROM cfg) > 0
      THEN ROUND(ma.disparos::numeric * 30 / (SELECT dias_mes_atual FROM cfg))::int ELSE 0 END
  ) FROM mes_atual_agg ma),
  'periodos', (
    SELECT jsonb_object_agg(pm.bucket, jsonb_build_object(
      'label', pm.label, 'sublabel', pm.sublabel,
      'disparos', COALESCE(k.disparos, 0),
      'respostas', COALESCE(r.respostas, 0),
      'taxa_resp', CASE WHEN COALESCE(k.disparos,0) > 0
        THEN ROUND(100.0*COALESCE(r.respostas,0)/k.disparos, 1) ELSE 0 END,
      'alunos_atendidos', COALESCE(k.alunos_atendidos, 0),
      'disparos_por_aluno', CASE WHEN COALESCE(k.alunos_atendidos,0) > 0
        THEN ROUND(k.disparos::numeric/k.alunos_atendidos, 2) ELSE 0 END,
      'msgs_aluno', COALESCE(m.msgs_aluno, 0),
      'msgs_tcs', COALESCE(m.msgs_tcs, 0),
      'assuntos', COALESCE(a.assuntos, '[]'::jsonb),
      'nuvem', COALESCE(nv.nuvem, '[]'::jsonb),
      'desafio', COALESCE(d.desafio, '{}'::jsonb),
      'frases', COALESCE(f.frases, '{}'::jsonb),
      'ritmo', COALESCE(rt.r, '[]'::jsonb),
      'heatmap', COALESCE(to_jsonb(hm.arr), '[]'::jsonb)
    ))
    FROM periodos_meta pm
    LEFT JOIN kpi_agg k ON k.bucket = pm.bucket
    LEFT JOIN msg_agg m ON m.bucket = pm.bucket
    LEFT JOIN respostas_agg r ON r.bucket = pm.bucket
    LEFT JOIN assuntos_agg a ON a.bucket = pm.bucket
    LEFT JOIN nuvem_agg nv ON nv.bucket = pm.bucket
    LEFT JOIN desafio_agg d ON d.bucket = pm.bucket
    LEFT JOIN frases_agg f ON f.bucket = pm.bucket
    LEFT JOIN ritmo_agg rt ON rt.bucket = pm.bucket
    LEFT JOIN heatmap_agg hm ON hm.bucket = pm.bucket
  )
)
$func$;

GRANT EXECUTE ON FUNCTION public.cs_resumo_atendimento(uuid, date, int, date, date) TO anon, authenticated;

COMMENT ON FUNCTION public.cs_resumo_atendimento IS
'v5 — Categorias acesso + elogios; prova = resultado real; nuvem de palavras por período. Respostas = conversas únicas com msg do aluno no período; aceita p_custom_start/p_custom_end pra retornar bucket "custom".';
