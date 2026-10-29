-- =====================================================================
-- GenVar-PE · Hito 2 · 4.2 Carga de datos y 4.3 Simulación de datos faltantes
-- Genera un escenario completo con N filas en la tabla de hechos GENOTIPO.
-- Uso:  psql -d genvar -v N=1000000 -f 06_generar_datos.sql
-- Todo es reproducible (setseed). Las demás tablas escalan con N:
--   donantes = max(40, N/1000)       genes = entre 100 y 20 000 (N/50)
--   variantes = max(50, N/4)         condiciones = entre 50 y 2 000 (N/500)
-- Los cromosomas usan las longitudes reales del ensamblado GRCh38.
-- =====================================================================
\set ON_ERROR_STOP on
SET search_path TO genvar;
SET client_min_messages TO warning;

TRUNCATE cromosoma, gen, exon, variante, variante_gen, condicion, anotacion_clinica,
         donante, muestra, muestra_germinal, muestra_tumoral, laboratorio, secuenciador,
         corrida, muestra_corrida, genotipo, informe, anotacion_historial, bitacora,
         stg_genotipo RESTART IDENTITY CASCADE;

SELECT setseed(0.2026);

CREATE TEMP TABLE par AS
SELECT :N::bigint                                  AS n,
       greatest(40,  :N / 1000)::int               AS n_don,
       least(20000, greatest(100, :N / 50))::int   AS n_gen,
       greatest(50,  :N / 4)::int                  AS n_var,
       least(2000, greatest(50, :N / 500))::int    AS n_cond;

-- ---------- 1. Cromosomas (datos reales GRCh38) ----------
INSERT INTO cromosoma VALUES
('1',248956422,'AUTOSOMA'),('2',242193529,'AUTOSOMA'),('3',198295559,'AUTOSOMA'),
('4',190214555,'AUTOSOMA'),('5',181538259,'AUTOSOMA'),('6',170805979,'AUTOSOMA'),
('7',159345973,'AUTOSOMA'),('8',145138636,'AUTOSOMA'),('9',138394717,'AUTOSOMA'),
('10',133797422,'AUTOSOMA'),('11',135086622,'AUTOSOMA'),('12',133275309,'AUTOSOMA'),
('13',114364328,'AUTOSOMA'),('14',107043718,'AUTOSOMA'),('15',101991189,'AUTOSOMA'),
('16',90338345,'AUTOSOMA'),('17',83257441,'AUTOSOMA'),('18',80373285,'AUTOSOMA'),
('19',58617616,'AUTOSOMA'),('20',64444167,'AUTOSOMA'),('21',46709983,'AUTOSOMA'),
('22',50818468,'AUTOSOMA'),('X',156040895,'SEXUAL'),('Y',57227415,'SEXUAL'),
('MT',16569,'MITOCONDRIAL');

-- ---------- 2. Laboratorios y secuenciadores ----------
INSERT INTO laboratorio(nombre, ciudad, pais) VALUES
('CGA Sede Lima','Lima','Perú'),('CGA Sede Arequipa','Arequipa','Perú'),('CGA Sede Cusco','Cusco','Perú');

INSERT INTO secuenciador VALUES
('NS6K-LIM-001',1,'NovaSeq 6000','Illumina','LECTURA_CORTA'),
('NS6K-LIM-002',1,'NovaSeq 6000','Illumina','LECTURA_CORTA'),
('NX2K-LIM-003',1,'NextSeq 2000','Illumina','LECTURA_CORTA'),
('PROM-LIM-004',1,'PromethION 24','Oxford Nanopore','LECTURA_LARGA'),
('NX2K-AQP-001',2,'NextSeq 2000','Illumina','LECTURA_CORTA'),
('MISQ-AQP-002',2,'MiSeq','Illumina','LECTURA_CORTA'),
('REVO-AQP-003',2,'Revio','PacBio','LECTURA_LARGA'),
('NX2K-CUS-001',3,'NextSeq 2000','Illumina','LECTURA_CORTA'),
('MISQ-CUS-002',3,'MiSeq','Illumina','LECTURA_CORTA'),
('DNBS-CUS-003',3,'DNBSEQ-G400','MGI','LECTURA_CORTA');

