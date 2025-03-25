import requests
import json
import os
from dotenv import load_dotenv
import time

# Load environment variables
load_dotenv()

# Configuration
API_BASE_URL = "http://localhost:8002"
TENANT_ID = os.getenv("TEST_TENANT_ID", "00000000-0000-0000-0000-000000000000")  # Replace with a real tenant ID

def test_basic_query():
    """Test the /query endpoint with a basic query"""
    
    # Prepare query
    query = "¿Qué es LlamaIndex y cómo funciona RAG?"
    
    # Create request payload
    payload = {
        "tenant_id": TENANT_ID,
        "query": query,
        "collection_name": "default",  # Use your actual collection
        "similarity_top_k": 4
    }
    
    # Send request
    start_time = time.time()
    response = requests.post(f"{API_BASE_URL}/query", json=payload)
    end_time = time.time()
    
    # Print results
    print(f"Status Code: {response.status_code}")
    if response.status_code == 200:
        result = response.json()
        print(f"Query: {result['query']}")
        print(f"Processing Time: {result['processing_time']:.3f}s")
        print(f"Total Request Time: {end_time - start_time:.3f}s")
        print(f"LLM Model: {result['llm_model']}")
        print(f"Response: {result['response'][:300]}...")  # Show truncated response
        print(f"Sources: {len(result['sources'])}")
        
        # Show source details
        for i, source in enumerate(result['sources']):
            print(f"\nSource {i+1}:")
            print(f"  Score: {source.get('score')}")
            metadata = source.get('metadata', {})
            print(f"  Metadata: {', '.join([f'{k}: {v}' for k, v in metadata.items() if k != 'tenant_id'])}")
            print(f"  Text: {source.get('text', '')[:100]}...")  # Truncate text
    else:
        print(f"Error: {response.text}")
    
    return response.json() if response.status_code == 200 else None

def test_advanced_query():
    """Test the /query endpoint with advanced options"""
    
    # Prepare query
    query = "Explica las ventajas de un sistema multitenancy para implementaciones RAG"
    
    # Create request payload with advanced options
    payload = {
        "tenant_id": TENANT_ID,
        "query": query,
        "collection_name": "default",  # Use your actual collection
        "llm_model": "gpt-4-turbo",  # Might fail if tenant doesn't have access
        "similarity_top_k": 6,
        "response_mode": "refine",  # refine mode for longer, more detailed responses
        "additional_metadata_filter": {
            "document_type": "technical"  # Filter by document type if applicable
        }
    }
    
    # Send request
    response = requests.post(f"{API_BASE_URL}/query", json=payload)
    
    # Print results
    print(f"\nAdvanced Query Test")
    print(f"Status Code: {response.status_code}")
    if response.status_code == 200:
        result = response.json()
        print(f"Response Mode: refine")
        print(f"Requested Model: gpt-4-turbo, Actual Model Used: {result['llm_model']}")
        print(f"Number of sources: {len(result['sources'])}")
        print(f"Response Length: {len(result['response'])} characters")
    else:
        print(f"Error: {response.text}")
    
    return response.json() if response.status_code == 200 else None

def test_list_documents():
    """Test the /documents endpoint"""
    
    # Send request
    response = requests.get(f"{API_BASE_URL}/documents?tenant_id={TENANT_ID}")