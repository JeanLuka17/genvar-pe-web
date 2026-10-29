-- =====================================================================
-- GenVar-PE · Hito 2 · 5.1.2 Implementación de las consultas en SQL
-- Uso: psql -d genvar -v donante=CGA-D000001 -f 07_consultas.sql
-- =====================================================================
SET search_path TO genvar;
\if :{?donante} \else \set donante 'CGA-D000001' \endif
\set crom '1'
\set ini 1
\set fin 50000000
\set hoy '2026-10-01'
\set rs 'rs1000010'
\set simbolo 'GV00010'
\timing on

-- C1. Reporte clínico de un donante
-- Variantes con filtro PASS y profundidad >= 20 detectadas en cualquier muestra del donante, con anotación patogénica o probablemente patogénica, junto con el gen, la consecuencia y la condición. Une 7 tablas y filtra por un donante.
SELECT DISTINCT v.id_variante, v.rsid, v.id_cromosoma, v.posicion, g.genotipo,
       ge.simbolo AS gen, vg.consecuencia, c.nombre AS condicion, a.significancia
FROM muestra m
JOIN genotipo g           ON g.id_muestra   = m.id_muestra
JOIN variante v           ON v.id_variante  = g.id_variante
JOIN anotacion_clinica a  ON a.id_variante  = g.id_variante
JOIN condicion c          ON c.id_condicion = a.id_condicion
LEFT JOIN variante_gen vg ON vg.id_variante = v.id_variante
LEFT JOIN gen ge          ON ge.id_gen      = vg.id_gen
WHERE m.id_donante = :'donante'
  AND g.filtro = 'PASS' AND g.profundidad >= 20
  AND a.significancia IN ('PATOGENICA','PROBABLEMENTE_PATOGENICA')
ORDER BY v.id_cromosoma, v.posicion;

-- C2. Portadores por gen
-- Para cada gen, número de donantes distintos que portan al menos una variante patogénica y su porcentaje sobre el total de donantes secuenciados. Agregación con COUNT DISTINCT, subconsulta EXISTS y CTE.
WITH total AS (
    SELECT count(DISTINCT m.id_donante) AS n
    FROM muestra m JOIN muestra_corrida mc ON mc.id_muestra = m.id_muestra
), portadores AS (
    SELECT vg.id_gen, count(DISTINCT m.id_donante) AS n_portadores
    FROM genotipo g
    JOIN muestra m       ON m.id_muestra   = g.id_muestra
    JOIN variante_gen vg ON vg.id_variante = g.id_variante
    WHERE EXISTS (SELECT 1 FROM anotacion_clinica a
                  WHERE a.id_variante = g.id_variante AND a.significancia IN ('PATOGENICA','PROBABLEMENTE_PATOGENICA'))
    GROUP BY vg.id_gen
)
SELECT ge.simbolo, p.n_portadores,
       round(100.0 * p.n_portadores / t.n, 2) AS pct_donantes
FROM portadores p JOIN gen ge ON ge.id_gen = p.id_gen CROSS JOIN total t
ORDER BY p.n_portadores DESC, ge.simbolo;

-- C3. Variantes enriquecidas en la cohorte
-- Variantes observadas en al menos 10 donantes cuya frecuencia alélica en la cohorte supera 5 veces la frecuencia poblacional global (gnomAD). Cuenta los alelos por donante (1/1 aporta 2) para no contar dos veces las re-secuenciaciones.
WITH n AS (
    SELECT count(DISTINCT m.id_donante) AS n
    FROM muestra m JOIN muestra_corrida mc ON mc.id_muestra = m.id_muestra
), por_donante AS (
    SELECT g.id_variante, m.id_donante,
           max(CASE g.genotipo WHEN '1/1' THEN 2 ELSE 1 END) AS alelos
    FROM genotipo g JOIN muestra m ON m.id_muestra = g.id_muestra
    GROUP BY g.id_variante, m.id_donante
), f AS (
    SELECT id_variante, count(*) AS n_donantes, sum(alelos) AS alelos
    FROM por_donante GROUP BY id_variante HAVING count(*) >= 10
)
SELECT v.id_variante, v.rsid, v.id_cromosoma, v.posicion, f.n_donantes,
       round(f.alelos::numeric / (2 * n.n), 5)                       AS frec_cohorte,
       v.frec_poblacional,
       round(f.alelos::numeric / (2 * n.n) / v.frec_poblacional, 1)  AS veces
FROM f JOIN variante v ON v.id_variante = f.id_variante CROSS JOIN n
WHERE v.frec_poblacional > 0
  AND f.alelos::numeric / (2 * n.n) >= 5 * v.frec_poblacional
ORDER BY veces DESC;

-- C5. Consulta por región genómica
-- Variantes missense o de impacto ALTO en un rango de posiciones de un cromosoma, con el número de muestras germinales y tumorales en que aparecen. Filtro por rango, LEFT JOIN a las dos subclases y COUNT ... FILTER.
SELECT v.id_variante, v.rsid, v.posicion, v.alelo_ref, v.alelo_alt,
       ge.simbolo AS gen, vg.consecuencia, vg.impacto,
       count(DISTINCT g.id_muestra) FILTER (WHERE mg.id_muestra IS NOT NULL) AS germinales,
       count(DISTINCT g.id_muestra) FILTER (WHERE mt.id_muestra IS NOT NULL) AS tumorales