-- ---------- 3. Genes y exones (sintéticos, coordenadas válidas en GRCh38) ----------
CREATE TEMP TABLE crom_peso AS
SELECT id_cromosoma, longitud_pb,
       sum(longitud_pb) OVER (ORDER BY id_cromosoma) * 1.0 / sum(longitud_pb) OVER () AS acum
FROM cromosoma WHERE id_cromosoma <> 'MT';

INSERT INTO gen
SELECT 'ENSG' || lpad(i::text, 11, '0'),
       'GV' || lpad(i::text, 5, '0'),
       'Gen sintético ' || i,
       CASE WHEN r < 0.60 THEN 'protein_coding' WHEN r < 0.85 THEN 'lncRNA'
            WHEN r < 0.95 THEN 'pseudogene' ELSE 'miRNA' END,
       c.id_cromosoma,
       ini, ini + largo, CASE WHEN random() < 0.5 THEN '+' ELSE '-' END
FROM (SELECT i, random() AS r, random() AS rc,
             (2000 + power(random(), 2) * 200000)::bigint AS largo
      FROM generate_series(1, (SELECT n_gen FROM par)) i) s
CROSS JOIN LATERAL (SELECT id_cromosoma, longitud_pb FROM crom_peso
                    WHERE acum >= s.rc ORDER BY acum LIMIT 1) c
CROSS JOIN LATERAL (SELECT 1 + (random() * (c.longitud_pb - s.largo - 1))::bigint AS ini) p;

INSERT INTO exon
SELECT g.id_gen, k,
       g.inicio + (k - 1) * ((g.fin - g.inicio) / e.n_ex),
       g.inicio + (k - 1) * ((g.fin - g.inicio) / e.n_ex)
                + least((g.fin - g.inicio) / e.n_ex - 1, 50 + (random() * 250)::int)
FROM gen g
CROSS JOIN LATERAL (SELECT 1 + (random() * 14)::int + 0 * length(g.id_gen) AS n_ex) e
CROSS JOIN LATERAL generate_series(1, e.n_ex) k;

-- ---------- 4. Variantes: 70 % dentro de un gen, 30 % intergénicas ----------
CREATE TEMP TABLE tv AS
SELECT i, ingen, g.id_gen, g.id_cromosoma AS crom_g, g.inicio, g.fin, rc, ra, rf, rcons
FROM (SELECT i, random() < 0.70 AS ingen,
             1 + (random() * ((SELECT n_gen FROM par) - 1))::int AS gi,
             random() AS rc, random() AS ra, random() AS rf, random() AS rcons
      FROM generate_series(1, (SELECT n_var FROM par)) i) s
JOIN (SELECT row_number() OVER (ORDER BY id_gen) AS gi, * FROM gen) g USING (gi);

CREATE TEMP TABLE tv2 AS
SELECT t.i, t.ingen, t.id_gen, t.rcons,
       CASE WHEN t.ingen THEN t.crom_g ELSE c.id_cromosoma END AS crom,
       CASE WHEN t.ingen THEN t.inicio + (random() * (t.fin - t.inicio))::bigint
            ELSE 1 + (random() * (c.longitud_pb - 10))::bigint END AS pos,
       b1, b2, t.ra, t.rf
FROM tv t
CROSS JOIN LATERAL (SELECT id_cromosoma, longitud_pb FROM crom_peso
                    WHERE acum >= t.rc ORDER BY acum LIMIT 1) c
CROSS JOIN LATERAL (SELECT substr('ACGT', 1 + floor(random() * 4)::int + 0 * t.i, 1) AS b1) x
CROSS JOIN LATERAL (SELECT substr(replace('ACGT', x.b1, ''), 1 + floor(random() * 3)::int + 0 * t.i, 1) AS b2) y;

