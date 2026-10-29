-- =====================================================================
-- GenVar-PE · Hito 2 · 4.5 Procedimientos almacenados y funciones
-- =====================================================================
SET search_path TO genvar;

-- (1) Registrar una muestra junto con su subclase en una sola transacción.
--     Garantiza la cobertura total de la jerarquía Is-A (RS3): no puede
--     quedar una muestra sin tipo.
CREATE OR REPLACE PROCEDURE sp_registrar_muestra(
    p_id_muestra VARCHAR, p_id_donante VARCHAR, p_fecha DATE, p_conc NUMERIC,
    p_tipo VARCHAR,                      -- 'GERMINAL' o 'TUMORAL'
    p_fuente VARCHAR DEFAULT NULL,       -- solo germinal
    p_tipo_tumor VARCHAR DEFAULT NULL, p_estadio VARCHAR DEFAULT NULL,
    p_pureza NUMERIC DEFAULT NULL)       -- solo tumoral
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO muestra(id_muestra, id_donante, fecha_colecta, conc_adn, estado)
    VALUES (p_id_muestra, p_id_donante, p_fecha, p_conc, 'RECIBIDA');

    IF p_tipo = 'GERMINAL' THEN
        INSERT INTO muestra_germinal VALUES (p_id_muestra, p_fuente);
    ELSIF p_tipo = 'TUMORAL' THEN
        INSERT INTO muestra_tumoral VALUES (p_id_muestra, p_tipo_tumor, p_estadio, p_pureza);
    ELSE
        RAISE EXCEPTION 'Tipo de muestra inválido: % (use GERMINAL o TUMORAL)', p_tipo;
    END IF;
END $$;

-- (2) Carga de genotipos de una corrida desde la tabla de staging
--     (el bioinformático hace COPY del VCF normalizado a stg_genotipo).
--     a) inserta en el catálogo solo las variantes nuevas (RS13: una sola vez);
--     b) inserta los genotipos; la FK compuesta rechaza muestras que no
--        estén registradas en esa corrida (RS19);
--     c) deja constancia en la bitácora.
CREATE TABLE IF NOT EXISTS stg_genotipo (
    id_muestra   VARCHAR(14), id_corrida VARCHAR(30),
    id_cromosoma VARCHAR(2),  posicion   BIGINT,
    alelo_ref    VARCHAR(50), alelo_alt  VARCHAR(50), rsid VARCHAR(15),
    genotipo     VARCHAR(3),  profundidad INTEGER, calidad REAL,
    vaf          NUMERIC(4,3), filtro    VARCHAR(20)
);

CREATE OR REPLACE PROCEDURE sp_cargar_genotipos(p_id_corrida VARCHAR)
LANGUAGE plpgsql AS $$
DECLARE
    n_var BIGINT; n_gen BIGINT;
BEGIN
    INSERT INTO variante(rsid, id_cromosoma, posicion, alelo_ref, alelo_alt)
    SELECT DISTINCT ON (s.id_cromosoma, s.posicion, s.alelo_ref, s.alelo_alt)
           s.rsid, s.id_cromosoma, s.posicion, s.alelo_ref, s.alelo_alt
    FROM stg_genotipo s
    WHERE s.id_corrida = p_id_corrida
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS n_var = ROW_COUNT;

    INSERT INTO genotipo(id_muestra, id_corrida, id_variante, genotipo,
                         profundidad, calidad, vaf, filtro)
    SELECT s.id_muestra, s.id_corrida, v.id_variante, s.genotipo,
           s.profundidad, s.calidad, s.vaf, s.filtro
    FROM stg_genotipo s
    JOIN variante v ON v.id_cromosoma = s.id_cromosoma AND v.posicion = s.posicion
                   AND v.alelo_ref = s.alelo_ref AND v.alelo_alt = s.alelo_alt
    WHERE s.id_corrida = p_id_corrida;
    GET DIAGNOSTICS n_gen = ROW_COUNT;

    DELETE FROM stg_genotipo WHERE id_corrida = p_id_corrida;
    INSERT INTO bitacora(evento, detalle)
    VALUES ('CARGA_GENOTIPOS', format('corrida %s: %s variantes nuevas, %s genotipos',
                                      p_id_corrida, n_var, n_gen));
END $$;

-- (3) Reclasificar una anotación clínica (recarga mensual de ClinVar).
--     El trigger trg_anotacion_historial guarda el cambio.
CREATE OR REPLACE PROCEDURE sp_reclasificar_anotacion(
    p_id_anotacion VARCHAR, p_nueva VARCHAR, p_fecha DATE DEFAULT CURRENT_DATE)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE anotacion_clinica
       SET significancia = p_nueva, fecha_evaluacion = p_fecha
     WHERE id_anotacion = p_id_anotacion;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe la anotación %', p_id_anotacion;
    END IF;
END $$;

-- (4) Revocación de consentimiento (RS23): borra en cascada las muestras,
--     sus participaciones en corridas y sus genotipos, y lo registra.
CREATE OR REPLACE PROCEDURE sp_revocar_consentimiento(p_id_donante VARCHAR)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE donante SET consentimiento = FALSE WHERE id_donante = p_id_donante;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe el donante %', p_id_donante;
    END IF;
    -- el borrado en cascada lo hace el trigger trg_donante_revoca
END $$;

-- (5) Función: reporte clínico de un donante (C1 encapsulada para el genetista).
CREATE OR REPLACE FUNCTION fn_reporte_clinico(p_id_donante VARCHAR)
RETURNS TABLE (id_variante BIGINT, rsid VARCHAR, cromosoma VARCHAR, posicion BIGINT,
               genotipo VARCHAR, gen VARCHAR, consecuencia VARCHAR,
               condicion VARCHAR, significancia VARCHAR)
LANGUAGE sql STABLE AS $$
    SELECT DISTINCT r.id_variante, r.rsid, r.id_cromosoma, r.posicion, r.genotipo,
           r.gen, r.consecuencia, r.condicion, r.significancia
    FROM v_reporte_clinico r
    WHERE r.id_donante = p_id_donante
    ORDER BY r.id_cromosoma, r.posicion;
$$;
