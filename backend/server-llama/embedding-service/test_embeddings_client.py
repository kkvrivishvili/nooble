import requests
import json
import os
from dotenv import load_dotenv
import time

# Load environment variables
load_dotenv()

# Configuration
API_BASE_URL = "http://localhost:8001"
TENANT_ID = os.getenv("TEST_TENANT_ID", "00000000-0000-0000-0000-000000000000")  # Replace with a real tenant ID

def test_simple_embedding():
    """Test the /embed endpoint with a simple text"""
    
    # Prepare sample texts
    texts = [
        "LlamaIndex es una herramienta potente para RAG. Permite indexar documentos y consultarlos con lenguaje natural.",
        "La arquitectura multitenancy implica que multiples clientes comparten la misma infraestructura pero con datos aislados."
    ]
    
    # Create request payload
    payload = {
        "tenant_id": TENANT_ID,
        "texts": texts
    }
    
    # Send request
    start_time = time.time()
    response = requests.post(f"{API_BASE_URL}/embed", json=payload)
    end_time = time.time()
    
    # Print results
    print(f"Status Code: {response.status_code}")
    if response.status_code == 200:
        result = response.json()
        print(f"Model: {result['model']}")
        print(f"Dimensions: {result['dimensions']}")
        print(f"Processing Time (API): {result['processing_time']:.3f}s")
        print(f"Processing Time (Total): {end_time - start_time:.3f}s")
        print(f"Cache Hits: {result['cached_count']}")
        print(f"First embedding vector (truncated): {result['embeddings'][0][:5]}...")
    else:
        print(f"Error: {response.text}")
    
    return response.json() if response.status_code == 200 else None

def test_batch_embedding():
    """Test the /embed/batch endpoint with metadata"""
    
    # Prepare sample items
    items = [
        {
            "text": "Este es un texto sobre inteligencia artificial y LLMs.",
            "metadata": {
                "source": "manual",
                "id": "doc1",
                "category": "AI"
            }
        },
        {
            "text": "Los modelos de embeddings vectorizan textos para búsquedas semánticas.",
            "metadata": {
                "source": "website",
                "id": "doc2",
                "category": "NLP"
            }
        },
        {
            "text": "RAG combina recuperación y generación para respuestas precisas.",
            "metadata": {
                "source": "tutorial",
                "id": "doc3",
                "category": "RAG"
            }
        }
    ]
    
    # Create request payload
    payload = {
        "tenant_id": TENANT_ID,
        "items": items
    }
    
    # Send request
    response = requests.post(f"{API_BASE_URL}/embed/batch", json=payload)
    
    # Print results
    print(f"\nBatch Embedding Test")
    print(f"Status Code: {response.status_code}")
    if response.status_code == 200:
        result = response.json()
        print(f"Number of embeddings: {len(result['embeddings'])}")
        print(f"Processing Time: {result['processing_time']:.3f}s")
        
        # Verify dimensions are consistent
        dimensions = [len(emb) for emb in result['embeddings']]
        print(f"All embeddings have same dimensions: {len(set(dimensions)) == 1}")
    else:
        print(f"Error: {response.text}")

def test_advanced_model():
    """Test with a more advanced model (might fail if tenant doesn't have access)"""
    
    # Prepare sample text
    texts = ["Este es un ejemplo para probar el modelo avanzado de embeddings."]
    
    # Create request payload
    payload = {
        "tenant_id": TENANT_ID,
        "texts": texts,
        "model": "text-embedding-3-large"  # Advanced model
    }
    
    # Send request
    response = requests.post(f"{API_BASE_URL}/embed", json=payload)
    
    # Print results
    print(f"\nAdvanced Model Test")
    print(f"Status Code: {response.status_code}")
    if response.status_code == 200:
        result = response.json()
        print(f"Model requested vs used: text-embedding-3-large vs {result['model']}")
        print(f"Dimensions: {result['dimensions']}")
    else:
        print(f"Error: {response.text}")

def test_available_models():
    """Get list of available models for this tenant"""
    
    # Send request
    response = requests.get(f"{API_BASE_URL}/models?tenant_id={TENANT_ID}")
    
    # Print results
    print(f"\nAvailable Models Test")
    print(f"Status Code: {response.status_code}")
    if response.status_code == 200:
        result = response.json()
        print(f"Available models:")
        for model in result['models']:
            print(f"  - {model['name']} ({model['id']}): {model['dimensions']} dimensions")
    else:
        print(f"Error: {response.text}")

def test_service_status():
    """Check the service status"""
    
    # Send request
    response = requests.get(f"{API_BASE_URL}/status")
    
    # Print results
    print(f"\nService Status Test")
    print(f"Status Code: {response.status_code}")
    if response.status_code == 200:
        result = response.json()
        print(f"Service status: {result['status']}")
        print(f"Components status:")
        for component, status in result['components'].items():
            print(f"  - {component}: {status}")
    else:
        print(f"Error: {response.text}")

def run_all_tests():
    """Run all tests in sequence"""
    print("=== EMBEDDINGS SERVICE TEST CLIENT ===")
    print(f"Testing against: {API_BASE_URL}")
    print(f"Using tenant ID: {TENANT_ID}")
    print("=" * 40)
    
    test_simple_embedding()
    test_batch_embedding()
    test_advanced_model()
    test_available_models()
    test_service_status()
    
    print("\nAll tests completed!")

if __name__ == "__main__":
    run_all_tests()