FROM variante v
JOIN variante_gen vg          ON vg.id_variante = v.id_variante
JOIN gen ge                   ON ge.id_gen      = vg.id_gen
JOIN genotipo g               ON g.id_variante  = v.id_variante
LEFT JOIN muestra_germinal mg ON mg.id_muestra  = g.id_muestra
LEFT JOIN muestra_tumoral  mt ON mt.id_muestra  = g.id_muestra
WHERE v.id_cromosoma = :'crom' AND v.posicion BETWEEN :ini AND :fin
  AND (vg.consecuencia = 'missense_variant' OR vg.impacto = 'ALTO')
GROUP BY v.id_variante, ge.simbolo, vg.consecuencia, vg.impacto
ORDER BY v.posicion;

-- C6. Concordancia técnica entre corridas
-- Muestras secuenciadas en más de una corrida: para cada par de corridas, variantes en común, cuántas tienen genotipo distinto y el porcentaje de discordancia. Self-join de la tabla más grande.
WITH reseq AS (
    SELECT id_muestra FROM muestra_corrida
    GROUP BY id_muestra HAVING count(*) > 1
)
SELECT g1.id_muestra, g1.id_corrida AS corrida_1, g2.id_corrida AS corrida_2,
       count(*)                                          AS variantes_comunes,
       count(*) FILTER (WHERE g1.genotipo <> g2.genotipo) AS discordantes,
       round(100.0 * count(*) FILTER (WHERE g1.genotipo <> g2.genotipo) / count(*), 2)
                                                         AS pct_discordancia
FROM reseq r
JOIN genotipo g1 ON g1.id_muestra = r.id_muestra
JOIN genotipo g2 ON g2.id_muestra = g1.id_muestra
                AND g2.id_variante = g1.id_variante
                AND g2.id_corrida  > g1.id_corrida
GROUP BY g1.id_muestra, g1.id_corrida, g2.id_corrida
ORDER BY pct_discordancia DESC, g1.id_muestra;

-- =====================================================================
-- Consultas adicionales del Hito 1 (no entran al experimento)
-- =====================================================================

-- C4. Control de calidad del último trimestre por laboratorio y secuenciador
SELECT l.nombre AS laboratorio, s.id_secuenciador,
       count(DISTINCT c.id_corrida)                                   AS corridas,
       round(avg(mc.cobertura_media), 1)                              AS cobertura_promedio,
       round(100.0 * avg((mc.cobertura_media < 30 OR mc.pct_q30 < 80)::int), 1)
                                                                      AS pct_muestras_deficientes
FROM laboratorio l
JOIN secuenciador s     ON s.id_laboratorio  = l.id_laboratorio
JOIN corrida c          ON c.id_secuenciador = s.id_secuenciador
JOIN muestra_corrida mc ON mc.id_corrida     = c.id_corrida
WHERE c.fecha_inicio >= :'hoy'::date - interval '3 months'
GROUP BY l.nombre, s.id_secuenciador
ORDER BY pct_muestras_deficientes DESC;

-- C7. Búsqueda puntual por identificador rs o por símbolo de gen
SELECT v.id_variante, v.rsid, v.id_cromosoma, v.posicion, v.alelo_ref, v.alelo_alt,
       v.tipo_variante, ge.simbolo, vg.consecuencia, a.significancia, a.estado_revision
FROM v_variante v
LEFT JOIN variante_gen vg     ON vg.id_variante = v.id_variante
LEFT JOIN gen ge              ON ge.id_gen      = vg.id_gen
LEFT JOIN anotacion_clinica a ON a.id_variante  = v.id_variante
WHERE v.rsid = :'rs' OR ge.simbolo = :'simbolo';

-- C8. Reevaluación: donantes con variantes reclasificadas de VUS a (probablemente)
--     patogénica DESPUÉS de su último informe
SELECT DISTINCT m.id_donante, v.rsid, a.id_anotacion, h.significancia_nueva,
       h.fecha_cambio, ult.ultimo_informe
FROM anotacion_historial h
JOIN anotacion_clinica a ON a.id_anotacion = h.id_anotacion
JOIN variante v          ON v.id_variante  = a.id_variante
JOIN genotipo g          ON g.id_variante  = a.id_variante
JOIN muestra m           ON m.id_muestra   = g.id_muestra
JOIN (SELECT id_donante, max(fecha_informe) AS ultimo_informe
      FROM informe GROUP BY id_donante) ult ON ult.id_donante = m.id_donante
WHERE h.significancia_anterior = 'VUS'
  AND h.significancia_nueva IN ('PATOGENICA','PROBABLEMENTE_PATOGENICA')
  AND h.fecha_cambio > ult.ultimo_informe
ORDER BY m.id_donante, h.fecha_cambio;
