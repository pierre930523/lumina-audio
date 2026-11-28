use core_types::ProviderKind;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;

use crate::error::ProviderError;
use crate::traits::{MusicProvider, ProviderCapabilities};

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ProviderSummary {
    pub kind: ProviderKind,
    pub display_name: String,
    pub is_streaming: bool,
    pub is_authenticated: bool,
    pub capabilities: ProviderCapabilities,
}

#[derive(Default, Clone)]
pub struct ProviderRegistry {
    providers: Arc<RwLock<HashMap<ProviderKind, Arc<dyn MusicProvider>>>>,
}

impl ProviderRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub async fn register(&self, provider: Arc<dyn MusicProvider>) {
        let kind = provider.kind();
        let mut map = self.providers.write().await;
        map.insert(kind, provider);
    }

    pub async fn unregister(&self, kind: ProviderKind) -> Option<Arc<dyn MusicProvider>> {
        let mut map = self.providers.write().await;
        map.remove(&kind)
    }

    pub async fn get(&self, kind: ProviderKind) -> Option<Arc<dyn MusicProvider>> {
        let map = self.providers.read().await;
        map.get(&kind).cloned()
    }

    pub async fn require(
        &self,
        kind: ProviderKind,
    ) -> Result<Arc<dyn MusicProvider>, ProviderError> {
        self.get(kind).await.ok_or_else(|| {
            ProviderError::InvalidConfig(format!("Provider '{kind}' not registered"))
        })
    }

    pub async fn is_registered(&self, kind: ProviderKind) -> bool {
        let map = self.providers.read().await;
        map.contains_key(&kind)
    }

    pub async fn list_all(&self) -> Vec<Arc<dyn MusicProvider>> {
        let map = self.providers.read().await;
        map.values().cloned().collect()
    }

    pub async fn summaries(&self) -> Vec<ProviderSummary> {
        let map = self.providers.read().await;
        let mut list = Vec::with_capacity(map.len());
        for (kind, prov) in map.iter() {
            list.push(ProviderSummary {
                kind: *kind,
                display_name: kind.display_name().to_string(),
                is_streaming: kind.is_streaming(),
                is_authenticated: prov.is_authenticated().await,
                capabilities: prov.capabilities(),
            });
        }
        list
    }
}
