-- =====================================================================
-- GenVar-PE · Hito 2 · 4.4 Vistas de usuario
-- =====================================================================
SET search_path TO genvar;

-- Atributo derivado tipo_variante (RS15). Se calcula aquí y no se guarda,
-- para no romper la FNBC ({alelo_ref, alelo_alt} -> tipo_variante).
CREATE OR REPLACE VIEW v_variante AS
SELECT v.*,
       CASE
         WHEN length(alelo_ref) = 1 AND length(alelo_alt) = 1 THEN 'SNV'
         WHEN length(alelo_ref) < length(alelo_alt)           THEN 'INSERCION'
         WHEN length(alelo_ref) > length(alelo_alt)           THEN 'DELECION'
         ELSE 'MNV'
       END AS tipo_variante
FROM variante v;

-- Genetista clínico: variantes reportables de cada donante (base de C1).
CREATE OR REPLACE VIEW v_reporte_clinico AS
SELECT m.id_donante, g.id_muestra, g.id_corrida,
       v.id_variante, v.rsid, v.id_cromosoma, v.posicion, v.alelo_ref, v.alelo_alt,
       g.genotipo, g.profundidad, g.vaf,
       ge.simbolo AS gen, vg.consecuencia, vg.impacto,
       c.nombre   AS condicion, a.significancia, a.estado_revision
FROM genotipo g
JOIN muestra m            ON m.id_muestra   = g.id_muestra
JOIN variante v           ON v.id_variante  = g.id_variante
JOIN anotacion_clinica a  ON a.id_variante  = g.id_variante
JOIN condicion c          ON c.id_condicion = a.id_condicion
LEFT JOIN variante_gen vg ON vg.id_variante = g.id_variante
LEFT JOIN gen ge          ON ge.id_gen      = vg.id_gen
WHERE g.filtro = 'PASS' AND g.profundidad >= 20
  AND a.significancia IN ('PATOGENICA','PROBABLEMENTE_PATOGENICA');

-- Investigador: solo datos agregados, nunca filas de un donante (privacidad).
CREATE OR REPLACE VIEW v_frecuencia_cohorte AS
WITH secuenciados AS (
    SELECT count(DISTINCT m.id_donante) AS n
    FROM muestra m JOIN muestra_corrida mc ON mc.id_muestra = m.id_muestra
)
SELECT v.id_variante, v.rsid, v.id_cromosoma, v.posicion, v.alelo_ref, v.alelo_alt,
       count(DISTINCT m.id_donante)                                     AS n_donantes,
       round(sum(CASE g.genotipo WHEN '1/1' THEN 2 ELSE 1 END)::numeric
             / (2 * (SELECT n FROM secuenciados)), 6)                   AS frec_cohorte,
       v.frec_poblacional
FROM genotipo g
JOIN muestra m  ON m.id_muestra  = g.id_muestra
JOIN variante v ON v.id_variante = g.id_variante
GROUP BY v.id_variante;

-- Control de calidad por muestra secuenciada, con su laboratorio.
CREATE OR REPLACE VIEW v_qc_muestra_corrida AS
SELECT l.nombre AS laboratorio, s.id_secuenciador, c.id_corrida, c.fecha_inicio,
       mc.id_muestra, mc.cobertura_media, mc.pct_q30,
       (mc.cobertura_media < 30 OR mc.pct_q30 < 80) AS calidad_deficiente
FROM muestra_corrida mc
JOIN corrida c      ON c.id_corrida      = mc.id_corrida
JOIN secuenciador s ON s.id_secuenciador = c.id_secuenciador
JOIN laboratorio l  ON l.id_laboratorio  = s.id_laboratorio;

-- Auditor: trazabilidad completa de cada genotipo (requisito 1 del Hito 1).
CREATE OR REPLACE VIEW v_trazabilidad AS
SELECT g.id_variante, g.genotipo, g.id_muestra, m.id_donante,
       g.id_corrida, c.fecha_inicio, s.id_secuenciador, l.nombre AS laboratorio
FROM genotipo g
JOIN muestra m      ON m.id_muestra      = g.id_muestra
JOIN corrida c      ON c.id_corrida      = g.id_corrida
JOIN secuenciador s ON s.id_secuenciador = c.id_secuenciador
JOIN laboratorio l  ON l.id_laboratorio  = s.id_laboratorio;
