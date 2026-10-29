-- =====================================================================
-- GenVar-PE · Hito 2 · Roles por tipo de usuario (Sección 1.5.3 del Hito 1)
-- Ejecutar como superusuario. Los roles son NOLOGIN: a cada persona se le
-- crea su usuario y se le asigna el rol (GRANT genetista TO ana;).
-- =====================================================================
SET search_path TO genvar;

DO $$
DECLARE r TEXT;
BEGIN
    FOREACH r IN ARRAY ARRAY['tecnico_lab','bioinformatico','genetista','investigador','auditor']
    LOOP
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = r) THEN
            EXECUTE format('CREATE ROLE %I NOLOGIN', r);
        END IF;
        EXECUTE format('GRANT USAGE ON SCHEMA genvar TO %I', r);
    END LOOP;
END $$;

-- Técnico de laboratorio: registra donantes, muestras y corridas. No ve genotipos.
GRANT SELECT, INSERT, UPDATE ON donante, muestra, muestra_germinal, muestra_tumoral,
      corrida, muestra_corrida, laboratorio, secuenciador TO tecnico_lab;
GRANT EXECUTE ON PROCEDURE sp_registrar_muestra TO tecnico_lab;

-- Bioinformático: carga genotipos y catálogos de referencia.
GRANT SELECT, INSERT, UPDATE, DELETE ON cromosoma, gen, exon, variante, variante_gen,
      condicion, anotacion_clinica, genotipo, stg_genotipo, muestra_corrida TO bioinformatico;
GRANT SELECT ON muestra, corrida TO bioinformatico;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA genvar TO bioinformatico;
GRANT EXECUTE ON PROCEDURE sp_cargar_genotipos, sp_reclasificar_anotacion TO bioinformatico;

-- Genetista clínico: solo lectura de reportes y anotaciones.
GRANT SELECT ON v_reporte_clinico, v_variante, anotacion_clinica, condicion, gen TO genetista;
GRANT EXECUTE ON FUNCTION fn_reporte_clinico TO genetista;

-- Investigador: solo vistas agregadas, nunca filas de un donante.
GRANT SELECT ON v_frecuencia_cohorte, v_variante, gen, condicion TO investigador;

-- Auditor / comité de ética: trazabilidad, consentimientos y bitácoras.
GRANT SELECT ON v_trazabilidad, donante, bitacora, anotacion_historial, informe TO auditor;
