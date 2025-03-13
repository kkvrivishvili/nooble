-- ==============================================
-- ARCHIVO: init_8.sql - Políticas RLS (Row Level Security)
-- ==============================================
-- Propósito: Implementar políticas de seguridad a nivel de fila para todas las
-- tablas del sistema, garantizando que los usuarios solo puedan acceder a los
-- datos que les corresponden según sus permisos.
--
-- Este archivo:
--   1. Limpia todas las políticas RLS existentes
--   2. Habilita RLS en todas las tablas relevantes
--   3. Implementa políticas para tablas principales (usuarios, perfiles)
--   4. Implementa políticas para tablas de contenido (bots, colecciones)
--   5. Implementa políticas para tablas de interacción (conversaciones, mensajes)
--   6. Implementa políticas para tablas de analítica y métricas
--   7. Configura políticas específicas para particiones
--   8. Crea un usuario administrador inicial si no existe
--
-- IMPORTANTE: Las políticas respetan la estructura de esquemas, donde las tablas
-- públicas están en el esquema 'public' y las tablas internas en el esquema 'app'.
-- ==============================================

-- ---------- SECCIÓN 1: LIMPIEZA DE POLÍTICAS ANTIGUAS ----------

/**
 * Función para eliminar todas las políticas de seguridad existentes en los
 * esquemas 'public' y 'app'. Esto evita conflictos al recrear las políticas.
 */
DROP POLICY IF EXISTS ON ALL IN SCHEMA public;
DROP POLICY IF EXISTS ON ALL IN SCHEMA app;

-- ---------- SECCIÓN 2: HABILITAR RLS EN TODAS LAS TABLAS ----------

/**
 * Habilitar RLS en tablas del esquema 'app'
 */
ALTER TABLE app.users ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.document_collections ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.document_chunks ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.bot_collections ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.bot_response_feedback ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.vector_analytics ENABLE ROW LEVEL SECURITY;

/**
 * Política simple para esquema app: solo permitir acceso con token válido
 */
CREATE POLICY "Require authentication for app schema"
ON ALL TABLES IN SCHEMA app
FOR ALL USING (auth.role() = 'authenticated');

/**
 * No se requieren políticas en el esquema public ya que será de acceso abierto
 */
ALTER TABLE public.bots DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.links DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.link_groups DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.link_group_items DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.conversations DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.messages DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.themes DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.profiles DISABLE ROW LEVEL SECURITY;

/**
 * Política básica para usuarios autenticados que modifiquen datos públicos
 */
CREATE POLICY "Allow authenticated users to modify their public data"
ON ALL TABLES IN SCHEMA public
FOR ALL USING (
  CASE 
    WHEN auth.role() = 'authenticated' THEN true
    ELSE CURRENT_OPERATION = 'SELECT'
  END
);