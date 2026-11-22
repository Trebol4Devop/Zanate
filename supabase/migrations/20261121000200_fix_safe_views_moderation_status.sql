-- =============================================================================
-- Zanate · Migración: Corrección de visibilidad en vistas seguras (moderation_status)
-- Timestamp fijo: 20261121000200
-- =============================================================================
-- Bug solucionado:
-- safe_posts_feed y safe_comments filtraban 'moderation_status = 0', ocultando
-- publicaciones y comentarios válidamente aprobados (status = 1) o bajo revisión
-- humana no sancionada (status = 3).
--
-- Semántica canónica de moderation_status:
--   0 = pendiente
--   1 = aprobado
--   2 = oculto / rechazado
--   3 = revisión humana
--
-- Criterio de visibilidad unificado:
--   moderation_status IS DISTINCT FROM 2 (excluye únicamente el contenido rechazado/oculto)
-- =============================================================================

-- 1. Vista segura de publicaciones (safe_posts_feed)
CREATE OR REPLACE VIEW public.safe_posts_feed
WITH (security_invoker = true)
AS
SELECT
    p.id,
    p.title,
    p.category,
    p.content,
    p.author_alias,
    p.author_hash,
    p.likes,
    p.reposts_count,
    p.comments_count,
    p.comments_count AS comment_count,
    p.hot_score,
    p.carrera,
    p.image_url,
    p.gif_url,
    p.is_pinned,
    p.quoted_post_id,
    p.created_at,
    p.updated_at,
    p.moderation_status,
    p.moderation_label,
    p.moderation_confidence,
    p.moderation_reason,
    p.moderated_at,
    p.moderated_by,
    p.expires_at,
    p.deleted_at,
    p.is_legal_hold,
    public.is_my_post(p.id) AS is_mine
FROM public.posts p
WHERE p.deleted_at IS NULL
  AND p.moderation_status IS DISTINCT FROM 2
  AND (p.expires_at IS NULL OR p.expires_at > now());

-- 2. Vista segura de comentarios (safe_comments)
CREATE OR REPLACE VIEW public.safe_comments
WITH (security_invoker = true)
AS
SELECT
    c.id,
    c.post_id,
    c.parent_id,
    c.content,
    c.author_alias,
    c.author_hash,
    c.is_op,
    c.is_op AS is_post_author,
    c.likes_count,
    c.gif_url,
    c.created_at,
    c.updated_at,
    c.moderation_status,
    c.moderation_label,
    c.moderation_confidence,
    c.moderation_reason,
    c.moderated_at,
    c.moderated_by,
    c.deleted_at,
    c.is_legal_hold,
    public.is_my_comment(c.id) AS is_mine
FROM public.comments c
WHERE c.deleted_at IS NULL
  AND c.moderation_status IS DISTINCT FROM 2;

-- 3. Vista segura de grupos estudiantiles (safe_student_groups)
CREATE OR REPLACE VIEW public.safe_student_groups
WITH (security_invoker = true)
AS
SELECT
    id,
    title,
    carrera,
    curso,
    section,
    link,
    description,
    author_alias,
    upvotes,
    reported_count,
    created_at,
    image_url,
    moderation_status,
    moderation_label,
    moderation_confidence,
    moderation_reason,
    moderated_at,
    moderated_by,
    platform,
    updated_at,
    deleted_at,
    is_legal_hold,
    public.is_my_group(id) AS is_mine
FROM public.student_groups
WHERE deleted_at IS NULL
  AND (moderation_status IS DISTINCT FROM 2 OR public.is_my_group(id));

-- 4. Vista segura de artículos de marketplace (safe_marketplace_items)
CREATE OR REPLACE VIEW public.safe_marketplace_items
WITH (security_invoker = true)
AS
SELECT
    mi.id,
    mi.title,
    mi.description,
    mi.price,
    mi.is_free,
    mi.category,
    mi.facultad,
    mi.sede,
    mi.building_code,
    mi.location_detail,
    mi.contact_whatsapp,
    mi.contact_telegram,
    mi.contact_instagram,
    mi.contact_messenger,
    mi.social_links,
    mi.image_urls,
    mi.video_url,
    mi.is_sponsored,
    mi.sponsor_badge_text,
    mi.author_alias,
    mi.upvotes,
    mi.reported_count,
    mi.shares_count,
    mi.status,
    mi.moderation_status,
    mi.moderation_label,
    mi.moderation_confidence,
    mi.moderation_reason,
    mi.moderated_at,
    mi.moderated_by,
    mi.created_at,
    mi.updated_at,
    mi.expires_at,
    mi.deleted_at,
    mi.is_legal_hold,
    ctx.seller_public_id,
    ctx.seller_business_name,
    ctx.seller_plan_id,
    ctx.seller_plan_name,
    ctx.seller_badge_text,
    ctx.seller_is_verified,
    ctx.seller_is_on_campus,
    ctx.seller_building_code,
    public.is_my_marketplace_item(mi.id) AS is_mine,
    (auth.uid() IS NOT NULL AND EXISTS (
        SELECT 1 FROM public.marketplace_upvotes mu
        WHERE mu.item_id = mi.id AND mu.user_id = auth.uid()
    )) AS is_upvoted_by_me,
    (auth.uid() IS NOT NULL AND EXISTS (
        SELECT 1 FROM public.marketplace_bookmarks mb
        WHERE mb.item_id = mi.id AND mb.user_id = auth.uid()
    )) AS is_bookmarked_by_me
FROM public.marketplace_items mi
LEFT JOIN LATERAL public.get_item_seller_context(mi.id) ctx ON true
WHERE mi.deleted_at IS NULL
  AND (
      mi.moderation_status IS DISTINCT FROM 2
      OR public.is_my_marketplace_item(mi.id)
  )
  AND (
      mi.status IN ('available', 'reserved')
      OR public.is_my_marketplace_item(mi.id)
  )
  AND (mi.expires_at IS NULL OR mi.expires_at > now());

-- 5. Reafirmar vistas de compatibilidad histórica (v_public_posts, v_public_comments)
CREATE OR REPLACE VIEW public.v_public_posts
WITH (security_invoker = true)
AS
SELECT
    id,
    title,
    category,
    content,
    author_alias,
    author_hash,
    likes,
    reposts_count,
    carrera,
    image_url,
    gif_url,
    is_pinned,
    quoted_post_id,
    created_at,
    moderation_status,
    comments_count AS comment_count,
    is_mine AS is_my_post
FROM public.safe_posts_feed;

CREATE OR REPLACE VIEW public.v_public_comments
WITH (security_invoker = true)
AS
SELECT
    id,
    post_id,
    parent_id,
    content,
    author_alias,
    author_hash,
    gif_url,
    created_at,
    moderation_status,
    is_op AS is_post_author,
    is_mine AS is_my_comment
FROM public.safe_comments;

-- 6. Reafirmar permisos SELECT vigentes para anon y authenticated
GRANT SELECT ON public.safe_posts_feed TO anon, authenticated;
GRANT SELECT ON public.safe_comments TO anon, authenticated;
GRANT SELECT ON public.safe_student_groups TO anon, authenticated;
GRANT SELECT ON public.safe_marketplace_items TO anon, authenticated;
GRANT SELECT ON public.v_public_posts TO anon, authenticated;
GRANT SELECT ON public.v_public_comments TO anon, authenticated;
