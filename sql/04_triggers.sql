-- =====================================================================
-- GenVar-PE · Hito 2 · 4.6 Triggers (reglas de negocio que un CHECK no puede
-- expresar porque miran otra tabla, y automatizaciones)
-- =====================================================================
SET search_path TO genvar;

-- T1 (RS11) El gen debe terminar dentro de su cromosoma.
CREATE OR REPLACE FUNCTION fn_gen_dentro_cromosoma() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.fin > (SELECT longitud_pb FROM cromosoma WHERE id_cromosoma = NEW.id_cromosoma) THEN
        RAISE EXCEPTION 'El gen % termina en % y supera la longitud del cromosoma %',
                        NEW.id_gen, NEW.fin, NEW.id_cromosoma;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_gen_dentro_cromosoma BEFORE INSERT OR UPDATE ON gen
FOR EACH ROW EXECUTE FUNCTION fn_gen_dentro_cromosoma();

-- T2 (RS12) Las coordenadas del exón deben estar dentro de las de su gen.
CREATE OR REPLACE FUNCTION fn_exon_dentro_gen() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE g gen%ROWTYPE;
BEGIN
    SELECT * INTO g FROM gen WHERE id_gen = NEW.id_gen;
    IF NEW.inicio < g.inicio OR NEW.fin > g.fin THEN
        RAISE EXCEPTION 'El exón % del gen % está fuera del gen [% - %]',
                        NEW.numero_exon, NEW.id_gen, g.inicio, g.fin;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_exon_dentro_gen BEFORE INSERT OR UPDATE ON exon
FOR EACH ROW EXECUTE FUNCTION fn_exon_dentro_gen();

-- T3 (RS4) Solo se registran muestras de donantes con consentimiento firmado.
CREATE OR REPLACE FUNCTION fn_muestra_consentimiento() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT (SELECT consentimiento FROM donante WHERE id_donante = NEW.id_donante) THEN
        RAISE EXCEPTION 'El donante % no tiene consentimiento informado', NEW.id_donante;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_muestra_consentimiento BEFORE INSERT ON muestra
FOR EACH ROW EXECUTE FUNCTION fn_muestra_consentimiento();

-- T4 (RS3, disjunta) Una muestra no puede ser germinal y tumoral a la vez.
CREATE OR REPLACE FUNCTION fn_subclase_disjunta() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_TABLE_NAME = 'muestra_germinal'
       AND EXISTS (SELECT 1 FROM muestra_tumoral WHERE id_muestra = NEW.id_muestra) THEN
        RAISE EXCEPTION 'La muestra % ya es tumoral', NEW.id_muestra;
    ELSIF TG_TABLE_NAME = 'muestra_tumoral'
       AND EXISTS (SELECT 1 FROM muestra_germinal WHERE id_muestra = NEW.id_muestra) THEN
        RAISE EXCEPTION 'La muestra % ya es germinal', NEW.id_muestra;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_germinal_disjunta BEFORE INSERT ON muestra_germinal
FOR EACH ROW EXECUTE FUNCTION fn_subclase_disjunta();
CREATE TRIGGER trg_tumoral_disjunta BEFORE INSERT ON muestra_tumoral
FOR EACH ROW EXECUTE FUNCTION fn_subclase_disjunta();

-- T5 (RS3, total) Al confirmar la transacción, toda muestra debe tener subclase.
--     Es un CONSTRAINT TRIGGER diferido: se revisa en el COMMIT, así la muestra
--     y su subclase se pueden insertar en dos sentencias seguidas.
CREATE OR REPLACE FUNCTION fn_muestra_cobertura_total() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM muestra WHERE id_muestra = NEW.id_muestra)
       AND NOT EXISTS (SELECT 1 FROM muestra_germinal WHERE id_muestra = NEW.id_muestra)
       AND NOT EXISTS (SELECT 1 FROM muestra_tumoral  WHERE id_muestra = NEW.id_muestra) THEN
        RAISE EXCEPTION 'La muestra % no es germinal ni tumoral', NEW.id_muestra;
    END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER trg_muestra_cobertura_total AFTER INSERT ON muestra
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION fn_muestra_cobertura_total();