INSERT INTO variante(id_variante, rsid, id_cromosoma, posicion, alelo_ref, alelo_alt, frec_poblacional)
SELECT i,
       CASE WHEN random() < 0.70 THEN 'rs' || (1000000 + i) END,
       crom, pos,
       CASE WHEN ra < 0.85 THEN b1                         -- SNV
            WHEN ra < 0.93 THEN b1 || b2 || b1             -- deleción
            WHEN ra < 0.99 THEN b1                         -- inserción
            ELSE b1 || b2 END,                             -- MNV
       CASE WHEN ra < 0.85 THEN b2
            WHEN ra < 0.93 THEN b1
            WHEN ra < 0.99 THEN b1 || b2 || b2
            ELSE b2 || b1 END,
       CASE WHEN rf < 0.90 THEN round(power(random(), 4)::numeric * 0.5, 7) END
FROM tv2
ON CONFLICT DO NOTHING;
SELECT setval('variante_id_variante_seq', (SELECT max(id_variante) FROM variante));

-- Efecto sobre el gen (solo variantes dentro de un gen)
INSERT INTO variante_gen
SELECT t.i, t.id_gen, x.cons, x.imp
FROM tv2 t
JOIN variante v ON v.id_variante = t.i
CROSS JOIN LATERAL (SELECT CASE
        WHEN t.rcons < 0.03 THEN 'stop_gained'           WHEN t.rcons < 0.05 THEN 'frameshift_variant'
        WHEN t.rcons < 0.08 THEN 'splice_acceptor_variant' WHEN t.rcons < 0.33 THEN 'missense_variant'
        WHEN t.rcons < 0.53 THEN 'synonymous_variant'    WHEN t.rcons < 0.60 THEN '3_prime_UTR_variant'
        WHEN t.rcons < 0.65 THEN '5_prime_UTR_variant'   ELSE 'intron_variant' END AS cons) c0
CROSS JOIN LATERAL (SELECT c0.cons, CASE
        WHEN c0.cons IN ('stop_gained','frameshift_variant','splice_acceptor_variant') THEN 'ALTO'
        WHEN c0.cons = 'missense_variant'   THEN 'MODERADO'
        WHEN c0.cons = 'synonymous_variant' THEN 'BAJO'
        ELSE 'MODIFICADOR' END AS imp) x
WHERE t.ingen;

-- ---------- 5. Condiciones y anotaciones clínicas ----------
INSERT INTO condicion
SELECT 'MONDO:' || lpad((1000 + i)::text, 7, '0'),
       (ARRAY['Cáncer de mama y ovario hereditario','Síndrome de Lynch','Miocardiopatía hipertrófica',
              'Hipercolesterolemia familiar','Fibrosis quística','Atrofia muscular espinal',
              'Síndrome de QT largo','Distrofia muscular','Retinitis pigmentosa',
              'Sordera no sindrómica','Epilepsia infantil','Anemia hereditaria'])[1 + (i % 12)]
         || ' tipo ' || (1 + i / 12),
       (ARRAY['Autosómica dominante','Autosómica recesiva','Ligada al X','Mitocondrial'])
         [1 + floor(random() * 4)::int]
FROM generate_series(1, (SELECT n_cond FROM par)) i;

CREATE TEMP TABLE cand_anot AS
SELECT v.id_variante, COALESCE(vg.impacto, 'INTERGENICA') AS imp, random() AS rs
FROM variante v LEFT JOIN variante_gen vg USING (id_variante)
WHERE random() < CASE COALESCE(vg.impacto, 'INTERGENICA')
                   WHEN 'ALTO' THEN 0.80 WHEN 'MODERADO' THEN 0.50
                   WHEN 'INTERGENICA' THEN 0.05 ELSE 0.25 END;

INSERT INTO anotacion_clinica
SELECT 'SCV' || lpad(row_number() OVER ()::text, 9, '0'),
       id_variante,
       'MONDO:' || lpad((1001 + (random() * ((SELECT n_cond FROM par) - 1))::int)::text, 7, '0'),
       CASE
         WHEN imp = 'ALTO' THEN CASE WHEN rs < .45 THEN 'PATOGENICA' WHEN rs < .70 THEN 'PROBABLEMENTE_PATOGENICA'
                                     WHEN rs < .95 THEN 'VUS' WHEN rs < .98 THEN 'PROBABLEMENTE_BENIGNA' ELSE 'BENIGNA' END
         WHEN imp = 'MODERADO' THEN CASE WHEN rs < .08 THEN 'PATOGENICA' WHEN rs < .18 THEN 'PROBABLEMENTE_PATOGENICA'
                                     WHEN rs < .70 THEN 'VUS' WHEN rs < .85 THEN 'PROBABLEMENTE_BENIGNA' ELSE 'BENIGNA' END
         ELSE CASE WHEN rs < .01 THEN 'PATOGENICA' WHEN rs < .03 THEN 'PROBABLEMENTE_PATOGENICA'
                   WHEN rs < .30 THEN 'VUS' WHEN rs < .60 THEN 'PROBABLEMENTE_BENIGNA' ELSE 'BENIGNA' END
       END,
       (random() * 4)::int,
       DATE '2015-01-01' + (random() * 3650)::int
