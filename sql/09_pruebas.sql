-- =====================================================================
-- GenVar-PE · Hito 2 · Pruebas de las reglas de negocio
-- Cada bloque muestra que el trigger o procedimiento hace lo que debe.
-- Los casos que deben fallar se ejecutan dentro de un bloque que captura el
-- error y lo imprime, para que el script corra completo.
-- Uso: psql -d genvar -f 09_pruebas.sql
-- =====================================================================
SET search_path TO genvar;
\pset footer off

-- Prueba 1 (T3, RS4): registrar una muestra de un donante SIN consentimiento -> error
INSERT INTO donante VALUES ('CGA-DTEST01','F',1990,'Quechua',FALSE);
DO $$ BEGIN
  CALL sp_registrar_muestra('CGA-MTEST001','CGA-DTEST01','2026-09-01',20,'GERMINAL','SANGRE');
  RAISE NOTICE 'Prueba 1: NO debió insertarse';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Prueba 1 OK -> %', SQLERRM; END $$;

-- Prueba 2 (procedimiento 1): registrar una muestra germinal válida
UPDATE donante SET consentimiento = TRUE WHERE id_donante = 'CGA-DTEST01';
CALL sp_registrar_muestra('CGA-MTEST001','CGA-DTEST01','2026-09-01',20,'GERMINAL','SANGRE');
SELECT m.id_muestra, m.estado, g.fuente FROM muestra m JOIN muestra_germinal g USING (id_muestra)
WHERE id_muestra = 'CGA-MTEST001';

-- Prueba 3 (T4, disjunta): la misma muestra no puede ser también tumoral -> error
DO $$ BEGIN
  INSERT INTO muestra_tumoral VALUES ('CGA-MTEST001','Melanoma','II',50);
  RAISE NOTICE 'Prueba 3: NO debió insertarse';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Prueba 3 OK -> %', SQLERRM; END $$;

-- Prueba 4 (T5, cobertura total): una muestra sin subclase se rechaza al COMMIT
DO $$ BEGIN
  INSERT INTO muestra VALUES ('CGA-MTEST002','CGA-DTEST01','2026-09-01',15,'RECIBIDA');
  SET CONSTRAINTS trg_muestra_cobertura_total IMMEDIATE;   -- fuerza la revisión ahora
  RAISE NOTICE 'Prueba 4: NO debió aceptarse';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Prueba 4 OK -> %', SQLERRM; END $$;

-- Prueba 5 (T6, RS9): la colecta no puede ser posterior al inicio de la corrida -> error
INSERT INTO corrida VALUES ('RUN-TEST1','NS6K-LIM-001','WES','2026-08-15 08:00',NULL,'EN_CURSO',0);
DO $$ BEGIN
  INSERT INTO muestra_corrida VALUES ('CGA-MTEST001','RUN-TEST1','BC001',0,0,0);
  RAISE NOTICE 'Prueba 5: NO debió insertarse';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Prueba 5 OK -> %', SQLERRM; END $$;

-- Prueba 6 (T7): una corrida sin muestras no puede completarse -> error
DO $$ BEGIN
  UPDATE corrida SET estado = 'COMPLETADA' WHERE id_corrida = 'RUN-TEST1';
  RAISE NOTICE 'Prueba 6: NO debió completarse';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Prueba 6 OK -> %', SQLERRM; END $$;

-- Prueba 7 (T6 y T7, automatización de estados) y procedimiento 2 (carga de genotipos)
INSERT INTO corrida VALUES ('RUN-TEST2','NS6K-LIM-001','WES','2026-09-10 08:00',NULL,'EN_CURSO',0);
INSERT INTO muestra_corrida VALUES ('CGA-MTEST001','RUN-TEST2','BC001',50000000,85.5,91.2);
SELECT id_muestra, estado AS estado_tras_entrar_a_corrida FROM muestra WHERE id_muestra = 'CGA-MTEST001';
INSERT INTO stg_genotipo VALUES
 ('CGA-MTEST001','RUN-TEST2','17',43045712,'G','A',NULL,'0/1',55,99,0.48,'PASS'),
 ('CGA-MTEST001','RUN-TEST2','17',43045713,'C','T',NULL,'1/1',60,99,0.97,'PASS');
CALL sp_cargar_genotipos('RUN-TEST2');
SELECT evento, detalle FROM bitacora ORDER BY id_evento DESC LIMIT 1;
UPDATE corrida SET estado = 'COMPLETADA' WHERE id_corrida = 'RUN-TEST2';
SELECT c.estado AS corrida, c.fecha_fin IS NOT NULL AS tiene_fecha_fin, m.estado AS muestra
FROM corrida c, muestra m WHERE c.id_corrida = 'RUN-TEST2' AND m.id_muestra = 'CGA-MTEST001';

-- Prueba 8 (RS19 por FK compuesta): genotipo de una muestra que no está en esa corrida -> error
DO $$ BEGIN
  INSERT INTO genotipo VALUES ('CGA-MTEST001','RUN-TEST1',1,'0/1',30,50,0.5,'PASS');
  RAISE NOTICE 'Prueba 8: NO debió insertarse';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Prueba 8 OK -> %', SQLERRM; END $$;

-- Prueba 9 (procedimiento 3 y T8): reclasificar una VUS deja historial
SELECT id_anotacion AS anot_vus FROM anotacion_clinica WHERE significancia = 'VUS'
ORDER BY id_anotacion LIMIT 1 \gset
CALL sp_reclasificar_anotacion(:'anot_vus', 'PATOGENICA', '2026-09-30');
SELECT id_anotacion, significancia_anterior, significancia_nueva, fecha_cambio
FROM anotacion_historial WHERE id_anotacion = :'anot_vus';

-- Prueba 10 (función): reporte clínico del donante con más hallazgos
SELECT m.id_donante AS don FROM v_reporte_clinico m
GROUP BY 1 ORDER BY count(*) DESC, 1 LIMIT 1 \gset
SELECT * FROM fn_reporte_clinico(:'don') LIMIT 5;

-- Prueba 11 (procedimiento 4 y T9): revocar el consentimiento borra en cascada
SELECT count(*) AS genotipos_antes FROM genotipo WHERE id_muestra = 'CGA-MTEST001';
CALL sp_revocar_consentimiento('CGA-DTEST01');
SELECT count(*) AS muestras_despues  FROM muestra  WHERE id_donante = 'CGA-DTEST01';
SELECT count(*) AS genotipos_despues FROM genotipo WHERE id_muestra = 'CGA-MTEST001';
SELECT evento, detalle FROM bitacora ORDER BY id_evento DESC LIMIT 1;

-- Prueba 12 (vista con atributo derivado)
SELECT tipo_variante, count(*) FROM v_variante GROUP BY 1 ORDER BY 2 DESC;

-- Limpieza de los datos de prueba
DELETE FROM donante WHERE id_donante = 'CGA-DTEST01';
DELETE FROM corrida WHERE id_corrida IN ('RUN-TEST1','RUN-TEST2');
UPDATE anotacion_clinica SET significancia = 'VUS' WHERE id_anotacion = :'anot_vus';
DELETE FROM anotacion_historial WHERE id_anotacion = :'anot_vus';
DELETE FROM variante WHERE id_cromosoma = '17' AND posicion IN (43045712, 43045713)
  AND id_variante NOT IN (SELECT id_variante FROM genotipo);