-- T6 (RS9) La colecta no puede ser posterior al inicio de la corrida.
--     Automatización: la muestra pasa de RECIBIDA a EN_PROCESO al entrar a una corrida.
CREATE OR REPLACE FUNCTION fn_muestra_corrida_fechas() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE f_colecta DATE; f_inicio TIMESTAMP;
BEGIN
    SELECT fecha_colecta INTO f_colecta FROM muestra WHERE id_muestra = NEW.id_muestra;
    SELECT fecha_inicio  INTO f_inicio  FROM corrida WHERE id_corrida = NEW.id_corrida;
    IF f_colecta > f_inicio::date THEN
        RAISE EXCEPTION 'La muestra % se colectó (%) después del inicio de la corrida % (%)',
                        NEW.id_muestra, f_colecta, NEW.id_corrida, f_inicio::date;
    END IF;
    UPDATE muestra SET estado = 'EN_PROCESO'
     WHERE id_muestra = NEW.id_muestra AND estado = 'RECIBIDA';
    RETURN NEW;
END $$;
CREATE TRIGGER trg_muestra_corrida_fechas BEFORE INSERT OR UPDATE ON muestra_corrida
FOR EACH ROW EXECUTE FUNCTION fn_muestra_corrida_fechas();

-- T7 Al cerrar una corrida: debe tener al menos una muestra (participación
--    total de Corrida en Secuenciada_En) y sus muestras pasan a SECUENCIADA.
CREATE OR REPLACE FUNCTION fn_cerrar_corrida() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.estado = 'COMPLETADA' AND OLD.estado <> 'COMPLETADA' THEN
        IF NOT EXISTS (SELECT 1 FROM muestra_corrida WHERE id_corrida = NEW.id_corrida) THEN
            RAISE EXCEPTION 'La corrida % no tiene muestras y no puede completarse', NEW.id_corrida;
        END IF;
        NEW.fecha_fin := COALESCE(NEW.fecha_fin, now());
        UPDATE muestra SET estado = 'SECUENCIADA'
         WHERE id_muestra IN (SELECT id_muestra FROM muestra_corrida WHERE id_corrida = NEW.id_corrida)
           AND estado <> 'DESCARTADA';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_cerrar_corrida BEFORE UPDATE OF estado ON corrida
FOR EACH ROW EXECUTE FUNCTION fn_cerrar_corrida();

-- T8 Historial de reclasificaciones de ClinVar (alimenta la consulta C8).
CREATE OR REPLACE FUNCTION fn_anotacion_historial() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.significancia IS DISTINCT FROM OLD.significancia THEN
        INSERT INTO anotacion_historial(id_anotacion, significancia_anterior,
                                        significancia_nueva, fecha_cambio)
        VALUES (NEW.id_anotacion, OLD.significancia, NEW.significancia,
                COALESCE(NEW.fecha_evaluacion, CURRENT_DATE));
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_anotacion_historial AFTER UPDATE OF significancia ON anotacion_clinica
FOR EACH ROW EXECUTE FUNCTION fn_anotacion_historial();

-- T9 (RS23) Si el donante revoca el consentimiento, se borran en cascada sus
--    muestras (y por FK sus participaciones en corridas y genotipos), y queda
--    registrado en la bitácora.
CREATE OR REPLACE FUNCTION fn_donante_revoca() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE n INT;
BEGIN
    IF OLD.consentimiento AND NOT NEW.consentimiento THEN
        DELETE FROM muestra WHERE id_donante = NEW.id_donante;
        GET DIAGNOSTICS n = ROW_COUNT;
        INSERT INTO bitacora(evento, detalle)
        VALUES ('REVOCA_CONSENTIMIENTO',
                format('donante %s: %s muestras eliminadas en cascada', NEW.id_donante, n));
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_donante_revoca AFTER UPDATE OF consentimiento ON donante
FOR EACH ROW EXECUTE FUNCTION fn_donante_revoca();
