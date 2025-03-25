import os
from typing import List, Dict, Any, Optional
import uuid
import time
from fastapi import FastAPI, HTTPException, Depends, BackgroundTasks, Request
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field
import httpx
from supabase import create_client, Client
import redis
from redis.exceptions import ConnectionError
import json
from tenacity import retry, stop_after_attempt, wait_exponential

# LlamaIndex imports
from llama_index.embeddings.openai import OpenAIEmbedding
from llama_index.embeddings.base import BaseEmbedding
from llama_index.core.schema import TextNode, NodeWithEmbedding

# FastAPI app
app = FastAPI(title="Linktree AI - Embeddings Service")

# Add CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # Specify your frontend domain in production
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Configuration
SUPABASE_URL = os.environ.get("SUPABASE_URL")
SUPABASE_KEY = os.environ.get("SUPABASE_KEY")
OPENAI_API_KEY = os.environ.get("OPENAI_API_KEY")
REDIS_URL = os.environ.get("REDIS_URL", "redis://localhost:6379")
DEFAULT_EMBEDDING_MODEL = os.environ.get("DEFAULT_EMBEDDING_MODEL", "text-embedding-3-small")
DEFAULT_EMBEDDING_DIMENSION = int(os.environ.get("DEFAULT_EMBEDDING_DIMENSION", "1536"))
EMBEDDING_BATCH_SIZE = int(os.environ.get("EMBEDDING_BATCH_SIZE", "100"))

# Redis connection for caching
try:
    redis_client = redis.from_url(REDIS_URL)
    print("Redis connected successfully")
except ConnectionError:
    print("Warning: Redis connection failed. Running without cache.")
    redis_client = None

# Supabase client
supabase: Client = create_client(SUPABASE_URL, SUPABASE_KEY)

# OpenAI Embedding model with caching
class CachedOpenAIEmbedding(BaseEmbedding):
    def __init__(
        self,
        model_name: str = DEFAULT_EMBEDDING_MODEL,
        embed_batch_size: int = EMBEDDING_BATCH_SIZE,
        api_key: Optional[str] = None,
        cache_prefix: str = "embed",
        cache_ttl: int = 86400 * 7,  # 7 days default
    ):
        super().__init__(model_name=model_name)
        self.api_key = api_key or OPENAI_API_KEY
        self.embed_batch_size = embed_batch_size
        self.openai_embed = OpenAIEmbedding(
            model_name=model_name,
            api_key=self.api_key,
            embed_batch_size=embed_batch_size
        )
        self.cache_prefix = cache_prefix
        self.cache_ttl = cache_ttl
    
    def _get_cache_key(self, text: str) -> str:
        """Generate a cache key for a text."""
        import hashlib
        # Create hash from text and model name to ensure uniqueness
        text_hash = hashlib.md5(text.encode()).hexdigest()
        return f"{self.cache_prefix}:{self.model_name}:{text_hash}"
    
    @retry(stop=stop_after_attempt(3), wait=wait_exponential(multiplier=1, min=4, max=10))
    def _get_text_embedding(self, text: str) -> List[float]:
        """Get embedding with caching."""
        if not text.strip():
            # Return zero vector for empty text
            return [0.0] * DEFAULT_EMBEDDING_DIMENSION
            
        # Try to get from cache first
        if redis_client:
            cache_key = self._get_cache_key(text)
            cached_embedding = redis_client.get(cache_key)
            
            if cached_embedding:
                return json.loads(cached_embedding)
        
        # Get from OpenAI if not in cache
        embedding = self.openai_embed._get_text_embedding(text)
        
        # Store in cache if available
        if redis_client:
            cache_key = self._get_cache_key(text)
            redis_client.setex(
                cache_key,
                self.cache_ttl,
                json.dumps(embedding)
            )
        
        return embedding
    
    @retry(stop=stop_after_attempt(3), wait=wait_exponential(multiplier=1, min=4, max=10))
    def _get_text_embedding_batch(self, texts: List[str]) -> List[List[float]]:
        """Get embeddings for a batch of texts with caching."""
        if not texts:
            return []
            
        # Check which texts are in cache
        cache_hits = {}
        texts_to_embed = []
        original_indices = []
        
        if redis_client:
            for i, text in enumerate(texts):
                if not text.strip():
                    # Handle empty text
                    cache_hits[i] = [0.0] * DEFAULT_EMBEDDING_DIMENSION
                    continue
                    
                cache_key = self._get_cache_key(text)
                cached_embedding = redis_client.get(cache_key)
                
                if cached_embedding:
                    cache_hits[i] = json.loads(cached_embedding)
                else:
                    texts_to_embed.append(text)
                    original_indices.append(i)
        else:
            # No cache available, embed all non-empty texts
            for i, text in enumerate(texts):
                if not text.strip():
                    cache_hits[i] = [0.0] * DEFAULT_EMBEDDING_DIMENSION
                else:
                    texts_to_embed.append(text)
                    original_indices.append(i)
        
        # If all texts were in cache, return them
        if not texts_to_embed:
            return [cache_hits[i] for i in range(len(texts))]
        
        # Get embeddings for texts not in cache
        embeddings = self.openai_embed._get_text_embedding_batch(texts_to_embed)
        
        # Store new embeddings in cache
        if redis_client:
            for text_idx, embedding in zip(original_indices, embeddings):
                text = texts[text_idx]
                cache_key = self._get_cache_key(text)
                redis_client.setex(
                    cache_key,
                    self.cache_ttl,
                    json.dumps(embedding)
                )
        
        # Combine cached and new embeddings
        result = [None] * len(texts)
        
        # Add cache hits
        for idx, embedding in cache_hits.items():
            result[idx] = embedding
        
        # Add new embeddings
        for orig_idx, embedding in zip(original_indices, embeddings):
            result[orig_idx] = embedding
        
        return result

