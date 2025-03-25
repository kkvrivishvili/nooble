# Servicio de Consulta LlamaIndex

Este servicio forma parte de la plataforma Linktree AI y se encarga de procesar consultas para el sistema RAG multitenancy, recuperando la información relevante y generando respuestas utilizando modelos de lenguaje avanzados.

## Características

- Procesamiento de consultas mediante RAG (Retrieval Augmented Generation)
- Recuperación de documentos relevantes basada en embeddings
- Generación de respuestas usando OpenAI GPT o Claude (según tier)
- Citado de fuentes para respuestas basadas en evidencia
- Diferentes modos de síntesis de respuesta (compact, refine, tree)
- Aislamiento completo entre tenants
- Control de cuotas y limitaciones según nivel de suscripción

## Requisitos

- Python 3.10+
- Supabase (cuenta y proyecto configurado)
- API Key de OpenAI
- Servicio de Embeddings Linktree AI
- Redis (para caché y funcionalidades adicionales)

## Configuración

1. Copia el archivo `.env.example` a `.env` y ajusta los valores:

```bash
cp .env.example .env
```

2. Edita el archivo `.env` con tus credenciales:

```
SUPABASE_URL=https://your-supabase-project.supabase.co
SUPABASE_KEY=your-supabase-service-key
OPENAI_API_KEY=your-openai-api-key
EMBEDDINGS_SERVICE_URL=http://embeddings-service:8001
```

3. Configura el esquema adicional de la base de datos ejecutando el script SQL en tu proyecto Supabase:

```
supabase_query_schema.sql
```

## Instalación y Ejecución

### Usando Docker (recomendado)

```bash
docker-compose up -d
```

### Instalación local

```bash
pip install -r requirements.txt
uvicorn query_service:app --reload
```

## Endpoints API

### POST /query
Procesa una consulta utilizando RAG y devuelve una respuesta con fuentes.

**Request:**
```json
{
  "tenant_id": "123e4567-e89b-12d3-a456-426614174000",
  "query": "¿Cuáles son los principales beneficios de RAG?",
  "collection_name": "technical_docs",
  "llm_model": "gpt-4-turbo",
  "similarity_top_k": 4,
  "response_mode": "compact"
}
```

**Response:**
```json
{
  "tenant_id": "123e4567-e89b-12d3-a456-426614174000",
  "query": "¿Cuáles son los principales beneficios de RAG?",
  "response": "Los principales beneficios de RAG (Retrieval Augmented Generation) son: 1) Mayor precisión gracias a la recuperación de información relevante, 2) Reducción de alucinaciones al basarse en datos específicos, 3) Capacidad para acceder a información actualizada o específica, y 4) Transparencia al citar las fuentes utilizadas.",
  "sources": [
    {
      "text": "RAG combina la recuperación de información con la generación para producir respuestas más precisas y fundamentadas.",
      "metadata": {
        "source": "technical_article.pdf",
        "page": 4
      },
      "score": 0.92
    },
    ...
  ],
  "processing_time": 1.45,
  "llm_model": "gpt-4-turbo",
  "collection_name": "technical_docs"
}
```

### GET /documents
Lista los documentos disponibles para un tenant con paginación.

### GET /collections
Lista todas las colecciones para un tenant junto con estadísticas.

### GET /llm/models
Lista los modelos de LLM disponibles según el nivel de suscripción.

### GET /stats
Obtiene estadísticas de uso y cuotas para un tenant.

### GET /healthcheck
Verifica el estado del servicio y sus dependencias.

## Arquitectura

El servicio sigue una arquitectura de microservicios y utiliza:

- FastAPI para la API REST
- LlamaIndex para la pipeline RAG
- OpenAI/Claude para LLMs
- Servicio de Embeddings personalizado
- Supabase como base de datos vectorial
- Redis para funcionalidades adicionales

## Planes por Niveles y Límites

### Free
- Acceso a GPT-3.5 Turbo únicamente
- Máximo 100 consultas por día
- 4 resultados máximo por consulta

### Pro
- Acceso a GPT-3.5 y GPT-4 Turbo
- Máximo 1,000 consultas por día
- 8 resultados máximo por consulta
- Modos avanzados de respuesta

### Business
- Acceso a todos los modelos incluido Claude
- Consultas ilimitadas (sujeto a fair use)
- 16 resultados máximo por consulta
- Todas las funcionalidades avanzadas
- Estadísticas detalladas

## Integración con Otros Servicios

El Servicio de Consulta se integra con:

1. **Servicio de Embeddings** - Para generar vectores de consulta
2. **Servicio de Ingestión** - Que proporciona los documentos indexados
3. **Supabase** - Para almacenamiento y autenticación
4. **LLMs (OpenAI/Claude)** - Para generación de respuestas

## Personalización

Los administradores pueden personalizar:

- Templates de prompts para RAG
- Modelos de LLM por defecto
- Parámetros de recuperación y generación
- Cuotas y limitaciones por tenant