FROM (SELECT id_variante, imp, rs FROM cand_anot
      UNION ALL   -- 15 % recibe una segunda evaluación de otro remitente
      SELECT id_variante, imp, random() FROM cand_anot WHERE random() < 0.15) a;

-- ---------- 6. Donantes, muestras y subclases ----------
INSERT INTO donante
SELECT 'CGA-D' || lpad(i::text, 6, '0'),
       CASE WHEN r < 0.52 THEN 'F' WHEN r < 0.99 THEN 'M' ELSE 'X' END,
       1940 + (random() * 65)::int,
       (ARRAY['Mestiza (Lima)','Quechua','Aymara','Amazónica','Afroperuana','Mestiza (Arequipa)'])
         [1 + floor(random() * 6)::int],
       random() < 0.97
FROM (SELECT i, random() AS r FROM generate_series(1, (SELECT n_don FROM par)) i) s;

-- Muestra y subclase en la MISMA transacción: el trigger diferido de cobertura
-- total (T5) se revisa al COMMIT.
BEGIN;
CREATE TEMP TABLE tm AS
SELECT 'CGA-M' || lpad(row_number() OVER (ORDER BY d.id_donante, t.tipo)::text, 7, '0') AS id_muestra,
       d.id_donante, t.tipo,
       DATE '2023-01-01' + (random() * 1338)::int AS fecha_colecta    -- hasta 2026-08-31
FROM donante d
CROSS JOIN LATERAL (SELECT 'GERMINAL' AS tipo WHERE random() + 0 * length(d.id_donante) < 0.95
                    UNION ALL SELECT 'TUMORAL' WHERE random() + 0 * length(d.id_donante) < 0.30) t
WHERE d.consentimiento;

INSERT INTO muestra
SELECT id_muestra, id_donante, fecha_colecta, round((5 + random() * 95)::numeric, 2), 'RECIBIDA' FROM tm;
INSERT INTO muestra_germinal
SELECT id_muestra, (ARRAY['SANGRE','SALIVA','HISOPADO_BUCAL'])[1 + floor(random() * 3)::int]
FROM tm WHERE tipo = 'GERMINAL';
INSERT INTO muestra_tumoral
SELECT id_muestra,
       (ARRAY['Carcinoma ductal de mama','Adenocarcinoma de colon','Adenocarcinoma gástrico',
              'Carcinoma de pulmón','Melanoma'])[1 + floor(random() * 5)::int],
       (ARRAY['I','II','III','IV'])[1 + floor(random() * 4)::int],
       round((20 + random() * 75)::numeric, 2)
FROM tm WHERE tipo = 'TUMORAL';
COMMIT;

-- ---------- 7. Corridas y muestra_corrida ----------
-- 95 % de las muestras se secuencian. Se ordenan por fecha de colecta y se
-- agrupan de a 12 por corrida; la corrida empieza después de la última colecta
-- del grupo (así se cumple RS9).
CREATE TEMP TABLE ts AS
SELECT id_muestra, fecha_colecta,
       (row_number() OVER (ORDER BY fecha_colecta, id_muestra) - 1) / 12 AS grupo
FROM muestra WHERE random() < 0.95;

CREATE TEMP TABLE tc AS
SELECT grupo,
       'RUN-' || lpad((grupo + 1)::text, 5, '0') AS id_corrida,
       max(fecha_colecta) + (3 + random() * 17)::int + time '08:00' AS fecha_inicio,
       random() AS rt, random() AS rsq