# Initialize the embedding model
embed_model = CachedOpenAIEmbedding(
    model_name=DEFAULT_EMBEDDING_MODEL,
    embed_batch_size=EMBEDDING_BATCH_SIZE,
    api_key=OPENAI_API_KEY,
    cache_prefix="linktree-embed"
)

# Pydantic models
class TenantInfo(BaseModel):
    tenant_id: str
    subscription_tier: str  # "free", "pro", "business"

class TextItem(BaseModel):
    text: str
    metadata: Optional[Dict[str, Any]] = Field(default_factory=dict)

class EmbeddingRequest(BaseModel):
    tenant_id: str
    texts: List[str]
    metadata: Optional[List[Dict[str, Any]]] = None
    model: Optional[str] = None

class BatchEmbeddingRequest(BaseModel):
    tenant_id: str
    items: List[TextItem]
    model: Optional[str] = None

class EmbeddingResponse(BaseModel):
    success: bool
    embeddings: List[List[float]]
    model: str
    dimensions: int
    processing_time: float
    cached_count: int = 0

# Dependency to verify tenant exists and subscription is active
async def verify_tenant(tenant_id: str) -> TenantInfo:
    tenant_data = supabase.table("tenants").select("*").eq("tenant_id", tenant_id).execute()
    
    if not tenant_data.data:
        raise HTTPException(status_code=404, detail=f"Tenant {tenant_id} not found")
    
    # Check if subscription is active
    subscription_data = supabase.table("tenant_subscriptions").select("*") \
        .eq("tenant_id", tenant_id) \
        .eq("is_active", True) \
        .execute()
    
    if not subscription_data.data:
        raise HTTPException(status_code=403, detail=f"No active subscription for tenant {tenant_id}")
    
    return TenantInfo(
        tenant_id=tenant_id,
        subscription_tier=subscription_data.data[0]["subscription_tier"]
    )

# Rate limiter middleware
@app.middleware("http")
async def rate_limit_middleware(request: Request, call_next):
    # Extract tenant_id from path or body
    tenant_id = None
    
    # Try to get from path params
    path_parts = request.url.path.split("/")
    if len(path_parts) > 2 and path_parts[1] == "embed":
        tenant_id = path_parts[2]
    
    # If not found in path, try to get from body for POST requests
    if not tenant_id and request.method == "POST":
        try:
            body = await request.json()
            tenant_id = body.get("tenant_id")
        except:
            pass
    
    if tenant_id and redis_client:
        # Check rate limit
        rate_key = f"ratelimit:{tenant_id}:minute"
        current = redis_client.get(rate_key)
        
        if current and int(current) > 600:  # 600 requests per minute max
            return HTTPException(
                status_code=429,
                detail="Rate limit exceeded. Try again later."
            )
        
        # Increment rate counter
        pipe = redis_client.pipeline()
        pipe.incr(rate_key)
        pipe.expire(rate_key, 60)  # 1 minute TTL
        pipe.execute()
    
    # Continue with the request
    return await call_next(request)

