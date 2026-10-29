-- =====================================================================
-- GenVar-PE · Solo para la base en la nube (Neon u otro servicio sin superusuario).
-- El usuario dueño de la base crea los roles pero no es superusuario, así que
-- para que la web pueda hacer SET ROLE tiene que ser miembro de cada rol.
-- Ejecutar DESPUÉS de 05_roles.sql. En una instalación local no hace falta.
-- =====================================================================
DO $$
DECLARE r TEXT;
BEGIN
    FOREACH r IN ARRAY ARRAY['tecnico_lab','bioinformatico','genetista','investigador','auditor']
    LOOP
        EXECUTE format('GRANT %I TO CURRENT_USER', r);
    END LOOP;
END $$;
