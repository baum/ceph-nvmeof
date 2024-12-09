# KMS client

A KMS client serves as an abstraction layer for interacting with different Key Management Systems (KMS), providing a uniform interface for operations such as key retrieval and storage, regardless of the underlying KMS provider (e.g., HashiCorp Vault, AWS KMS, Azure Key Vault).

Using a Key Management System (KMS) instead of implementing custom key storage provides enhanced security, as KMS solutions are specifically designed to protect sensitive data with strong encryption and access control mechanisms. Additionally, KMS services offer centralized key management, auditing, and compliance features, ensuring that keys are securely stored, rotated, and monitored, which reduces the complexity and risk associated with managing cryptographic keys internally.

## KMS Config

A KMS Config defines the settings required to connect and interact with a specific Key Management System (KMS) service, including parameters such as the service endpoint, authentication method (e.g., API keys, tokens), and paths to store or retrieve keys. It provides the necessary details to initialize and authenticate the KMS client.

KMS settings required for secure key management, such as:

- **KMS Type** (e.g., HashiCorp Vault, AWS KMS, etc.)  
- **Authentication** (e.g., tokens, certificates)  
- **Endpoints** (e.g., URL or IP address)  
- **Encryption Key Information** (e.g., key IDs, key paths)

### **YAML Configuration Example**

```yaml
type: vault  
endpoint: https://vault.example.com
auth:  
  method: token  
  token: sometokenhere  
key_path: secret/data/nvmeof/keys
```

## KMSClient ABC

The `KMSClient` abstract base class (ABC) defines a standard interface for Key Management System (KMS) clients, ensuring a consistent API across different implementations like Vault, AWS KMS, or Azure Key Vault. It specifies three essential methods: `connect` for establishing a connection to the KMS service, `get_key` for retrieving a key, and `set_key` for storing a key. Each method uses type hints to return structured results, including success indicators, retrieved values, or error messages, enabling robust error handling. By encapsulating shared behaviors and enforcing a uniform contract, `KMSClient` simplifies the integration of new KMS backends and ensures that client code interacts with the KMS in a predictable manner.

```python
from abc import ABC, abstractmethod
from typing import Dict, Optional, Tuple


class KMSClient(ABC):
    """
    Abstract base class for KMS client implementations.
    """

    def __init__(self, config: Dict[str, any]) -> None:
        """
        Initialize with configuration.
        :param config: Dictionary containing KMS configuration.
        """
        self.config: Dict[str, any] = config

    @abstractmethod
    def connect(self) -> Tuple[bool, Optional[str]]:
        """
        Establish connection with the KMS service.
        :return: (success, error_message), where `success` is True if connected successfully,
                 and `error_message` contains details in case of failure.
        """
        pass

    @abstractmethod
    def get_key(self, key_name: str) -> Tuple[Optional[str], Optional[str]]:
        """
        Retrieve a key from the KMS.
        :param key_name: The name of the key to retrieve.
        :return: (key_value, error_message), where `key_value` is the key if successful,
                 and `error_message` contains details in case of failure.
        """
        pass

    @abstractmethod
    def set_key(self, key_name: str, key_value: str) -> Tuple[bool, Optional[str]]:
        """
        Store a key in the KMS.
        :param key_name: The name of the key to store.
        :param key_value: The value of the key to store.
        :return: (success, error_message), where `success` is True if stored successfully,
                 and `error_message` contains details in case of failure.
        """
        pass
```

## KMSClient factory

A factory function provides a single, centralized way to create instances of the `KMSClient` interface. It abstracts away the specific details of which implementation to use (e.g., `VaultKMSClient`, `AWSKMSClient`), making the client code simpler and more maintainable. The factory allows dynamic instantiation based on the configuration at runtime.Adding support for new KMS types is straightforward: just create a new subclass of `KMSClient` and update the factory function. Existing code using the factory doesn’t need to change.

```python
from typing import Dict


def kms_client_factory(config: Dict[str, any]) -> KMSClient:
    """
    Factory function to create a KMS client instance based on configuration.
    :param config: Dictionary containing the KMS configuration.
    :return: An instance of KMSClient.
    :raises ValueError: If the 'type' field is missing or unsupported.
    """
    kms_type = config.get("type")
    if not kms_type:
        raise ValueError("KMS configuration must include a 'type' field")

    if kms_type == "vault":
        return VaultKMSClient(config)
    else:
        raise ValueError(f"Unsupported KMS type: {kms_type}")
```

## Example Usage

### Configuration Dictionary

```python
config = {
    "type": "vault",
    "endpoint": "https://vault.example.com",
    "auth": {"method": "token", "token": "sometokenhere"},
    "key_path": "secret/data/nvmeof/keys"
}
```

### Create KMS Client

```python
kms_client = kms_client_factory(config)

# Connect to the KMS
success, error = kms_client.connect()
if not success:
    print(f"Failed to connect: {error}")
else:
    print("Connected successfully")
```

### Retrieve a key

```python
# Retrieve a key
key, error = kms_client.get_key("gateway-secret-key")
if error:
    print(f"Failed to retrieve key: {error}")
else:
    print(f"Retrieved key: {key}")
```

### Store a key

```python
# Store a key
success, error = kms_client.set_key("gateway-secret-key", "new-secret-key")
if not success:
    print(f"Failed to store key: {error}")
else:
    print("Key stored successfully")
```

## References

- [Configuring the Ceph Object Gateway to use SSE-KMS with Vault ](https://www.ibm.com/docs/en/storage-ceph/6?topic=uhv-configuring-ceph-object-gateway-use-sse-kms-vault)
- [Key Management System/Rook](https://rook.io/docs/rook/latest/Storage-Configuration/Advanced/key-management-system/) 
- [Ceph Object Gateway Config Reference](https://docs.ceph.com/en/reef/radosgw/config-ref/)