# API endpoints
@app.post("/embed", response_model=EmbeddingResponse)
async def generate_embeddings(
    request: EmbeddingRequest,
    tenant_info: TenantInfo = Depends(verify_tenant)
):
    start_time = time.time()
    
    # Use requested model if specified and allowed for this tenant
    model_name = DEFAULT_EMBEDDING_MODEL
    if request.model:
        # Check if tenant can use custom models
        if tenant_info.subscription_tier in ["pro", "business"]:
            model_name = request.model
        else:
            # For free tier, ignore custom model request
            pass
    
    # Check if metadata was provided and has the right length
    metadata = request.metadata or []
    if metadata and len(metadata) != len(request.texts):
        raise HTTPException(
            status_code=400,
            detail="If metadata is provided, it must have the same length as texts"
        )
    
    # Pad metadata if needed
    while len(metadata) < len(request.texts):
        metadata.append({})
    
    # Add tenant_id to metadata
    for meta in metadata:
        meta["tenant_id"] = request.tenant_id
    
    # Generate embeddings
    try:
        if redis_client:
            # Count cache hits for stats
            cache_hits = 0
            for text in request.texts:
                cache_key = embed_model._get_cache_key(text)
                if redis_client.exists(cache_key):
                    cache_hits += 1
        
        # Generate embeddings
        embeddings = embed_model._get_text_embedding_batch(request.texts)
        
        # Track token usage (approximate)
        total_tokens = sum(len(text.split()) * 1.3 for text in request.texts)
        supabase.rpc(
            "increment_token_usage",
            {
                "p_tenant_id": request.tenant_id,
                "p_tokens": int(total_tokens)
            }
        ).execute()
        
        return EmbeddingResponse(
            success=True,
            embeddings=embeddings,
            model=model_name,
            dimensions=len(embeddings[0]) if embeddings else DEFAULT_EMBEDDING_DIMENSION,
            processing_time=time.time() - start_time,
            cached_count=cache_hits if redis_client else 0
        )
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"Error generating embeddings: {str(e)}"
        )

@app.post("/embed/batch", response_model=EmbeddingResponse)
async def batch_generate_embeddings(
    request: BatchEmbeddingRequest,
    tenant_info: TenantInfo = Depends(verify_tenant)
):
    start_time = time.time()
    
    # Use requested model if specified and allowed for this tenant
    model_name = DEFAULT_EMBEDDING_MODEL
    if request.model:
        # Check if tenant can use custom models
        if tenant_info.subscription_tier in ["pro", "business"]:
            model_name = request.model
        else:
            # For free tier, ignore custom model request
            pass
    
    # Extract texts and metadata
    texts = [item.text for item in request.items]
    metadata = [item.metadata for item in request.items]
    
    # Add tenant_id to metadata
    for meta in metadata:
        meta["tenant_id"] = request.tenant_id
    
    # Generate embeddings
    try:
        if redis_client:
            # Count cache hits for stats
            cache_hits = 0
            for text in texts:
                cache_key = embed_model._get_cache_key(text)
                if redis_client.exists(cache_key):
                    cache_hits += 1
        
        # Generate embeddings
        embeddings = embed_model._get_text_embedding_batch(texts)
        
        # Track token usage (approximate)
        total_tokens = sum(len(text.split()) * 1.3 for text in texts)
        supabase.rpc(
            "increment_token_usage",
            {
                "p_tenant_id": request.tenant_id,
                "p_tokens": int(total_tokens)
            }
        ).execute()
        
        return EmbeddingResponse(
            success=True,
            embeddings=embeddings,
            model=model_name,
            dimensions=len(embeddings[0]) if embeddings else DEFAULT_EMBEDDING_DIMENSION,
            processing_time=time.time() - start_time,
            cached_count=cache_hits if redis_client else 0
        )
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"Error generating embeddings: {str(e)}"
        )