FROM ts GROUP BY grupo;

INSERT INTO corrida
SELECT id_corrida,
       (ARRAY['NS6K-LIM-001','NS6K-LIM-002','NX2K-LIM-003','PROM-LIM-004','NX2K-AQP-001',
              'MISQ-AQP-002','REVO-AQP-003','NX2K-CUS-001','MISQ-CUS-002','DNBS-CUS-003'])
         [1 + floor(rsq * 10)::int],
       CASE WHEN rt < 0.60 THEN 'WES' WHEN rt < 0.90 THEN 'PANEL' ELSE 'WGS' END,
       fecha_inicio,
       fecha_inicio + interval '1 day' * (1 + random() * 2),
       'COMPLETADA',
       round((50 + random() * 900)::numeric, 2)
FROM tc;

-- Cobertura por tipo de ensayo; ~8 % con cobertura < 30x y ~6 % con Q30 < 80 %
INSERT INTO muestra_corrida
SELECT s.id_muestra, c.id_corrida,
       'BC' || lpad(row_number() OVER (PARTITION BY c.id_corrida ORDER BY s.id_muestra)::text, 3, '0'),
       (20000000 + random() * 80000000)::bigint,
       round(CASE WHEN random() < 0.08 THEN 10 + random() * 19
                  WHEN co.tipo_ensayo = 'PANEL' THEN 200 + random() * 300
                  WHEN co.tipo_ensayo = 'WES'   THEN 50 + random() * 70
                  ELSE 30 + random() * 15 END::numeric, 2),
       round(CASE WHEN random() < 0.06 THEN 65 + random() * 14 ELSE 82 + random() * 14 END::numeric, 2)
FROM ts s JOIN tc c USING (grupo) JOIN corrida co USING (id_corrida);

-- 10 % de las muestras se re-secuencian en una corrida posterior (alimenta C6)
INSERT INTO muestra_corrida
SELECT s.id_muestra, c2.id_corrida,
       'BR' || lpad(row_number() OVER (PARTITION BY c2.id_corrida ORDER BY s.id_muestra)::text, 3, '0'),
       (20000000 + random() * 80000000)::bigint,
       round((40 + random() * 60)::numeric, 2),
       round((84 + random() * 12)::numeric, 2)
FROM (SELECT * FROM ts
      WHERE grupo < (SELECT max(grupo) FROM ts)                -- tiene corrida posterior
      ORDER BY random()
      LIMIT greatest(3, (SELECT count(*) FROM ts) / 10)) s       -- 10 %, mínimo 3
JOIN tc c2 ON c2.grupo = least(s.grupo + 1 + floor(random() * 3)::int,
                               (SELECT max(grupo) FROM ts));

UPDATE muestra SET estado = 'SECUENCIADA'
WHERE id_muestra IN (SELECT id_muestra FROM muestra_corrida);
UPDATE muestra SET estado = 'DESCARTADA'
WHERE estado = 'RECIBIDA' AND random() < 0.3;

-- ---------- 8. Genotipos (tabla de hechos: exactamente N filas) ----------
-- La variante se elige con sesgo: power(random(), 2.5) concentra la elección en
-- pocas variantes "comunes" y deja la mayoría raras, como en un exoma real.
CREATE TEMP TABLE prim AS
SELECT DISTINCT ON (id_muestra) id_muestra, id_corrida
FROM muestra_corrida ORDER BY id_muestra, id_corrida;

CREATE TEMP TABLE cand AS
SELECT DISTINCT ON (id_muestra, id_corrida, vid) id_muestra, id_corrida, vid, false AS reseq
FROM (SELECT p.id_muestra, p.id_corrida,
             1 + floor(mx.m * power(random(), 2.5))::bigint AS vid   -- random() en la lista
      FROM prim p                                                    -- de SELECT: uno por fila
      CROSS JOIN (SELECT max(id_variante) AS m FROM variante) mx
      CROSS JOIN LATERAL generate_series(1, ceil((SELECT n FROM par) * 1.6
                   / (SELECT count(*) FROM prim)
                   * (0.6 + random() * 0.8 + 0 * hashtext(p.id_muestra)))::int) k) s;
