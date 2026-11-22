-- =============================================================================
-- Zanate · Reconciliación de aprovisionamiento de vendedores
-- Fecha: 2026-11-22
-- =============================================================================
-- Contexto:
--   El endurecimiento de roles (20261118220937_role_hardening) agregó el trigger
--   enforce_seller_admin_fields() sobre seller_profiles. Dos efectos colaterales
--   rompían flujos legítimos:
--
--   1) ensure_seller_profile_for_item() hacía INSERT ... ON CONFLICT DO NOTHING
--      cuando el perfil ya existía con otro plan/tipo; el trigger BEFORE INSERT
--      se ejecuta ANTES de resolver el conflicto y lanzaba 42501, impidiendo
--      publicar en Marketplace a vendedores ya existentes.
--   2) Los RPC administrativos que operan en contexto service_role (p. ej.
--      admin_review_merchant_verification) cambiaban los claims a service_role,
--      pero el trigger solo eximía a is_pemtree_admin(auth.uid()), bloqueando
--      la aprobación de comercios.
--
-- Solución (idempotente, sin relajar la protección para usuarios normales):
--   a) Solo provisionar el perfil cuando realmente no exista.
--   b) Eximir explícitamente al contexto service_role.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.ensure_seller_profile_for_item()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
    IF NEW.user_id IS NOT NULL
       AND NOT EXISTS (
           SELECT 1 FROM public.seller_profiles sp WHERE sp.user_id = NEW.user_id
       ) THEN
        INSERT INTO public.seller_profiles (user_id)
        VALUES (NEW.user_id)
        ON CONFLICT (user_id) DO NOTHING;
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.enforce_seller_admin_fields()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_old_plan     text;
    v_old_expires  timestamptz;
    v_old_ver      text;
    v_old_type     text;
    v_exists       boolean := false;
    v_jwt_role     text;
BEGIN
    -- Contexto de servicio (panel administrativo / workers): no aplicar guardas.
    BEGIN
        v_jwt_role := (NULLIF(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role');
    EXCEPTION WHEN others THEN
        v_jwt_role := NULL;
    END;

    IF auth.uid() IS NULL
       OR v_jwt_role = 'service_role'
       OR public.is_pemtree_admin(auth.uid()) THEN
        RETURN NEW;
    END IF;

    IF TG_OP = 'INSERT' THEN
        SELECT sp.plan_id, sp.plan_expires_at, sp.verification_status, sp.seller_type
        INTO v_old_plan, v_old_expires, v_old_ver, v_old_type
        FROM public.seller_profiles sp
        WHERE sp.user_id = NEW.user_id;
        v_exists := FOUND;

        IF v_exists THEN
            IF NEW.plan_id IS DISTINCT FROM v_old_plan
               OR NEW.plan_expires_at IS DISTINCT FROM v_old_expires THEN
                RAISE EXCEPTION 'Solo un administrador puede cambiar el plan o la vigencia del vendedor' USING ERRCODE = '42501';
            END IF;
            IF NEW.seller_type IS DISTINCT FROM v_old_type THEN
                RAISE EXCEPTION 'Solo un administrador puede cambiar el tipo de vendedor' USING ERRCODE = '42501';
            END IF;
            IF NEW.verification_status = 'approved'
               AND NEW.verification_status IS DISTINCT FROM v_old_ver THEN
                RAISE EXCEPTION 'Solo un administrador puede aprobar la verificación de un vendedor' USING ERRCODE = '42501';
            END IF;
            RETURN NEW;
        END IF;

        IF auth.uid() IS DISTINCT FROM NEW.user_id THEN
            RAISE EXCEPTION 'Solo un administrador puede crear perfiles de vendedor para otros usuarios' USING ERRCODE = '42501';
        END IF;
        IF NEW.plan_id IS DISTINCT FROM 'free'
           OR NEW.seller_type IS DISTINCT FROM 'student'
           OR NEW.verification_status IS DISTINCT FROM 'pending' THEN
            RAISE EXCEPTION 'Solo un administrador puede dar de alta un comercio o asignar un plan' USING ERRCODE = '42501';
        END IF;
        RETURN NEW;
    END IF;

    IF NEW.plan_id IS DISTINCT FROM OLD.plan_id
       OR NEW.plan_expires_at IS DISTINCT FROM OLD.plan_expires_at THEN
        RAISE EXCEPTION 'Solo un administrador puede cambiar el plan o la vigencia del vendedor' USING ERRCODE = '42501';
    END IF;
    IF NEW.seller_type IS DISTINCT FROM OLD.seller_type THEN
        RAISE EXCEPTION 'Solo un administrador puede cambiar el tipo de vendedor' USING ERRCODE = '42501';
    END IF;
    IF NEW.verification_status = 'approved'
       AND NEW.verification_status IS DISTINCT FROM OLD.verification_status THEN
        RAISE EXCEPTION 'Solo un administrador puede aprobar la verificación de un vendedor' USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
END;
$function$;

-- -----------------------------------------------------------------------------
-- Retención legal: permitir cambios internos anidados (auto-cuarentena)
-- -----------------------------------------------------------------------------
-- La auto-cuarentena corre en un trigger AFTER INSERT sobre entity_reports y
-- actualiza posts.is_legal_hold. En ese contexto pg_trigger_depth() >= 2, por lo
-- que la guarda de "solo administrador" no debe bloquearla. Un UPDATE directo
-- del cliente siempre ocurre en profundidad 1.

CREATE OR REPLACE FUNCTION public.enforce_legal_hold_admin_only()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
    IF NEW.is_legal_hold IS DISTINCT FROM OLD.is_legal_hold
       AND pg_trigger_depth() < 2
       AND auth.uid() IS NOT NULL
       AND NOT public.is_pemtree_admin(auth.uid()) THEN
        RAISE EXCEPTION 'Solo un administrador puede modificar la retención legal'
            USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
END;
$function$;