@app.get("/models")
async def list_available_models(tenant_info: TenantInfo = Depends(verify_tenant)):
    # Base models available to all tiers
    base_models = [
        {
            "id": "text-embedding-3-small",
            "name": "OpenAI Embedding Small",
            "dimensions": 1536,
            "provider": "openai",
            "description": "Fast and efficient general purpose embedding model"
        }
    ]
    
    # Pro and business tier models
    advanced_models = [
        {
            "id": "text-embedding-3-large",
            "name": "OpenAI Embedding Large",
            "dimensions": 3072,
            "provider": "openai",
            "description": "High performance embedding model with better retrieval quality"
        }
    ]
    
    # Return models based on subscription tier
    if tenant_info.subscription_tier in ["pro", "business"]:
        return {"models": base_models + advanced_models}
    else:
        return {"models": base_models}

@app.get("/status")
async def get_service_status():
    try:
        # Check if Redis is available
        redis_status = "available" if redis_client and redis_client.ping() else "unavailable"
        
        # Check if Supabase is available
        supabase_status = "available"
        try:
            supabase.table("tenants").select("tenant_id").limit(1).execute()
        except Exception:
            supabase_status = "unavailable"
        
        # Check if OpenAI is available
        openai_status = "available"
        try:
            # Quick test - generate a simple embedding
            test_result = embed_model._get_text_embedding("test")
            if not test_result or len(test_result) < 10:
                openai_status = "degraded"
        except Exception:
            openai_status = "unavailable"
        
        return {
            "status": "healthy" if all(s == "available" for s in [redis_status, supabase_status, openai_status]) else "degraded",
            "components": {
                "redis": redis_status,
                "supabase": supabase_status,
                "openai": openai_status
            },
            "embedding_model": DEFAULT_EMBEDDING_MODEL,
            "dimensions": DEFAULT_EMBEDDING_DIMENSION,
            "version": "1.0.0"
        }
    except Exception as e:
        return {
            "status": "error",
            "error": str(e)
        }

@app.get("/cache/stats")
async def get_cache_stats(tenant_info: TenantInfo = Depends(verify_tenant)):
    if not redis_client:
        return {"status": "cache_unavailable"}
    
    try:
        # Get total keys in cache
        total_keys = redis_client.dbsize()
        
        # Get tenant-specific keys (if they're prefixed by tenant)
        tenant_prefix = f"linktree-embed:{DEFAULT_EMBEDDING_MODEL}:"
        tenant_keys = 0  # This is an approximation as we can't easily count by tenant
        
        # Get memory usage
        memory_info = redis_client.info("memory")
        used_memory = memory_info.get("used_memory_human", "unknown")
        
        return {
            "status": "available",
            "total_cached_embeddings": total_keys,
            "tenant_cached_embeddings": tenant_keys,
            "memory_usage": used_memory
        }
    except Exception as e:
        return {
            "status": "error",
            "error": str(e)
        }

@app.delete("/cache/clear/{tenant_id}")
async def clear_tenant_cache(
    tenant_id: str,
    tenant_info: TenantInfo = Depends(verify_tenant)
):
    # Only allow admins or the tenant itself to clear their cache
    if tenant_id != tenant_info.tenant_id and tenant_info.subscription_tier != "business":
        raise HTTPException(
            status_code=403, 
            detail="You can only clear your own cache unless you have admin privileges"
        )
    
    if not redis_client:
        return {"status": "cache_unavailable"}
    
    try:
        # We can't easily target just tenant's keys without a proper design
        # This is a simplified approach - in production you'd want tenant isolation in cache keys
        # Clear all embedding cache (dangerous in production!)
        cursor = 0
        deleted = 0
        
        while True:
            cursor, keys = redis_client.scan(cursor, match=f"linktree-embed:*", count=100)
            if keys:
                deleted += redis_client.delete(*keys)
            
            if cursor == 0:
                break
        
        return {
            "status": "success",
            "deleted_keys": deleted
        }
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"Error clearing cache: {str(e)}"
        )

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8001)