DELETE FROM cand c WHERE NOT EXISTS (SELECT 1 FROM variante v WHERE v.id_variante = c.vid);

-- Re-secuenciación: copia 93 % de los genotipos de la corrida original
INSERT INTO cand
SELECT mc.id_muestra, mc.id_corrida, c.vid, true
FROM muestra_corrida mc
JOIN prim p ON p.id_muestra = mc.id_muestra AND p.id_corrida <> mc.id_corrida
JOIN cand c ON c.id_muestra = p.id_muestra AND c.id_corrida = p.id_corrida
WHERE random() < 0.93;

INSERT INTO genotipo
SELECT c.id_muestra, c.id_corrida, c.vid,
       CASE WHEN rg < 0.25 THEN '1/1' ELSE '0/1' END,
       dp,
       round((CASE WHEN random() < 0.05 THEN random() * 20 ELSE 30 + random() * 70 END)::numeric, 1),
       round((CASE WHEN tu.id_muestra IS NOT NULL THEN 0.05 + random() * 0.45
                   WHEN rg < 0.25 THEN 0.90 + random() * 0.10
                   ELSE 0.35 + random() * 0.30 END)::numeric, 3),
       CASE WHEN dp < 10 THEN 'LowDP' WHEN random() < 0.05 THEN 'LowQual' ELSE 'PASS' END
FROM (SELECT * FROM cand ORDER BY reseq DESC, random() LIMIT (SELECT n FROM par)) c
JOIN muestra_corrida mc USING (id_muestra, id_corrida)
LEFT JOIN muestra_tumoral tu USING (id_muestra)
CROSS JOIN LATERAL (SELECT random() AS rg,
                           greatest(1, (mc.cobertura_media * (0.3 + random() * 0.9))::int) AS dp) z;

-- En la re-secuenciación, 3 % de los genotipos difiere (discordancia técnica para C6)
UPDATE genotipo g SET genotipo = CASE g.genotipo WHEN '0/1' THEN '1/1' ELSE '0/1' END
FROM muestra_corrida mc
WHERE mc.id_muestra = g.id_muestra AND mc.id_corrida = g.id_corrida
  AND mc.barcode LIKE 'BR%' AND random() < 0.03;

-- ---------- 9. Informes y reclasificaciones (alimentan C8) ----------
INSERT INTO informe(id_donante, fecha_informe, genetista)
SELECT DISTINCT m.id_donante,
       DATE '2024-01-01' + (random() * 700)::int,
       (ARRAY['Dra. Quispe','Dr. Huamán','Dra. Rojas'])[1 + floor(random() * 3)::int]
FROM muestra m JOIN muestra_corrida mc USING (id_muestra)
WHERE random() < 0.40;

-- 3 % de las VUS se reclasifican; el trigger T8 guarda cada cambio en el historial
UPDATE anotacion_clinica
   SET significancia = CASE WHEN random() < 0.5 THEN 'PATOGENICA' ELSE 'PROBABLEMENTE_PATOGENICA' END,
       fecha_evaluacion = DATE '2025-01-01' + (random() * 630)::int
 WHERE significancia = 'VUS' AND random() < 0.03;

VACUUM ANALYZE;   -- VACUUM marca las páginas como visibles: habilita Index Only Scan

SELECT 'genotipo' AS tabla, count(*) FROM genotipo UNION ALL
SELECT 'variante', count(*) FROM variante UNION ALL
SELECT 'variante_gen', count(*) FROM variante_gen UNION ALL
SELECT 'anotacion_clinica', count(*) FROM anotacion_clinica UNION ALL
SELECT 'gen', count(*) FROM gen UNION ALL
SELECT 'exon', count(*) FROM exon UNION ALL
SELECT 'condicion', count(*) FROM condicion UNION ALL
SELECT 'donante', count(*) FROM donante UNION ALL
SELECT 'muestra', count(*) FROM muestra UNION ALL
SELECT 'corrida', count(*) FROM corrida UNION ALL
SELECT 'muestra_corrida', count(*) FROM muestra_corrida UNION ALL
SELECT 'informe', count(*) FROM informe UNION ALL
SELECT 'anotacion_historial', count(*) FROM anotacion_historial;
