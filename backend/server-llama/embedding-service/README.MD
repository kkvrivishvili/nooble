# Servicio de Embeddings LlamaIndex

Este servicio forma parte de la plataforma Linktree AI y se encarga de la generación y gestión de embeddings vectoriales en un entorno multitenancy.

## Características

- Generación de embeddings usando OpenAI API
- Caché de embeddings para mejorar rendimiento y reducir costos
- Control de acceso por tenant y nivel de suscripción
- Rate limiting para proteger el servicio
- Métricas y monitoreo del uso de embeddings
- Soporte para múltiples modelos de embeddings según nivel de suscripción

## Requisitos

- Python 3.10+
- Supabase (cuenta y proyecto configurado)
- API Key de OpenAI
- Redis (para caché y rate limiting)

## Configuración

1. Copia el archivo `.env.example` a `.env` y ajusta los valores:

```
cp .env.example .env
```

2. Edita el archivo `.env` con tus credenciales:

```
SUPABASE_URL=https://your-supabase-project.supabase.co
SUPABASE_KEY=your-supabase-service-key
OPENAI_API_KEY=your-openai-api-key
```

3. Configura el esquema adicional de la base de datos ejecutando el script SQL en tu proyecto Supabase:

```
supabase_embeddings_schema.sql
```

## Instalación y Ejecución

### Usando Docker (recomendado)

```bash
docker-compose up -d
```

### Instalación local

```bash
pip install -r requirements.txt
uvicorn embeddings_service:app --reload
```

## Endpoints API

### POST /embed
Genera embeddings para una lista de textos.

**Request:**
```json
{
  "tenant_id": "123e4567-e89b-12d3-a456-426614174000",
  "texts": ["Este es un texto de ejemplo", "Este es otro texto"],
  "metadata": [{"source": "manual"}, {"source": "website"}],
  "model": "text-embedding-3-small"
}
```

**Response:**
```json
{
  "success": true,
  "embeddings": [[0.1, 0.2, ...], [0.3, 0.4, ...]],
  "model": "text-embedding-3-small",
  "dimensions": 1536,
  "processing_time": 0.456,
  "cached_count": 1
}
```

### POST /embed/batch
Procesa embeddings para elementos con texto y metadata juntos.

**Request:**
```json
{
  "tenant_id": "123e4567-e89b-12d3-a456-426614174000",
  "items": [
    {
      "text": "Este es un texto de ejemplo",
      "metadata": {"source": "manual", "id": "doc1"}
    },
    {
      "text": "Este es otro texto",
      "metadata": {"source": "website", "id": "doc2"}
    }
  ],
  "model": "text-embedding-3-small"
}
```

### GET /models
Lista los modelos de embeddings disponibles para el tenant.

### GET /status
Verifica el estado del servicio y sus dependencias.

### GET /cache/stats
Obtiene estadísticas sobre el uso de caché.

### DELETE /cache/clear/{tenant_id}
Limpia la caché para un tenant específico.

## Arquitectura

El servicio sigue una arquitectura de microservicios y utiliza:

- FastAPI para la API REST
- OpenAI para generación de embeddings
- Redis para caché y rate limiting
- Supabase para autenticación y almacenamiento de metadatos

## Estructura del Proyecto

```
.
├── Dockerfile
├── docker-compose.yml
├── embeddings_service.py
├── requirements.txt
├── .env.example
└── supabase_embeddings_schema.sql
```

## Planes por Niveles y Límites

### Free
- Acceso solo al modelo text-embedding-3-small
- Rate limit de 600 requests/minuto
- Sin control de caché personalizado

### Pro
- Acceso a text-embedding-3-small y text-embedding-3-large
- Rate limit de 1200 requests/minuto
- Caché personalizado

### Business
- Acceso a todos los modelos
- Rate limit personalizable
- Control total de caché
- Estadísticas avanzadas