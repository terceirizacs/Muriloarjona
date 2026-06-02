-- ============================================================
-- Função: public.cs_resumo_atendimento  (v2)
-- Mudanças v2:
--   • DISPARO = cada nota privada do bot (1 msg = 1 disparo), não mais 1 conv = 1 disparo
--   • Buckets independentes (overlap permitido via LATERAL) — mes_fechado deixa de perder dias
--   • Remove cs_voltou e taxa_cs_resp
--   • Adiciona alunos_atendidos (contatos únicos) e disparos_por_aluno (média)
--   • Adiciona pace_mensal e pct_meta_proporcional (on track) em mes_atual e alltime
-- ============================================================

CREATE OR REPLACE FUNCTION public.cs_resumo_atendimento(
  p_cliente_id uuid,
  p_inicio_projeto date DEFAULT '2026-04-27'::date,
  p_meta_mensal int DEFAULT 800
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
    ((now() AT TIME ZONE 'America/Sao_Paulo')::date - (date_trunc('month', now() AT TIME ZONE 'America/Sao_Paulo')::date) + 1)::int AS dias_mes_atual
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
-- DISPAROS = cada nota privada do bot (cada msg conta)
disparos AS (
  SELECT m.conversa_id, m.contact_id, m.message_created_at AS dt,
    LEAD(m.message_created_at) OVER (PARTITION BY m.conversa_id ORDER BY m.message_created_at) AS prox_dt
  FROM msgs m
  WHERE m.message_type=1 AND m.private=true
),
-- Cada disparo: respondeu? (msg do aluno entre este disparo e o próximo na mesma conversa)
disparos_resp AS (
  SELECT d.*,
    EXISTS(
      SELECT 1 FROM msgs r
      WHERE r.conversa_id = d.conversa_id
        AND r.message_type=0 AND r.private=false
        AND r.message_created_at > d.dt
        AND (d.prox_dt IS NULL OR r.message_created_at < d.prox_dt)
    ) AS respondeu
  FROM disparos d
),
-- Cada disparo pode cair em múltiplos buckets (overlap permitido)
disparos_buckets AS (
  SELECT dr.conversa_id, dr.contact_id, dr.dt, dr.respondeu, b.bucket
  FROM disparos_resp dr
  CROSS JOIN LATERAL (
    SELECT unnest(ARRAY[
      CASE WHEN dr.dt >= (SELECT d7_start FROM cfg) THEN 'd7' END,
      CASE WHEN dr.dt >= (SELECT d8_start FROM cfg) AND dr.dt < (SELECT d8_end FROM cfg) THEN 'd8_14' END,
      CASE WHEN dr.dt >= (SELECT mf_start FROM cfg) AND dr.dt < (SELECT mf_end FROM cfg) THEN 'mes_fechado' END
    ]) AS bucket
  ) AS b
  WHERE b.bucket IS NOT NULL
),
kpi_agg AS (
  SELECT bucket,
    COUNT(*) AS disparos,
    COUNT(*) FILTER (WHERE respondeu) AS respostas,
    COUNT(DISTINCT contact_id) AS alunos_atendidos
  FROM disparos_buckets
  GROUP BY bucket
),
-- Volume de msgs públicas por bucket (com overlap)
msgs_buckets AS (
  SELECT m.conversa_id, m.contact_id, m.message_type, b.bucket
  FROM msgs m
  CROSS JOIN LATERAL (
    SELECT unnest(ARRAY[
      CASE WHEN m.message_created_at >= (SELECT d7_start FROM cfg) THEN 'd7' END,
      CASE WHEN m.message_created_at >= (SELECT d8_start FROM cfg) AND m.message_created_at < (SELECT d8_end FROM cfg) THEN 'd8_14' END,
      CASE WHEN m.message_created_at >= (SELECT mf_start FROM cfg) AND m.message_created_at < (SELECT mf_end FROM cfg) THEN 'mes_fechado' END
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
      WHEN texto ~* '\m(cancelar|reembolso|desistir|n[ãa]o quero mais|estornar|me devolv|me arrepend)' THEN 'risco'
      WHEN texto ~* '\m(plataforma|hotmart|n[ãa]o consigo acessar|n[ãa]o abre|n[ãa]o carrega|login|senha|v[ií]deo n[ãa]o|aula n[ãa]o (abre|carrega)|youtube|aplicativo)' THEN 'tecnico'
      WHEN texto ~* '\m(n[ãa]o entendi|t[oô] perdid|tenho d[uú]vida|me ajuda|dif[ií]cil|n[ãa]o sei como|preciso de ajuda|complicado)' THEN 'dificuldade'
      WHEN texto ~* '\m(consegui|arrematei|arremat|fechei|primeira venda|primeiro im[oó]vel|deu certo|funcionou|resultado|fechad[ao]|venda)' THEN 'prova'
      WHEN texto ~* '\m(vou (fazer|come[çc]ar|tentar|seguir|estudar|assistir|acessar|voltar)|me comprometo|aceito o desafio|t[oô] dentro|partiu|bora|vamo)' THEN 'compromisso'
      WHEN texto ~* '\m(gratid[ãa]o|aben[çc]oad|obrigad|grat[oa]|familia|filh|m[ãa]e|esposa|marido|sa[uú]de|hospitalizad|viagem|viajando|ocupad|luto|doente)' THEN 'afetivo'
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
      CASE WHEN cl.ult_msg >= (SELECT mf_start FROM cfg) AND cl.ult_msg < (SELECT mf_end FROM cfg) THEN 'mes_fechado' END
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
ritmo_d7_raw AS (
  SELECT (message_created_at AT TIME ZONE 'America/Sao_Paulo')::date AS dia,
    COUNT(*) FILTER (WHERE message_type=0) AS rec,
    COUNT(*) FILTER (WHERE message_type=1) AS env
  FROM msgs
  WHERE private=false AND message_type IN (0,1)
    AND message_created_at >= (SELECT d7_start FROM cfg)
  GROUP BY 1
),
ritmo_d7 AS (SELECT jsonb_agg(jsonb_build_object('dia', to_char(dia, 'DD/MM'), 'rec', rec, 'env', env) ORDER BY dia) AS r FROM ritmo_d7_raw),
ritmo_d8_raw AS (
  SELECT (message_created_at AT TIME ZONE 'America/Sao_Paulo')::date AS dia,
    COUNT(*) FILTER (WHERE message_type=0) AS rec,
    COUNT(*) FILTER (WHERE message_type=1) AS env
  FROM msgs
  WHERE private=false AND message_type IN (0,1)
    AND message_created_at >= (SELECT d8_start FROM cfg)
    AND message_created_at < (SELECT d8_end FROM cfg)
  GROUP BY 1
),
ritmo_d8 AS (SELECT jsonb_agg(jsonb_build_object('dia', to_char(dia, 'DD/MM'), 'rec', rec, 'env', env) ORDER BY dia) AS r FROM ritmo_d8_raw),
heatmap_d7_raw AS (
  SELECT EXTRACT(HOUR FROM message_created_at AT TIME ZONE 'America/Sao_Paulo')::int AS h, COUNT(*) AS n
  FROM msgs
  WHERE private=false AND message_type=0
    AND message_created_at >= (SELECT d7_start FROM cfg)
  GROUP BY 1
),
heatmap_d7 AS (
  SELECT array_agg(COALESCE(n, 0) ORDER BY h) AS arr
  FROM (SELECT g.h, hr.n FROM generate_series(0, 23) AS g(h) LEFT JOIN heatmap_d7_raw hr ON hr.h = g.h) x
),
frases_raw AS (
  SELECT DISTINCT ON (m.conversa_id, cb.categoria, cb.bucket) m.content, cb.categoria, cb.bucket
  FROM msgs m
  JOIN classif_buckets cb ON cb.conversa_id = m.conversa_id
  WHERE m.message_type=0 AND m.private=false
    AND m.content IS NOT NULL
    AND LENGTH(m.content) BETWEEN 30 AND 250
    AND cb.bucket IN ('d7','d8_14','mes_fechado')
    AND cb.categoria <> 'outros'
    AND m.content !~* '(agradec(emos|o) (seu|sua) (contato|mensagem))|(n[ãa]o estamos dispon[ií]veis)|(responderemos assim que)|(deixe sua mensagem que logo retorno)|(em breve envio)'
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
-- All-time: disparos (cada msg), respostas e alunos únicos ao longo do projeto
alltime_disparos AS (
  SELECT COUNT(*) AS disparos,
    COUNT(*) FILTER (WHERE respondeu) AS respostas,
    COUNT(DISTINCT contact_id) AS alunos
  FROM disparos_resp
),
alltime_conv AS (
  SELECT COUNT(DISTINCT conversa_id) AS conversas_unicas
  FROM msgs WHERE private=false AND message_type IN (0,1)
),
-- Mês atual: disparos no mês corrente
mes_atual_agg AS (
  SELECT
    COUNT(*) AS disparos,
    COUNT(DISTINCT contact_id) AS alunos
  FROM disparos_resp
  WHERE dt >= (SELECT m_atual_start FROM cfg)
),
periodos_meta AS (
  SELECT * FROM (VALUES
    ('d7', 'Últimos 7 dias',
      to_char(((SELECT d7_start FROM cfg) AT TIME ZONE 'America/Sao_Paulo')::date, 'DD/MM') || ' a ' || to_char((now() AT TIME ZONE 'America/Sao_Paulo')::date, 'DD/MM')),
    ('d8_14', 'Semana retrasada',
      to_char(((SELECT d8_start FROM cfg) AT TIME ZONE 'America/Sao_Paulo')::date, 'DD/MM') || ' a ' || to_char((((SELECT d8_end FROM cfg) - interval '1 day') AT TIME ZONE 'America/Sao_Paulo')::date, 'DD/MM')),
    ('mes_fechado',
      'Mês de ' || (ARRAY['Jan','Fev','Mar','Abr','Mai','Jun','Jul','Ago','Set','Out','Nov','Dez'])[EXTRACT(MONTH FROM (SELECT mf_start FROM cfg) AT TIME ZONE 'America/Sao_Paulo')::int]
        || '/' || to_char(((SELECT mf_start FROM cfg) AT TIME ZONE 'America/Sao_Paulo')::date, 'YY'),
      to_char(((SELECT mf_start FROM cfg) AT TIME ZONE 'America/Sao_Paulo')::date, 'DD/MM/YYYY') || ' a ' || to_char((((SELECT mf_end FROM cfg) - interval '1 day') AT TIME ZONE 'America/Sao_Paulo')::date, 'DD/MM/YYYY'))
  ) AS t(bucket, label, sublabel)
)
SELECT jsonb_build_object(
  'atualizado_em', to_char(now() AT TIME ZONE 'America/Sao_Paulo', 'YYYY-MM-DD HH24:MI'),
  'inicio_projeto', to_char(p_inicio_projeto, 'YYYY-MM-DD'),
  'meta_mensal', p_meta_mensal,
  'dias_corridos', (SELECT dias_corridos FROM cfg),
  'alltime', (SELECT jsonb_build_object(
    'disparos', ad.disparos,
    'respostas', ad.respostas,
    'taxa_resp', CASE WHEN ad.disparos > 0 THEN ROUND(100.0*ad.respostas/ad.disparos, 1) ELSE 0 END,
    'alunos_atendidos', ad.alunos,
    'disparos_por_aluno', CASE WHEN ad.alunos > 0 THEN ROUND(ad.disparos::numeric/ad.alunos, 2) ELSE 0 END,
    'conversas_unicas', (SELECT conversas_unicas FROM alltime_conv),
    -- Meta proporcional: disparos / (dias_corridos * meta_mensal/30)
    'meta_proporcional', ROUND((SELECT dias_corridos FROM cfg) * p_meta_mensal::numeric / 30)::int,
    'pct_meta', CASE WHEN (SELECT dias_corridos FROM cfg) > 0 AND p_meta_mensal > 0
      THEN ROUND(100.0 * ad.disparos / ((SELECT dias_corridos FROM cfg) * p_meta_mensal::numeric / 30), 1)
      ELSE 0 END,
    'pace_diario', CASE WHEN (SELECT dias_corridos FROM cfg) > 0
      THEN ROUND(ad.disparos::numeric / (SELECT dias_corridos FROM cfg), 1) ELSE 0 END
  ) FROM alltime_disparos ad),
  'mes_atual', (SELECT jsonb_build_object(
    'label', (ARRAY['Jan','Fev','Mar','Abr','Mai','Jun','Jul','Ago','Set','Out','Nov','Dez'])[EXTRACT(MONTH FROM now() AT TIME ZONE 'America/Sao_Paulo')::int]
      || '/' || to_char(now() AT TIME ZONE 'America/Sao_Paulo', 'YY'),
    'disparos', ma.disparos,
    'alunos_atendidos', ma.alunos,
    'dias_decorridos', (SELECT dias_mes_atual FROM cfg),
    'meta', p_meta_mensal,
    -- Meta proporcional pelos dias decorridos no mês
    'meta_proporcional', ROUND((SELECT dias_mes_atual FROM cfg) * p_meta_mensal::numeric / 30)::int,
    'pct_meta', CASE WHEN (SELECT dias_mes_atual FROM cfg) > 0 AND p_meta_mensal > 0
      THEN ROUND(100.0 * ma.disparos / ((SELECT dias_mes_atual FROM cfg) * p_meta_mensal::numeric / 30), 1)
      ELSE 0 END,
    'projecao_fim_mes', CASE WHEN (SELECT dias_mes_atual FROM cfg) > 0
      THEN ROUND(ma.disparos::numeric * 30 / (SELECT dias_mes_atual FROM cfg))::int ELSE 0 END
  ) FROM mes_atual_agg ma),
  'periodos', (
    SELECT jsonb_object_agg(pm.bucket, jsonb_build_object(
      'label', pm.label, 'sublabel', pm.sublabel,
      'disparos', COALESCE(k.disparos, 0),
      'respostas', COALESCE(k.respostas, 0),
      'taxa_resp', CASE WHEN COALESCE(k.disparos,0) > 0 THEN ROUND(100.0*k.respostas/k.disparos, 1) ELSE 0 END,
      'alunos_atendidos', COALESCE(k.alunos_atendidos, 0),
      'disparos_por_aluno', CASE WHEN COALESCE(k.alunos_atendidos,0) > 0
        THEN ROUND(k.disparos::numeric/k.alunos_atendidos, 2) ELSE 0 END,
      'msgs_aluno', COALESCE(m.msgs_aluno, 0),
      'msgs_tcs', COALESCE(m.msgs_tcs, 0),
      'assuntos', COALESCE(a.assuntos, '[]'::jsonb),
      'desafio', COALESCE(d.desafio, '{}'::jsonb),
      'frases', COALESCE(f.frases, '{}'::jsonb),
      'ritmo', CASE pm.bucket
        WHEN 'd7' THEN COALESCE((SELECT r FROM ritmo_d7), '[]'::jsonb)
        WHEN 'd8_14' THEN COALESCE((SELECT r FROM ritmo_d8), '[]'::jsonb)
        ELSE '[]'::jsonb END,
      'heatmap', CASE pm.bucket
        WHEN 'd7' THEN COALESCE(to_jsonb((SELECT arr FROM heatmap_d7)), '[]'::jsonb)
        ELSE '[]'::jsonb END
    ))
    FROM periodos_meta pm
    LEFT JOIN kpi_agg k ON k.bucket = pm.bucket
    LEFT JOIN msg_agg m ON m.bucket = pm.bucket
    LEFT JOIN assuntos_agg a ON a.bucket = pm.bucket
    LEFT JOIN desafio_agg d ON d.bucket = pm.bucket
    LEFT JOIN frases_agg f ON f.bucket = pm.bucket
  )
)
$func$;

GRANT EXECUTE ON FUNCTION public.cs_resumo_atendimento(uuid, date, int) TO anon, authenticated;

COMMENT ON FUNCTION public.cs_resumo_atendimento IS
'v2 — Disparo = cada nota privada do bot; buckets independentes via LATERAL; remove cs_voltou; adiciona alunos_atendidos, disparos_por_aluno, pct_meta e pace.';
